import type { FastifyInstance } from "fastify";
import { and, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { DOG_STATES, events, type DogState, type EventType } from "../db/schema.js";
import type { EventNotifier } from "../notifications/notifier.js";
import { eventMediaPrefix } from "../storage/storage.js";

/** Event types a camera may report; cameraOffline and dailySummary are created by the server. */
export const CAMERA_EVENT_TYPES = [
  "prolongedBarking",
  "whining",
  "forbiddenZone",
  "atDoor",
  "notVisible",
  "calmedDown",
  "lowBattery",
  "overheating",
] as const satisfies readonly EventType[];

type EventRow = typeof events.$inferSelect;

export function eventDto(e: EventRow) {
  return {
    id: e.id,
    householdId: e.householdId,
    cameraId: e.deviceId,
    type: e.type,
    state: e.state,
    startedAt: e.startedAt,
    endedAt: e.endedAt,
    confidence: e.confidence,
    clipKey: e.clipKey,
    snapshotKey: e.snapshotKey,
    feedback: e.feedback,
  };
}

interface CreateBody {
  id: string;
  type: (typeof CAMERA_EVENT_TYPES)[number];
  state?: DogState | null;
  startedAt: string;
  endedAt?: string | null;
  confidence?: number | null;
  clipKey?: string | null;
  snapshotKey?: string | null;
}

interface UpdateBody {
  endedAt?: string | null;
  clipKey?: string | null;
  snapshotKey?: string | null;
  /** The event has lasted this long: push an escalation update ("barking for 5 minutes"). */
  escalationSeconds?: number;
}

const storageKey = { type: ["string", "null"], minLength: 1, maxLength: 300 } as const;

/** Media keys must be the ones `POST /device/uploads` handed out for this event. */
function keysBelongToEvent(prefix: string, ...keys: (string | null | undefined)[]): boolean {
  return keys.every((key) => key === undefined || key === null || (key.startsWith(prefix) && !key.includes("..")));
}

/** Camera-reported events (device auth): `POST /events`, `PATCH /events/:id`. */
export async function cameraEventRoutes(app: FastifyInstance, opts: { db: Database; notifier: EventNotifier }): Promise<void> {
  const { db, notifier } = opts;
  app.addHook("preHandler", app.authenticateDevice);

  app.post<{ Body: CreateBody }>(
    "/events",
    {
      schema: {
        body: {
          type: "object",
          required: ["id", "type", "startedAt"],
          additionalProperties: false,
          properties: {
            id: { type: "string", format: "uuid" },
            type: { type: "string", enum: [...CAMERA_EVENT_TYPES] },
            state: { type: ["string", "null"], enum: [...DOG_STATES, null] },
            startedAt: { type: "string", format: "date-time" },
            endedAt: { type: ["string", "null"], format: "date-time" },
            confidence: { type: ["number", "null"], minimum: 0, maximum: 1 },
            clipKey: storageKey,
            snapshotKey: storageKey,
          },
        },
      },
    },
    async (request, reply) => {
      const { deviceId, householdId } = request.device!;
      const body = request.body;
      if (!keysBelongToEvent(eventMediaPrefix(householdId, deviceId, body.id), body.clipKey, body.snapshotKey)) {
        return reply.code(400).send({ error: "invalid_media_key" });
      }
      // Idempotent on the client-generated id, so the camera's offline queue can retry safely.
      const [created] = await db
        .insert(events)
        .values({
          id: body.id,
          householdId,
          deviceId,
          type: body.type,
          state: body.state ?? null,
          startedAt: new Date(body.startedAt),
          endedAt: body.endedAt ? new Date(body.endedAt) : null,
          confidence: body.confidence ?? null,
          clipKey: body.clipKey ?? null,
          snapshotKey: body.snapshotKey ?? null,
        })
        .onConflictDoNothing({ target: events.id })
        .returning();

      if (!created) {
        const [existing] = await db
          .select()
          .from(events)
          .where(and(eq(events.id, body.id), eq(events.deviceId, deviceId)));
        if (!existing) return reply.code(409).send({ error: "id_conflict" });
        return reply.code(200).send(eventDto(existing));
      }

      await notifier.notify({ householdId, cameraId: deviceId, eventId: created.id, type: created.type, snapshotKey: created.snapshotKey });
      return reply.code(201).send(eventDto(created));
    },
  );

  app.patch<{ Params: { id: string }; Body: UpdateBody }>(
    "/events/:id",
    {
      schema: {
        params: { type: "object", required: ["id"], properties: { id: { type: "string", format: "uuid" } } },
        body: {
          type: "object",
          minProperties: 1,
          additionalProperties: false,
          properties: {
            endedAt: { type: ["string", "null"], format: "date-time" },
            clipKey: storageKey,
            snapshotKey: storageKey,
            escalationSeconds: { type: "number", minimum: 60, maximum: 24 * 3600 },
          },
        },
      },
    },
    async (request, reply) => {
      const { deviceId, householdId } = request.device!;
      const { escalationSeconds, endedAt, ...keys } = request.body;
      if (!keysBelongToEvent(eventMediaPrefix(householdId, deviceId, request.params.id), keys.clipKey, keys.snapshotKey)) {
        return reply.code(400).send({ error: "invalid_media_key" });
      }
      const changes = {
        ...keys,
        ...(endedAt !== undefined && { endedAt: endedAt === null ? null : new Date(endedAt) }),
      };
      const where = and(eq(events.id, request.params.id), eq(events.deviceId, deviceId));
      const [event] =
        Object.keys(changes).length > 0
          ? await db.update(events).set(changes).where(where).returning()
          : await db.select().from(events).where(where);
      if (!event) return reply.code(404).send({ error: "not_found" });

      if (escalationSeconds !== undefined) {
        await notifier.notify({
          householdId,
          cameraId: deviceId,
          eventId: event.id,
          type: event.type,
          snapshotKey: event.snapshotKey,
          escalationSeconds,
        });
      }
      return eventDto(event);
    },
  );
}
