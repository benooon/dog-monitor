import type { FastifyInstance } from "fastify";
import { buildApp } from "../../src/app.js";
import { createAppleTokenVerifier } from "../../src/auth/apple.js";
import { JwtService } from "../../src/auth/jwt.js";
import type { DbHandle } from "../../src/db/client.js";
import { createFakeApple } from "./apple.js";

export const TEST_JWT_SECRET = "test-secret-test-secret-test-secret-123";

export async function buildTestApp(h: DbHandle): Promise<{
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
    },
  });
  return { app, apple, jwt };
}
