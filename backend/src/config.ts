import type { LiveKitConfig } from "./live/livekit.js";
import type { ApnsConfig } from "./notifications/apns.js";
import { APPLE_ROOT_CA_G3_SHA256, type AppStoreConfig } from "./billing/app-store.js";
import type { S3Config } from "./storage/storage.js";

/** Runtime configuration, read from environment variables (documented in .env.example). */
export interface Config {
  port: number;
  host: string;
  logLevel: string;
  nodeEnv: string;
  databaseUrl?: string;
  /** HMAC secret for our own JWTs. */
  jwtSecret?: string;
  /** Lifetime of our JWTs, in seconds. */
  jwtTtlSeconds: number;
  /** Accepted `aud` values for Sign in with Apple identity tokens (the app bundle id). */
  appleAudiences: string[];
  /** LiveKit Cloud credentials; undefined until all three LIVEKIT_* variables are set. */
  liveKit?: LiveKitConfig;
  /** APNs token auth; undefined until APNS_KEY_ID, APNS_TEAM_ID and APNS_KEY_P8 are set. */
  apns?: ApnsConfig;
  /** Clip storage; undefined until S3_BUCKET, S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY are set. */
  s3?: S3Config;
  /** Days to keep clips and snapshots. */
  retentionDays: number;
  /** "<team id>.<bundle id>" for Universal Links; empty until APPLE_TEAM_ID (or APNS_TEAM_ID) is set. */
  appLinkIds: string[];
  /** Verifying StoreKit 2 transactions for premium. */
  appStore: AppStoreConfig;
  /** Apply the free-plan limits (off until the app can sell premium). */
  enforcePlanLimits: boolean;
  /** Bearer token for admin routes; undefined when unset or shorter than 32 characters. */
  adminToken?: string;
  /** Optional features left off because their variables are incomplete or invalid; logged at startup. */
  warnings: string[];
}

/**
 * Reads a group of variables that only work together. Values are trimmed, so blank or
 * whitespace-only values count as unset. A partial group turns the feature off with a
 * warning instead of stopping the server.
 */
function group<K extends string>(
  env: NodeJS.ProcessEnv,
  names: readonly K[],
  feature: string,
  warnings: string[],
): Record<K, string> | undefined {
  const values = names.map((name) => [name, env[name]?.trim() ?? ""] as const);
  const missing = values.filter(([, value]) => !value).map(([name]) => name);
  if (missing.length === names.length) return undefined;
  if (missing.length > 0) {
    warnings.push(`${feature} is off: set ${missing.join(", ")} too (or remove the other ${names.length - missing.length})`);
    return undefined;
  }
  return Object.fromEntries(values) as Record<K, string>;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const port = Number(env.PORT ?? 3000);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error(`Invalid PORT: ${env.PORT}`);
  }
  const jwtTtlSeconds = Number(env.JWT_TTL_SECONDS ?? 60 * 60 * 24 * 30);
  if (!Number.isInteger(jwtTtlSeconds) || jwtTtlSeconds <= 0) {
    throw new Error(`Invalid JWT_TTL_SECONDS: ${env.JWT_TTL_SECONDS}`);
  }
  const warnings: string[] = [];
  let liveKit = group(env, ["LIVEKIT_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET"] as const, "Live view", warnings);
  if (liveKit) {
    // The LiveKit dashboard shows both forms; the apps connect over WebSocket.
    liveKit.LIVEKIT_URL = liveKit.LIVEKIT_URL.replace(/^http(s?):\/\//, "ws$1://");
  }
  if (liveKit && !/^wss?:\/\//.test(liveKit.LIVEKIT_URL)) {
    warnings.push(`Live view is off: LIVEKIT_URL must start with wss:// (got ${liveKit.LIVEKIT_URL})`);
    liveKit = undefined;
  }
  const apns = group(env, ["APNS_KEY_ID", "APNS_TEAM_ID", "APNS_KEY_P8"] as const, "Push notifications", warnings);
  const apnsEnvRaw = env.APNS_ENV?.trim() || "sandbox";
  if (apnsEnvRaw !== "sandbox" && apnsEnvRaw !== "production") {
    warnings.push(`APNS_ENV must be sandbox or production (got ${apnsEnvRaw}); using sandbox`);
  }
  const apnsEnv = apnsEnvRaw === "production" ? "production" : "sandbox";
  const s3 = group(env, ["S3_BUCKET", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY"] as const, "Clip storage", warnings);
  const s3Endpoint = env.S3_ENDPOINT?.trim() || undefined;
  const retentionDays = Number(env.CLIP_RETENTION_DAYS ?? 7);
  if (!Number.isInteger(retentionDays) || retentionDays < 1) {
    throw new Error(`Invalid CLIP_RETENTION_DAYS: ${env.CLIP_RETENTION_DAYS}`);
  }
  let adminToken = env.ADMIN_TOKEN?.trim() || undefined;
  if (adminToken && adminToken.length < 32) {
    warnings.push("Admin routes are off: ADMIN_TOKEN must be at least 32 characters");
    adminToken = undefined;
  }
  return {
    port,
    host: env.HOST ?? "0.0.0.0",
    logLevel: env.LOG_LEVEL ?? "info",
    nodeEnv: env.NODE_ENV ?? "development",
    databaseUrl: env.DATABASE_URL?.trim() || undefined,
    jwtSecret: env.JWT_SECRET?.trim() || undefined,
    jwtTtlSeconds,
    appleAudiences: (env.APPLE_AUDIENCES ?? "com.benooon.dogmonitor")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
    liveKit: liveKit
      ? { url: liveKit.LIVEKIT_URL, apiKey: liveKit.LIVEKIT_API_KEY, apiSecret: liveKit.LIVEKIT_API_SECRET }
      : undefined,
    apns: apns
      ? {
          keyId: apns.APNS_KEY_ID,
          teamId: apns.APNS_TEAM_ID,
          // Railway variables can't hold newlines easily; accept "\n" escapes too.
          privateKey: apns.APNS_KEY_P8.replace(/\\n/g, "\n"),
          topic: env.APNS_TOPIC ?? "com.benooon.dogmonitor",
          environment: apnsEnv,
        }
      : undefined,
    s3: s3
      ? {
          endpoint: s3Endpoint,
          forcePathStyle: s3PathStyle(env.S3_FORCE_PATH_STYLE, s3Endpoint),
          region: env.S3_REGION ?? "auto",
          bucket: s3.S3_BUCKET,
          accessKeyId: s3.S3_ACCESS_KEY_ID,
          secretAccessKey: s3.S3_SECRET_ACCESS_KEY,
        }
      : undefined,
    retentionDays,
    appLinkIds: appLinkIds(env),
    appStore: {
      bundleId: env.APPLE_BUNDLE_ID || "com.benooon.dogmonitor",
      productIds: list(env.APP_STORE_PRODUCT_IDS ?? "com.benooon.dogmonitor.premium.monthly,com.benooon.dogmonitor.premium.yearly"),
      rootFingerprints: list(env.APPLE_ROOT_CA_SHA256 || APPLE_ROOT_CA_G3_SHA256),
    },
    enforcePlanLimits: env.ENFORCE_PLAN_LIMITS === "true",
    adminToken,
    warnings,
  };
}

/**
 * Path-style unless told otherwise, except for Railway buckets (`*.storageapi.dev`), which use
 * virtual-hosted URLs. `S3_FORCE_PATH_STYLE=true|false` overrides it (e.g. an older Railway bucket).
 */
function s3PathStyle(value: string | undefined, endpoint: string | undefined): boolean {
  const explicit = value?.trim().toLowerCase();
  if (explicit === "true") return true;
  if (explicit === "false") return false;
  if (!endpoint) return false;
  return !/\.storageapi\.dev(?::\d+)?(?:\/|$)/.test(endpoint);
}

function list(value: string): string[] {
  return value
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

function appLinkIds(env: NodeJS.ProcessEnv): string[] {
  const team = env.APPLE_TEAM_ID || env.APNS_TEAM_ID;
  if (!team) return [];
  return [`${team}.${env.APPLE_BUNDLE_ID || "com.benooon.dogmonitor"}`];
}

/** Throws if a value needed to serve real traffic is missing. */
export function requireServerConfig(config: Config): Required<Pick<Config, "databaseUrl" | "jwtSecret">> {
  const missing: string[] = [];
  if (!config.databaseUrl) missing.push("DATABASE_URL");
  if (!config.jwtSecret) missing.push("JWT_SECRET");
  else if (config.jwtSecret.length < 32) missing.push("JWT_SECRET (must be at least 32 characters)");
  if (missing.length > 0) throw new Error(`Missing configuration: ${missing.join(", ")}`);
  return { databaseUrl: config.databaseUrl!, jwtSecret: config.jwtSecret! };
}
