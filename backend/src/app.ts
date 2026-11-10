import Fastify, { type FastifyInstance } from "fastify";
import websocket from "@fastify/websocket";
import type { AppleTokenVerifier } from "./auth/apple.js";
import type { JwtService } from "./auth/jwt.js";
import { deviceAuthPlugin } from "./auth/device-plugin.js";
import { authPlugin } from "./auth/plugin.js";
import type { Database } from "./db/client.js";
import type { LiveTokenIssuer } from "./live/livekit.js";
import type { AttemptLimiter } from "./pairing/attempt-limiter.js";
import { RealtimeHub } from "./realtime/hub.js";
import { authRoutes } from "./routes/auth.js";
import { deviceSelfRoutes } from "./routes/device-self.js";
import { deviceRoutes } from "./routes/devices.js";
import { dogRoutes } from "./routes/dogs.js";
import { householdRoutes } from "./routes/households.js";
import { inviteRoutes } from "./routes/invites.js";
import { cameraLiveRoutes, viewerLiveRoutes } from "./routes/live.js";
import { realtimeRoutes } from "./routes/realtime.js";
import { healthRoutes } from "./routes/health.js";

export interface AppServices {
  db: Database;
  jwt: JwtService;
  apple: AppleTokenVerifier;
  /** LiveKit token minting; undefined when LIVEKIT_* is not configured (live routes answer 503). */
  live?: LiveTokenIssuer;
  /** Realtime presence (tests pass their own to inspect it). */
  hub?: RealtimeHub;
  /** Clock for heartbeats and offline detection (tests). */
  now?: () => number;
  /** Override the invite brute-force limiter (tests). */
  inviteLimiter?: AttemptLimiter;
}

export interface BuildAppOptions {
  logLevel?: string;
  /** Omit to build only the stateless routes (e.g. /health). */
  services?: AppServices;
}

/** Builds the Fastify app without listening, so tests can use `app.inject`. */
export async function buildApp(options: BuildAppOptions = {}): Promise<FastifyInstance> {
  const app = Fastify({
    // Railway terminates TLS in front of us; trust X-Forwarded-For so request.ip is the client.
    trustProxy: true,
    logger: options.logLevel === "silent" ? false : { level: options.logLevel ?? "info" },
  });
  await app.register(healthRoutes);

  const services = options.services;
  if (services) {
    await app.register(authPlugin, { jwt: services.jwt });
    await app.register(deviceAuthPlugin, { db: services.db });
    await app.register(authRoutes, services);
    await app.register(householdRoutes, { db: services.db });
    await app.register(dogRoutes, { db: services.db });
    await app.register(deviceRoutes, { db: services.db });
    await app.register(inviteRoutes, { db: services.db, limiter: services.inviteLimiter });
    await app.register(deviceSelfRoutes, { db: services.db });
    const hub = services.hub ?? new RealtimeHub();
    const now = services.now ?? Date.now;
    await app.register(viewerLiveRoutes, { db: services.db, live: services.live, hub });
    await app.register(cameraLiveRoutes, { db: services.db, live: services.live });

    await app.register(websocket);
    await app.register(realtimeRoutes, { db: services.db, hub, now });
    // Marks cameras offline after 3 minutes without a heartbeat.
    const sweep = setInterval(() => hub.sweep(now()), 30_000);
    sweep.unref();
    app.addHook("onClose", async () => clearInterval(sweep));
  }
  return app;
}
