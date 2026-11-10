import http2 from "node:http2";
import { SignJWT, importPKCS8, type CryptoKey } from "jose";

/** APNs token-auth credentials (env: APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8, APNS_TOPIC, APNS_ENV). */
export interface ApnsConfig {
  keyId: string;
  teamId: string;
  /** Contents of the .p8 key (PEM). */
  privateKey: string;
  /** The app's bundle id. */
  topic: string;
  /** "sandbox" for Xcode debug builds, "production" for TestFlight / App Store. */
  environment: "sandbox" | "production";
}

export const APNS_HOSTS = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
} as const;

export interface ApnsNotification {
  deviceToken: string;
  payload: Record<string, unknown>;
  pushType?: "alert" | "background";
  /** 10 = immediately, 5 = power-friendly. */
  priority?: 10 | 5;
  /** Later pushes with the same id replace earlier ones on the device (max 64 bytes). */
  collapseId?: string;
}

export interface ApnsResult {
  status: number;
  /** Apple's error reason, e.g. "BadDeviceToken" or "Unregistered". */
  reason?: string;
}

export interface ApnsSender {
  send(notification: ApnsNotification): Promise<ApnsResult>;
}

/** The token is no longer valid for this app; stop sending to it. */
export function isDeadToken(result: ApnsResult): boolean {
  return result.status === 410 || (result.status === 400 && (result.reason === "BadDeviceToken" || result.reason === "DeviceTokenNotForTopic"));
}

/** Apple accepts provider tokens for up to an hour and rejects refreshes more often than every 20 minutes. */
const TOKEN_REFRESH_MS = 50 * 60 * 1000;

/**
 * APNs over HTTP/2 with JWT (ES256) provider tokens. One connection is reused for all pushes
 * and reopened if it drops. `origin` can point at a local test server.
 */
export class ApnsClient implements ApnsSender {
  private session: http2.ClientHttp2Session | null = null;
  private token: { value: string; issuedAt: number } | null = null;
  private key: Promise<CryptoKey> | null = null;

  constructor(
    private readonly config: ApnsConfig,
    private readonly origin: string = APNS_HOSTS[config.environment],
    private readonly now: () => number = Date.now,
  ) {}

  async providerToken(): Promise<string> {
    const now = this.now();
    if (this.token && now - this.token.issuedAt < TOKEN_REFRESH_MS) return this.token.value;
    this.key ??= importPKCS8(this.config.privateKey, "ES256");
    const value = await new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: this.config.keyId })
      .setIssuer(this.config.teamId)
      .setIssuedAt(Math.floor(now / 1000))
      .sign(await this.key);
    this.token = { value, issuedAt: now };
    return value;
  }

  async send(notification: ApnsNotification): Promise<ApnsResult> {
    const headers: http2.OutgoingHttpHeaders = {
      ":method": "POST",
      ":path": `/3/device/${notification.deviceToken}`,
      authorization: `bearer ${await this.providerToken()}`,
      "apns-topic": this.config.topic,
      "apns-push-type": notification.pushType ?? "alert",
      "apns-priority": String(notification.priority ?? 10),
      "content-type": "application/json",
    };
    if (notification.collapseId) headers["apns-collapse-id"] = notification.collapseId;
    const body = JSON.stringify(notification.payload);

    return new Promise<ApnsResult>((resolve, reject) => {
      const request = this.connection().request(headers);
      let status = 0;
      let data = "";
      request.setEncoding("utf8");
      request.on("response", (h) => {
        status = Number(h[":status"]);
      });
      request.on("data", (chunk: string) => {
        data += chunk;
      });
      request.on("end", () => {
        let reason: string | undefined;
        if (data) {
          try {
            reason = (JSON.parse(data) as { reason?: string }).reason;
          } catch {
            reason = data;
          }
        }
        resolve({ status, reason });
      });
      request.on("error", reject);
      request.setTimeout(10_000, () => request.close(http2.constants.NGHTTP2_CANCEL));
      request.end(body);
    });
  }

  close(): void {
    this.session?.close();
    this.session = null;
  }

  private connection(): http2.ClientHttp2Session {
    if (this.session && !this.session.closed && !this.session.destroyed) return this.session;
    const session = http2.connect(this.origin);
    session.on("error", () => {
      if (this.session === session) this.session = null;
    });
    session.on("close", () => {
      if (this.session === session) this.session = null;
    });
    session.unref();
    this.session = session;
    return session;
  }
}
