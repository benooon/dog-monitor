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
  };
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
