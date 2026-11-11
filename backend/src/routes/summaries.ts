import type { FastifyInstance } from "fastify";
import { and, desc, eq, gte, isNull, lte, type SQL } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { DOG_STATES, dailySummaries, events, type DogState } from "../db/schema.js";
import { requireHousehold } from "../households/scope.js";
import type { EventNotifier } from "../notifications/notifier.js";

interface SummaryBody {
  restMinutes: number;
  barkCount: number;
  activityByHour: number[];
  stateMinutes: Partial<Record<DogState, number>>;
  /** The day is over on the camera: send the "daily summary is ready" push (once). */
  final?: boolean;
}

const minutesOfDay = { type: "integer", minimum: 0, maximum: 1440 } as const;

function summaryDto(row: typeof dailySummaries.$inferSelect) {
  return {
    cameraId: row.deviceId,
    date: row.date,
    restMinutes: row.restMinutes,
    barkCount: row.barkCount,
    activityByHour: row.activityByHour,
    stateMinutes: row.stateMinutes,
    isFinal: row.notifiedAt !== null,
    /** The day's highlight reel is uploaded (`GET /summaries/:cameraId/:date/reel`). */
    hasReel: row.reelKey !== null,
    updatedAt: row.updatedAt.toISOString(),
  };
}

/** Cameras upload their day as it goes: `PUT /device/summaries/:date` (date in the camera's time zone). */
export async function cameraSummaryRoutes(app: FastifyInstance, opts: { db: Database; notifier: EventNotifier }): Promise<void> {
  const { db, notifier } = opts;
  app.addHook("preHandler", app.authenticateDevice);

  app.put<{ Params: { date: string }; Body: SummaryBody }>(
    "/device/summaries/:date",
    {
      schema: {
        params: { type: "object", required: ["date"], properties: { date: { type: "string", format: "date" } } },
        body: {
          type: "object",
          required: ["restMinutes", "barkCount", "activityByHour", "stateMinutes"],
          additionalProperties: false,
          properties: {
            restMinutes: minutesOfDay,
            barkCount: { type: "integer", minimum: 0, maximum: 100000 },
            activityByHour: { type: "array", minItems: 24, maxItems: 24, items: { type: "integer", minimum: 0, maximum: 60 } },
            stateMinutes: {
              type: "object",
              additionalProperties: false,
              properties: Object.fromEntries(DOG_STATES.map((state) => [state, minutesOfDay])),
            },
            final: { type: "boolean" },
          },
        },
      },
    },
    async (request) => {
      const { deviceId, householdId } = request.device!;
      const { date } = request.params;
      const { final, ...values } = request.body;
      const [row] = await db
        .insert(dailySummaries)
        .values({ householdId, deviceId, date, ...values, updatedAt: new Date() })
        .onConflictDoUpdate({ target: [dailySummaries.deviceId, dailySummaries.date], set: { ...values, updatedAt: new Date() } })
        .returning();

      if (final) {
        // Claim the push atomically so retries and races send it once.
        const [claimed] = await db
          .update(dailySummaries)
          .set({ notifiedAt: new Date() })
          .where(and(eq(dailySummaries.deviceId, deviceId), eq(dailySummaries.date, date), isNull(dailySummaries.notifiedAt)))
          .returning();
        if (claimed) {
          const now = new Date();
          const [event] = await db
            .insert(events)
            .values({ householdId, deviceId, type: "dailySummary", startedAt: now, endedAt: now })
            .returning();
          await notifier.notify({
            householdId,
            cameraId: deviceId,
            eventId: event!.id,
            type: "dailySummary",
            hasReel: claimed.reelKey !== null,
          });
          return summaryDto(claimed);
        }
      }
      return summaryDto(row!);
    },
  );
}

interface SummaryQuery {
  cameraId?: string;
  from?: string;
  to?: string;
}

/** Viewers read summaries: `GET /summaries?cameraId=&from=&to=` (newest first, up to 62 days). */
export async function viewerSummaryRoutes(app: FastifyInstance, opts: { db: Database }): Promise<void> {
  const { db } = opts;
  app.addHook("preHandler", app.authenticate);
  app.addHook("preHandler", requireHousehold(db));

  app.get<{ Querystring: SummaryQuery }>(
    "/summaries",
    {
      schema: {
        querystring: {
          type: "object",
          additionalProperties: false,
          properties: {
            cameraId: { type: "string", format: "uuid" },
            from: { type: "string", format: "date" },
            to: { type: "string", format: "date" },
          },
        },
      },
    },
    async (request) => {
      const { householdId } = request.household!;
      const { cameraId, from, to } = request.query;
      const filters: SQL[] = [eq(dailySummaries.householdId, householdId)];
      if (cameraId) filters.push(eq(dailySummaries.deviceId, cameraId));
      if (from) filters.push(gte(dailySummaries.date, from));
      if (to) filters.push(lte(dailySummaries.date, to));
      const rows = await db
        .select()
        .from(dailySummaries)
        .where(and(...filters))
        .orderBy(desc(dailySummaries.date))
        .limit(62);
      return { summaries: rows.map(summaryDto) };
    },
  );
}
