import type { FastifyInstance, FastifyReply } from "fastify";
import { and, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices, households, users } from "../db/schema.js";
import { LIMITS } from "../households/limits.js";
import { requireHousehold } from "../households/scope.js";
import type { LiveTokenIssuer } from "../live/livekit.js";
import type { RealtimeHub } from "../realtime/hub.js";

interface LiveRouteOptions {
  db: Database;
  /** Undefined until LIVEKIT_* is configured; routes then answer 503. */
  live?: LiveTokenIssuer;
}

interface ViewerLiveRouteOptions extends LiveRouteOptions {
  /** Presence, to enforce the viewers-per-camera limit (SPEC §3). */
  hub: RealtimeHub;
}

function notConfigured(reply: FastifyReply) {
  return reply.code(503).send({ error: "live_not_configured" });
}

/** Whether the household's live video is end-to-end encrypted (the key itself never reaches us). */
async function isLiveEncrypted(db: Database, householdId: string): Promise<boolean> {
  const [row] = await db.select({ liveEncrypted: households.liveEncrypted }).from(households).where(eq(households.id, householdId));
  return row?.liveEncrypted ?? false;
}

/** Viewer side: `POST /cameras/:id/live-token` (user auth, scoped to the household). */
export async function viewerLiveRoutes(app: FastifyInstance, opts: ViewerLiveRouteOptions): Promise<void> {
  const { db } = opts;
  app.addHook("preHandler", app.authenticate);
  app.addHook("preHandler", requireHousehold(db));

  app.post<{ Params: { id: string } }>(
    "/cameras/:id/live-token",
    {
      schema: {
        params: { type: "object", required: ["id"], properties: { id: { type: "string", format: "uuid" } } },
      },
    },
    async (request, reply) => {
      const [camera] = await db
        .select({ id: devices.id, status: devices.status })
        .from(devices)
        .where(
          and(
            eq(devices.id, request.params.id),
            eq(devices.householdId, request.household!.householdId),
            eq(devices.role, "camera"),
          ),
        );
      if (!camera) return reply.code(404).send({ error: "not_found" });
      if (camera.status !== "active") return reply.code(409).send({ error: "device_revoked" });
      // Someone already watching (e.g. reconnecting, or a second phone) doesn't count twice.
      const userId = request.user!.userId;
      if (opts.hub.viewerCount(camera.id) >= LIMITS.viewersPerCamera && !opts.hub.isWatching(camera.id, userId)) {
        return reply.code(409).send({ error: "viewer_limit_reached", limit: LIMITS.viewersPerCamera });
      }
      if (!opts.live) return notConfigured(reply);

      const [user] = await db.select({ name: users.name }).from(users).where(eq(users.id, userId));
      const token = await opts.live.viewerToken({ deviceId: camera.id, userId, name: user?.name });
      return { ...token, encrypted: await isLiveEncrypted(db, request.household!.householdId) };
    },
  );
}

/** Camera side: `POST /device/live-token` (device auth) for publishing its own room. */
export async function cameraLiveRoutes(app: FastifyInstance, opts: LiveRouteOptions): Promise<void> {
  const { db } = opts;
  app.addHook("preHandler", app.authenticateDevice);

  app.post("/device/live-token", async (request, reply) => {
    const [device] = await db
      .select({ id: devices.id, role: devices.role, name: devices.name, householdId: devices.householdId })
      .from(devices)
      .where(eq(devices.id, request.device!.deviceId));
    if (device?.role !== "camera") return reply.code(403).send({ error: "camera_only" });
    if (!opts.live) return notConfigured(reply);
    const token = await opts.live.cameraToken({ deviceId: device.id, name: device.name });
    return { ...token, encrypted: await isLiveEncrypted(db, device.householdId) };
  });
}
