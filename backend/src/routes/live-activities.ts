import type { FastifyInstance } from "fastify";
import { and, eq, sql } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices, liveActivities } from "../db/schema.js";
import { requireHousehold } from "../households/scope.js";

const UUID = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";

/**
 * Viewers register the ActivityKit push token of a Live Activity showing one camera
 * (`PUT /live-activities`) and remove it when the activity ends (`DELETE /live-activities/:id`).
 */
export async function liveActivityRoutes(app: FastifyInstance, opts: { db: Database }): Promise<void> {
  const { db } = opts;
  app.addHook("preHandler", app.authenticate);
  app.addHook("preHandler", requireHousehold(db));

  app.put<{ Body: { cameraId: string; pushToken: string } }>(
    "/live-activities",
    {
      schema: {
        body: {
          type: "object",
          required: ["cameraId", "pushToken"],
          additionalProperties: false,
          properties: {
            cameraId: { type: "string", pattern: UUID },
            pushToken: { type: "string", pattern: "^[0-9a-fA-F]{16,512}$" },
          },
        },
      },
    },
    async (request, reply) => {
      const { householdId } = request.household!;
      const userId = request.user!.userId;
      const cameraId = request.body.cameraId.toLowerCase();
      const [camera] = await db
        .select({ id: devices.id })
        .from(devices)
        .where(
          and(
            eq(devices.id, cameraId),
            eq(devices.householdId, householdId),
            eq(devices.role, "camera"),
            eq(devices.status, "active"),
          ),
        );
      if (!camera) return reply.code(404).send({ error: "camera_not_found" });

      const pushToken = request.body.pushToken.toLowerCase();
      // iOS can hand the same token out again; it then belongs to the latest registration.
      const [row] = await db
        .insert(liveActivities)
        .values({ householdId, userId, cameraId, pushToken })
        .onConflictDoUpdate({
          target: liveActivities.pushToken,
          set: { householdId, userId, cameraId, createdAt: sql`now()` },
        })
        .returning({ id: liveActivities.id, cameraId: liveActivities.cameraId, createdAt: liveActivities.createdAt });
      return row;
    },
  );

  app.delete<{ Params: { id: string } }>(
    "/live-activities/:id",
    { schema: { params: { type: "object", properties: { id: { type: "string", pattern: UUID } } } } },
    async (request, reply) => {
      const deleted = await db
        .delete(liveActivities)
        .where(and(eq(liveActivities.id, request.params.id.toLowerCase()), eq(liveActivities.userId, request.user!.userId)))
        .returning({ id: liveActivities.id });
      if (deleted.length === 0) return reply.code(404).send({ error: "not_found" });
      return reply.code(204).send();
    },
  );
}
