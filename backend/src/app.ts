import Fastify, { type FastifyInstance } from "fastify";
import websocket from "@fastify/websocket";
import type { AppleTokenVerifier } from "./auth/apple.js";
import type { JwtService } from "./auth/jwt.js";
import { deviceAuthPlugin } from "./auth/device-plugin.js";
import { authPlugin } from "./auth/plugin.js";
import type { Database } from "./db/client.js";
import type { LiveTokenIssuer } from "./live/livekit.js";
import type { ApnsSender } from "./notifications/apns.js";
import type { MediaStorage } from "./storage/storage.js";
import { DEFAULT_RETENTION_DAYS, scheduleRetention } from "./storage/retention.js";
import { EventNotifier, recordCameraOffline } from "./notifications/notifier.js";
import type { AttemptLimiter } from "./pairing/attempt-limiter.js";
import { RealtimeHub } from "./realtime/hub.js";
import { authRoutes } from "./routes/auth.js";
import { deviceSelfRoutes } from "./routes/device-self.js";
import { deviceRoutes } from "./routes/devices.js";
import { dogRoutes } from "./routes/dogs.js";
import { cameraEventRoutes } from "./routes/events.js";
import { cameraMediaRoutes, viewerMediaRoutes } from "./routes/media.js";
import { householdRoutes } from "./routes/households.js";
import { inviteRoutes } from "./routes/invites.js";
import { notificationPrefRoutes } from "./routes/notification-prefs.js";
import { cameraLiveRoutes, viewerLiveRoutes } from "./routes/live.js";
import { realtimeRoutes } from "./routes/realtime.js";
import { timelineRoutes } from "./routes/timeline.js";
import { cameraZoneRoutes } from "./routes/zones.js";
import { trainingRoutes } from "./routes/training.js";
import { cameraSummaryRoutes, viewerSummaryRoutes } from "./routes/summaries.js";
import { healthRoutes } from "./routes/health.js";
import { appLinkRoutes } from "./routes/app-links.js";

export interface AppServices {
  db: Database;
  jwt: JwtService;
  apple: AppleTokenVerifier;
  /** LiveKit token minting; undefined when LIVEKIT_* is not configured (live routes answer 503). */
  live?: LiveTokenIssuer;
  /** APNs; undefined when APNS_* is not configured (events are stored without pushes). */
  apns?: ApnsSender;
  /** Clip/snapshot storage; undefined when S3_* is not configured. */
  storage?: MediaStorage;
  /** Days to keep clips and snapshots (SPEC §10, default 7). */
  retentionDays?: number;
  /** Realtime presence (tests pass their own to inspect it). */
  hub?: RealtimeHub;
  /** Clock for heartbeats and offline detection (tests). */
  now?: () => number;
  /** Override the invite brute-force limiter (tests). */
  inviteLimiter?: AttemptLimiter;
}

export interface BuildAppOptions {
  logLevel?: string;
  /** "<team id>.<bundle id>" values allowed to open invite links (Universal Links). */
  appLinkIds?: string[];
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
  await app.register(appLinkRoutes, { appIds: options.appLinkIds ?? [] });

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
    await app.register(cameraZoneRoutes, { db: services.db });
    await app.register(notificationPrefRoutes, { db: services.db });
    const clock = services.now ?? Date.now;
    const notifier = new EventNotifier(services.db, services.apns, app.log, services.storage, () => new Date(clock()));
    await app.register(cameraEventRoutes, { db: services.db, notifier });
    await app.register(cameraMediaRoutes, { db: services.db, storage: services.storage });
    await app.register(viewerMediaRoutes, { db: services.db, storage: services.storage });
    await app.register(timelineRoutes, { db: services.db });
    await app.register(cameraSummaryRoutes, { db: services.db, notifier });
    await app.register(viewerSummaryRoutes, { db: services.db });
    await app.register(trainingRoutes, { db: services.db, storage: services.storage, jwt: services.jwt });
    if (services.storage && services.retentionDays !== 0) {
      const stop = scheduleRetention(services.db, services.storage, services.retentionDays ?? DEFAULT_RETENTION_DAYS, app.log);
      app.addHook("onClose", async () => stop());
    }

    const hub = services.hub ?? new RealtimeHub();
    hub.addPresenceListener((cameraId, householdId, online) => {
      if (!online) void recordCameraOffline(services.db, notifier, cameraId, householdId, app.log);
    });
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
