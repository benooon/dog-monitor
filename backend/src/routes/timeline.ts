import type { FastifyInstance } from "fastify";
import { and, desc, eq, inArray, lt, or, type SQL } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { EVENT_TYPES, events, type EventType } from "../db/schema.js";
import { requireHousehold } from "../households/scope.js";
import { eventDto } from "./events.js";

export const TIMELINE_DEFAULT_LIMIT = 50;
export const TIMELINE_MAX_LIMIT = 100;

/** Opaque page cursor: `<startedAt ISO>_<event id>` of the last event on the previous page. */
export function encodeCursor(startedAt: Date, id: string): string {
  return `${startedAt.toISOString()}_${id}`;
}

export function decodeCursor(cursor: string): { startedAt: Date; id: string } | null {
  const separator = cursor.lastIndexOf("_");
  if (separator <= 0) return null;
  const startedAt = new Date(cursor.slice(0, separator));
  const id = cursor.slice(separator + 1);
  if (Number.isNaN(startedAt.getTime()) || !/^[0-9a-f-]{36}$/i.test(id)) return null;
  return { startedAt, id: id.toLowerCase() };
}

interface TimelineQuery {
  cameraId?: string;
  /** Comma-separated event types. */
  types?: string;
  cursor?: string;
  limit?: number;
}

/** Viewer timeline (SPEC §8): `GET /events` and `PUT /events/:id/feedback`. */
export async function timelineRoutes(app: FastifyInstance, opts: { db: Database }): Promise<void> {
  const { db } = opts;
  app.addHook("preHandler", app.authenticate);
  app.addHook("preHandler", requireHousehold(db));

  app.get<{ Querystring: TimelineQuery }>(
    "/events",
    {
      schema: {
        querystring: {
          type: "object",
          additionalProperties: false,
          properties: {
            cameraId: { type: "string", format: "uuid" },
            types: { type: "string", maxLength: 500 },
            cursor: { type: "string", maxLength: 100 },
            limit: { type: "integer", minimum: 1, maximum: TIMELINE_MAX_LIMIT },
          },
        },
      },
    },
    async (request, reply) => {
      const { cameraId, types, cursor, limit = TIMELINE_DEFAULT_LIMIT } = request.query;
      const filters: SQL[] = [eq(events.householdId, request.household!.householdId)];

      if (cameraId) filters.push(eq(events.deviceId, cameraId));

      if (types !== undefined) {
        const requested = types.split(",").map((t) => t.trim()).filter((t) => t.length > 0);
        if (requested.length === 0 || requested.some((t) => !(EVENT_TYPES as readonly string[]).includes(t))) {
          return reply.code(400).send({ error: "invalid_types" });
        }
        filters.push(inArray(events.type, requested as EventType[]));
      }

      if (cursor !== undefined) {
        const position = decodeCursor(cursor);
        if (!position) return reply.code(400).send({ error: "invalid_cursor" });
        filters.push(
          or(
            lt(events.startedAt, position.startedAt),
            and(eq(events.startedAt, position.startedAt), lt(events.id, position.id)),
          )!,
        );
      }

      const rows = await db
        .select()
        .from(events)
        .where(and(...filters))
        .orderBy(desc(events.startedAt), desc(events.id))
        .limit(limit + 1);
      const page = rows.slice(0, limit);
      const last = page.at(-1);
      return {
        events: page.map(eventDto),
        nextCursor: rows.length > limit && last ? encodeCursor(last.startedAt, last.id) : null,
      };
    },
  );

  app.put<{ Params: { id: string }; Body: { feedback: "correct" | "wrong" | null } }>(
    "/events/:id/feedback",
    {
      schema: {
        params: { type: "object", required: ["id"], properties: { id: { type: "string", format: "uuid" } } },
        body: {
          type: "object",
          required: ["feedback"],
          additionalProperties: false,
          properties: { feedback: { type: ["string", "null"], enum: ["correct", "wrong", null] } },
        },
      },
    },
    async (request, reply) => {
      const [event] = await db
        .update(events)
        .set({ feedback: request.body.feedback })
        .where(and(eq(events.id, request.params.id), eq(events.householdId, request.household!.householdId)))
        .returning();
      if (!event) return reply.code(404).send({ error: "not_found" });
      return eventDto(event);
    },
  );
}
