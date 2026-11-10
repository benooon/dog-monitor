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
  const liveKitVars = [env.LIVEKIT_URL, env.LIVEKIT_API_KEY, env.LIVEKIT_API_SECRET];
  const setCount = liveKitVars.filter(Boolean).length;
  if (setCount > 0 && setCount < 3) {
    throw new Error("Set all of LIVEKIT_URL, LIVEKIT_API_KEY and LIVEKIT_API_SECRET, or none of them");
  }
  if (env.LIVEKIT_URL && !/^wss?:\/\//.test(env.LIVEKIT_URL)) {
    throw new Error(`Invalid LIVEKIT_URL (expected wss://…): ${env.LIVEKIT_URL}`);
  }
  const apnsVars = [env.APNS_KEY_ID, env.APNS_TEAM_ID, env.APNS_KEY_P8];
  const apnsSet = apnsVars.filter(Boolean).length;
  if (apnsSet > 0 && apnsSet < 3) {
    throw new Error("Set all of APNS_KEY_ID, APNS_TEAM_ID and APNS_KEY_P8, or none of them");
  }
  const apnsEnv = env.APNS_ENV ?? "sandbox";
  if (apnsEnv !== "sandbox" && apnsEnv !== "production") {
    throw new Error(`Invalid APNS_ENV (sandbox or production): ${apnsEnv}`);
  }
  const s3Vars = [env.S3_BUCKET, env.S3_ACCESS_KEY_ID, env.S3_SECRET_ACCESS_KEY];
  const s3Set = s3Vars.filter(Boolean).length;
  if (s3Set > 0 && s3Set < 3) {
    throw new Error("Set all of S3_BUCKET, S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY, or none of them");
  }
  const retentionDays = Number(env.CLIP_RETENTION_DAYS ?? 7);
  if (!Number.isInteger(retentionDays) || retentionDays < 1) {
    throw new Error(`Invalid CLIP_RETENTION_DAYS: ${env.CLIP_RETENTION_DAYS}`);
  }
  return {
    port,
    host: env.HOST ?? "0.0.0.0",
    logLevel: env.LOG_LEVEL ?? "info",
    nodeEnv: env.NODE_ENV ?? "development",
    databaseUrl: env.DATABASE_URL || undefined,
    jwtSecret: env.JWT_SECRET || undefined,
    jwtTtlSeconds,
    appleAudiences: (env.APPLE_AUDIENCES ?? "com.benooon.dogmonitor")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
    liveKit:
      setCount === 3
        ? { url: env.LIVEKIT_URL!, apiKey: env.LIVEKIT_API_KEY!, apiSecret: env.LIVEKIT_API_SECRET! }
        : undefined,
    apns:
      apnsSet === 3
        ? {
            keyId: env.APNS_KEY_ID!,
            teamId: env.APNS_TEAM_ID!,
            // Railway variables can't hold newlines easily; accept "\n" escapes too.
            privateKey: env.APNS_KEY_P8!.replace(/\\n/g, "\n"),
            topic: env.APNS_TOPIC ?? "com.benooon.dogmonitor",
            environment: apnsEnv,
          }
        : undefined,
    s3:
      s3Set === 3
        ? {
            endpoint: env.S3_ENDPOINT || undefined,
            region: env.S3_REGION ?? "auto",
            bucket: env.S3_BUCKET!,
            accessKeyId: env.S3_ACCESS_KEY_ID!,
            secretAccessKey: env.S3_SECRET_ACCESS_KEY!,
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
  };
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
