import Fastify, { type FastifyInstance } from "fastify";
import type { AppleTokenVerifier } from "./auth/apple.js";
import type { JwtService } from "./auth/jwt.js";
import { authPlugin } from "./auth/plugin.js";
import type { Database } from "./db/client.js";
import { authRoutes } from "./routes/auth.js";
import { deviceRoutes } from "./routes/devices.js";
import { dogRoutes } from "./routes/dogs.js";
import { householdRoutes } from "./routes/households.js";
import { healthRoutes } from "./routes/health.js";

export interface AppServices {
  db: Database;
  jwt: JwtService;
  apple: AppleTokenVerifier;
}

export interface BuildAppOptions {
  logLevel?: string;
  /** Omit to build only the stateless routes (e.g. /health). */
  services?: AppServices;
}

/** Builds the Fastify app without listening, so tests can use `app.inject`. */
export async function buildApp(options: BuildAppOptions = {}): Promise<FastifyInstance> {
  const app = Fastify({
    logger: options.logLevel === "silent" ? false : { level: options.logLevel ?? "info" },
  });
  await app.register(healthRoutes);

  const services = options.services;
  if (services) {
    await app.register(authPlugin, { jwt: services.jwt });
    await app.register(authRoutes, services);
    await app.register(householdRoutes, { db: services.db });
    await app.register(dogRoutes, { db: services.db });
    await app.register(deviceRoutes, { db: services.db });
  }
  return app;
}
