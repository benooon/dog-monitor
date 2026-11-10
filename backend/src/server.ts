import { buildApp } from "./app.js";
import { createAppleTokenVerifier } from "./auth/apple.js";
import { JwtService } from "./auth/jwt.js";
import { loadConfig, requireServerConfig } from "./config.js";
import { createDb } from "./db/client.js";
import { createLiveKitIssuer } from "./live/livekit.js";

const config = loadConfig();
const { databaseUrl, jwtSecret } = requireServerConfig(config);
const dbHandle = createDb(databaseUrl);

const app = await buildApp({
  logLevel: config.logLevel,
  services: {
    db: dbHandle.db,
    jwt: new JwtService(jwtSecret, config.jwtTtlSeconds),
    apple: createAppleTokenVerifier({ audiences: config.appleAudiences }),
    live: config.liveKit ? createLiveKitIssuer(config.liveKit) : undefined,
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

if (!config.liveKit) app.log.warn("LIVEKIT_* not set: live view token routes will answer 503");

await app.listen({ port: config.port, host: config.host });
