import type { FastifyInstance } from "fastify";
import { and, eq, inArray } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { EVENT_TYPES, devices, notificationPrefs, type EventType } from "../db/schema.js";
import { requireHousehold } from "../households/scope.js";
import { enabledByDefault, interruptionLevel } from "../notifications/payload.js";

interface PrefInput {
  cameraId: string | null;
  eventType: EventType;
  enabled: boolean;
  quietStart?: string | null;
  quietEnd?: string | null;
}

const TIME_OF_DAY = "^([01]\\d|2[0-3]):[0-5]\\d$";

/** "HH:MM:SS" from Postgres → "HH:MM". */
function shortTime(value: string | null): string | null {
  return value ? value.slice(0, 5) : null;
}

/** The caller's push preferences (SPEC §5 per-viewer settings): `GET` / `PUT /notification-prefs`. */
export async function notificationPrefRoutes(app: FastifyInstance, opts: { db: Database }): Promise<void> {
  const { db } = opts;
  app.addHook("preHandler", app.authenticate);
  app.addHook("preHandler", requireHousehold(db));

  async function load(userId: string) {
    const rows = await db.select().from(notificationPrefs).where(eq(notificationPrefs.userId, userId));
    return {
      /** What applies when no preference row exists, and whether quiet hours can hold the type back. */
      types: EVENT_TYPES.map((type) => ({
        eventType: type,
        enabledByDefault: enabledByDefault(type),
        bypassesQuietHours: interruptionLevel(type) === "time-sensitive",
      })),
      prefs: rows.map((r) => ({
        cameraId: r.deviceId,
        eventType: r.eventType,
        enabled: r.enabled,
        quietStart: shortTime(r.quietStart),
        quietEnd: shortTime(r.quietEnd),
      })),
    };
  }

  app.get("/notification-prefs", async (request) => load(request.user!.userId));

  app.put<{ Body: { prefs: PrefInput[] } }>(
    "/notification-prefs",
    {
      schema: {
        body: {
          type: "object",
          required: ["prefs"],
          additionalProperties: false,
          properties: {
            prefs: {
              type: "array",
              maxItems: 200,
              items: {
                type: "object",
                required: ["cameraId", "eventType", "enabled"],
                additionalProperties: false,
                properties: {
                  cameraId: { type: ["string", "null"], format: "uuid" },
                  eventType: { type: "string", enum: [...EVENT_TYPES] },
                  enabled: { type: "boolean" },
                  quietStart: { type: ["string", "null"], pattern: TIME_OF_DAY },
                  quietEnd: { type: ["string", "null"], pattern: TIME_OF_DAY },
                },
              },
            },
          },
        },
      },
    },
    async (request, reply) => {
      const userId = request.user!.userId;
      const { householdId } = request.household!;
      const prefs = request.body.prefs;

      const seen = new Set<string>();
      for (const p of prefs) {
        const key = `${p.cameraId ?? "*"}|${p.eventType}`;
        if (seen.has(key)) return reply.code(400).send({ error: "duplicate_pref", key });
        seen.add(key);
        if (Boolean(p.quietStart) !== Boolean(p.quietEnd)) return reply.code(400).send({ error: "incomplete_quiet_hours" });
      }

      const cameraIds = [...new Set(prefs.map((p) => p.cameraId).filter((id): id is string => id !== null))];
      if (cameraIds.length > 0) {
        const cameras = await db
          .select({ id: devices.id })
          .from(devices)
          .where(and(inArray(devices.id, cameraIds), eq(devices.householdId, householdId), eq(devices.role, "camera")));
        if (cameras.length !== cameraIds.length) return reply.code(400).send({ error: "unknown_camera" });
      }

      await db.transaction(async (tx) => {
        await tx.delete(notificationPrefs).where(eq(notificationPrefs.userId, userId));
        if (prefs.length > 0) {
          await tx.insert(notificationPrefs).values(
            prefs.map((p) => ({
              userId,
              deviceId: p.cameraId,
              eventType: p.eventType,
              enabled: p.enabled,
              quietStart: p.quietStart ?? null,
              quietEnd: p.quietEnd ?? null,
            })),
          );
        }
      });
      return load(userId);
    },
  );
}
