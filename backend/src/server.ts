import { buildApp } from "./app.js";
import { createAppleTokenVerifier } from "./auth/apple.js";
import { JwtService } from "./auth/jwt.js";
import { loadConfig, requireServerConfig } from "./config.js";
import { createDb } from "./db/client.js";
import { createLiveKitIssuer } from "./live/livekit.js";
import { ApnsClient } from "./notifications/apns.js";
import { S3MediaStorage } from "./storage/storage.js";
import { createAppStoreVerifier } from "./billing/app-store.js";

const config = loadConfig();
const { databaseUrl, jwtSecret } = requireServerConfig(config);
const dbHandle = createDb(databaseUrl);

const app = await buildApp({
  logLevel: config.logLevel,
  appLinkIds: config.appLinkIds,
  services: {
    db: dbHandle.db,
    jwt: new JwtService(jwtSecret, config.jwtTtlSeconds),
    apple: createAppleTokenVerifier({ audiences: config.appleAudiences }),
    live: config.liveKit ? createLiveKitIssuer(config.liveKit) : undefined,
    apns: config.apns ? new ApnsClient(config.apns) : undefined,
    storage: config.s3 ? new S3MediaStorage(config.s3) : undefined,
    retentionDays: config.retentionDays,
    recordRetentionDays: config.recordRetentionDays,
    transactions: createAppStoreVerifier(config.appStore),
    enforcePlanLimits: config.enforcePlanLimits,
  },
});

const shutdown = async (signal: string) => {
  app.log.info({ signal }, "shutting down");
  await app.close();
  await dbHandle.close();
  process.exit(0);
};
process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));

for (const warning of config.warnings) app.log.warn(warning);
if (!config.s3) app.log.warn("S3_* not set: clip and snapshot uploads are disabled");
if (!config.apns) app.log.warn("APNS_* not set: events are stored but no pushes are sent");
if (!config.liveKit) app.log.warn("LIVEKIT_* not set: live view token routes will answer 503");

await app.listen({ port: config.port, host: config.host });
