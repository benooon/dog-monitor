import type { FastifyInstance, FastifyReply } from "fastify";
import { and, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { dailySummaries, households } from "../db/schema.js";
import { requireHousehold } from "../households/scope.js";
import { PLAN_FEATURES, effectivePlan } from "../billing/plans.js";
import { MEDIA_CONTENT_TYPES, reelMediaKey, type MediaStorage } from "../storage/storage.js";
import { DOWNLOAD_URL_TTL_SECONDS, UPLOAD_URL_TTL_SECONDS } from "./media.js";

interface ReelRouteOptions {
  db: Database;
  /** Undefined until S3_* is configured; routes then answer 503. */
  storage?: MediaStorage;
  /** Off: every household gets the reel, like every other plan feature. */
  enforcePlanLimits: boolean;
  now?: () => Date;
}

const dateParams = {
  type: "object",
  required: ["date"],
  properties: { date: { type: "string", format: "date" } },
} as const;

/**
 * The daily highlight reel (Premium). The camera stitches the day's best clips into one video,
 * then `POST /device/reels/:date/upload` → presigned PUT, upload, `PUT /device/reels/:date` to
 * attach it to that day's summary. The key is always derived on the server.
 */
export async function cameraReelRoutes(app: FastifyInstance, opts: ReelRouteOptions): Promise<void> {
  const { db, enforcePlanLimits } = opts;
  const now = opts.now ?? (() => new Date());
  app.addHook("preHandler", app.authenticateDevice);

  /** Checks the summary exists and the plan includes the reel; sends the error and returns false otherwise. */
  async function allowed(deviceId: string, householdId: string, date: string, reply: FastifyReply): Promise<boolean> {
    const [row] = await db
      .select({ planExpiresAt: households.planExpiresAt })
      .from(dailySummaries)
      .innerJoin(households, eq(households.id, dailySummaries.householdId))
      .where(and(eq(dailySummaries.deviceId, deviceId), eq(dailySummaries.date, date)));
    if (!row) {
      await reply.code(404).send({ error: "summary_not_found" });
      return false;
    }
    if (enforcePlanLimits && !PLAN_FEATURES[effectivePlan(row, now())].highlightReel) {
      await reply.code(403).send({ error: "premium_required" });
      return false;
    }
    return true;
  }

  app.post<{ Params: { date: string } }>(
    "/device/reels/:date/upload",
    { schema: { params: dateParams } },
    async (request, reply) => {
      if (!opts.storage) return reply.code(503).send({ error: "storage_not_configured" });
      const { deviceId, householdId } = request.device!;
      const { date } = request.params;
      if (!(await allowed(deviceId, householdId, date, reply))) return reply;
      const key = reelMediaKey(householdId, deviceId, date);
      return { upload: await opts.storage.presignUpload(key, MEDIA_CONTENT_TYPES.clip, UPLOAD_URL_TTL_SECONDS) };
    },
  );

  app.put<{ Params: { date: string } }>(
    "/device/reels/:date",
    { schema: { params: dateParams } },
    async (request, reply) => {
      const { deviceId, householdId } = request.device!;
      const { date } = request.params;
      if (!(await allowed(deviceId, householdId, date, reply))) return reply;
      await db
        .update(dailySummaries)
        .set({ reelKey: reelMediaKey(householdId, deviceId, date), updatedAt: now() })
        .where(and(eq(dailySummaries.deviceId, deviceId), eq(dailySummaries.date, date)));
      return { hasReel: true };
    },
  );
}

/** Viewer: `GET /summaries/:cameraId/:date/reel` → a short-lived download URL for that day's reel. */
export async function viewerReelRoutes(app: FastifyInstance, opts: ReelRouteOptions): Promise<void> {
  const { db } = opts;
  app.addHook("preHandler", app.authenticate);
  app.addHook("preHandler", requireHousehold(db));

  app.get<{ Params: { cameraId: string; date: string } }>(
    "/summaries/:cameraId/:date/reel",
    {
      schema: {
        params: {
          type: "object",
          required: ["cameraId", "date"],
          properties: { cameraId: { type: "string", format: "uuid" }, date: { type: "string", format: "date" } },
        },
      },
    },
    async (request, reply) => {
      const [row] = await db
        .select({ reelKey: dailySummaries.reelKey })
        .from(dailySummaries)
        .where(
          and(
            eq(dailySummaries.householdId, request.household!.householdId),
            eq(dailySummaries.deviceId, request.params.cameraId),
            eq(dailySummaries.date, request.params.date),
          ),
        );
      if (!row?.reelKey) return reply.code(404).send({ error: "not_found" });
      if (!opts.storage) return reply.code(503).send({ error: "storage_not_configured" });
      return {
        url: await opts.storage.presignDownload(row.reelKey, DOWNLOAD_URL_TTL_SECONDS),
        expiresAt: new Date(Date.now() + DOWNLOAD_URL_TTL_SECONDS * 1000).toISOString(),
      };
    },
  );
}
