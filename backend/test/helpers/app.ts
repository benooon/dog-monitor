import type { FastifyInstance } from "fastify";
import { buildApp } from "../../src/app.js";
import { createAppleTokenVerifier } from "../../src/auth/apple.js";
import { JwtService } from "../../src/auth/jwt.js";
import type { DbHandle } from "../../src/db/client.js";
import type { LiveTokenIssuer } from "../../src/live/livekit.js";
import type { RealtimeHub } from "../../src/realtime/hub.js";
import type { ApnsSender } from "../../src/notifications/apns.js";
import type { AttemptLimiter } from "../../src/pairing/attempt-limiter.js";
import { createFakeApple } from "./apple.js";

export const TEST_JWT_SECRET = "test-secret-test-secret-test-secret-123";

export async function buildTestApp(
  h: DbHandle,
  options: { inviteLimiter?: AttemptLimiter; live?: LiveTokenIssuer; hub?: RealtimeHub; now?: () => number; apns?: ApnsSender } = {},
): Promise<{
  app: FastifyInstance;
  apple: Awaited<ReturnType<typeof createFakeApple>>;
  jwt: JwtService;
}> {
  const apple = await createFakeApple();
  const jwt = new JwtService(TEST_JWT_SECRET, 3600);
  const app = await buildApp({
    logLevel: "silent",
    services: {
      db: h.db,
      jwt,
      apple: createAppleTokenVerifier({ audiences: ["com.benooon.dogmonitor"], keySet: apple.keySet }),
      inviteLimiter: options.inviteLimiter,
      live: options.live,
      hub: options.hub,
      apns: options.apns,
      now: options.now,
    },
  });
  return { app, apple, jwt };
}
