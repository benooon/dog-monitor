import type { FastifyInstance } from "fastify";
import { and, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { events } from "../db/schema.js";
import { requireHousehold } from "../households/scope.js";
import { MEDIA_CONTENT_TYPES, eventMediaKey, type MediaKind, type MediaStorage, type PresignedUpload } from "../storage/storage.js";

export const UPLOAD_URL_TTL_SECONDS = 15 * 60;
export const DOWNLOAD_URL_TTL_SECONDS = 10 * 60;

interface MediaRouteOptions {
  db: Database;
  /** Undefined until S3_* is configured; routes then answer 503. */
  storage?: MediaStorage;
}

/** Camera: `POST /device/uploads` → presigned PUT URLs for an event's snapshot and clip. */
export async function cameraMediaRoutes(app: FastifyInstance, opts: MediaRouteOptions): Promise<void> {
  app.addHook("preHandler", app.authenticateDevice);

  app.post<{ Body: { eventId: string; kinds: MediaKind[] } }>(
    "/device/uploads",
    {
      schema: {
        body: {
          type: "object",
          required: ["eventId", "kinds"],
          additionalProperties: false,
          properties: {
            eventId: { type: "string", format: "uuid" },
            kinds: { type: "array", minItems: 1, uniqueItems: true, items: { type: "string", enum: ["clip", "snapshot"] } },
          },
        },
      },
    },
    async (request, reply) => {
      if (!opts.storage) return reply.code(503).send({ error: "storage_not_configured" });
      const { deviceId, householdId } = request.device!;
      const uploads: Partial<Record<MediaKind, PresignedUpload>> = {};
      for (const kind of request.body.kinds) {
        const key = eventMediaKey(householdId, deviceId, request.body.eventId, kind);
        uploads[kind] = await opts.storage.presignUpload(key, MEDIA_CONTENT_TYPES[kind], UPLOAD_URL_TTL_SECONDS);
      }
      return { uploads };
    },
  );
}

/** Viewer: `GET /events/:id/media` → short-lived download URLs. */
export async function viewerMediaRoutes(app: FastifyInstance, opts: MediaRouteOptions): Promise<void> {
  const { db } = opts;
  app.addHook("preHandler", app.authenticate);
  app.addHook("preHandler", requireHousehold(db));

  app.get<{ Params: { id: string } }>(
    "/events/:id/media",
    { schema: { params: { type: "object", required: ["id"], properties: { id: { type: "string", format: "uuid" } } } } },
    async (request, reply) => {
      const [event] = await db
        .select({ clipKey: events.clipKey, snapshotKey: events.snapshotKey })
        .from(events)
        .where(and(eq(events.id, request.params.id), eq(events.householdId, request.household!.householdId)));
      if (!event) return reply.code(404).send({ error: "not_found" });
      if (!opts.storage) return reply.code(503).send({ error: "storage_not_configured" });
      const sign = (key: string | null) => (key ? opts.storage!.presignDownload(key, DOWNLOAD_URL_TTL_SECONDS) : null);
      const [clipUrl, snapshotUrl] = await Promise.all([sign(event.clipKey), sign(event.snapshotKey)]);
      return {
        clipUrl,
        snapshotUrl,
        expiresAt: new Date(Date.now() + DOWNLOAD_URL_TTL_SECONDS * 1000).toISOString(),
      };
    },
  );
}
