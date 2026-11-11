import type { FastifyInstance } from "fastify";
import { HOUSEHOLD_MEMBER_USER_UNIQUE, isUniqueViolation } from "../db/errors.js";
import { and, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices, dogs, householdMembers, households, notificationPrefs, users, zones } from "../db/schema.js";
import { deviceDto, dogDto } from "../households/dto.js";
import { findMembership, requireHousehold, requireOwner } from "../households/scope.js";
import { effectivePlan } from "../billing/plans.js";
import { StorageUnavailableError, deleteHousehold } from "../households/delete.js";
import type { MediaStorage } from "../storage/storage.js";
import { RealtimeSessions } from "../realtime/sessions.js";

export async function householdRoutes(
  app: FastifyInstance,
  opts: { db: Database; storage?: MediaStorage; sessions?: RealtimeSessions },
): Promise<void> {
  const { db, storage } = opts;

  app.post<{ Body: { name: string } }>(
    "/households",
    {
      preHandler: app.authenticate,
      schema: {
        body: {
          type: "object",
          required: ["name"],
          additionalProperties: false,
          properties: { name: { type: "string", minLength: 1, maxLength: 100 } },
        },
      },
    },
    async (request, reply) => {
      const userId = request.user!.userId;
      if (await findMembership(db, userId)) {
        return reply.code(409).send({ error: "already_in_household" });
      }
      let household;
      try {
        household = await db.transaction(async (tx) => {
          const [created] = await tx.insert(households).values({ name: request.body.name, ownerId: userId }).returning();
          await tx.insert(householdMembers).values({ householdId: created!.id, userId, role: "owner" });
          return created!;
        });
      } catch (error) {
        // A concurrent create or invite accept won the race for this user.
        if (isUniqueViolation(error, HOUSEHOLD_MEMBER_USER_UNIQUE)) return reply.code(409).send({ error: "already_in_household" });
        throw error;
      }
      return reply.code(201).send({ id: household.id, name: household.name, plan: effectivePlan(household, new Date()), role: "owner" });
    },
  );

  app.get("/household", { preHandler: [app.authenticate, requireHousehold(db)] }, async (request) => {
    const { householdId, role } = request.household!;
    const [household] = await db.select().from(households).where(eq(households.id, householdId));
    const members = await db
      .select({ userId: users.id, name: users.name, role: householdMembers.role })
      .from(householdMembers)
      .innerJoin(users, eq(users.id, householdMembers.userId))
      .where(eq(householdMembers.householdId, householdId));
    const dogRows = await db.select().from(dogs).where(eq(dogs.householdId, householdId));
    const deviceRows = await db.select().from(devices).where(eq(devices.householdId, householdId));
    // Which zone kinds each camera has drawn, so viewers know e.g. whether a sofa zone exists.
    const zoneRows = await db
      .selectDistinct({ deviceId: zones.deviceId, kind: zones.kind })
      .from(zones)
      .innerJoin(devices, eq(devices.id, zones.deviceId))
      .where(eq(devices.householdId, householdId));
    const zoneKinds = new Map<string, string[]>();
    for (const row of zoneRows) {
      zoneKinds.set(row.deviceId, [...(zoneKinds.get(row.deviceId) ?? []), row.kind].sort());
    }
    return {
      id: household!.id,
      name: household!.name,
      plan: effectivePlan(household!, new Date()),
      ownerId: household!.ownerId,
      shareTrainingData: household!.shareTrainingData,
      role,
      members,
      dogs: dogRows.map(dogDto),
      devices: deviceRows.map((d) => ({ ...deviceDto(d), zoneKinds: zoneKinds.get(d.id) ?? [] })),
    };
  });

  /** Owner only: rename the household or change the training-data opt-in. */
  app.patch<{ Body: { name?: string; shareTrainingData?: boolean } }>(
    "/household",
    {
      preHandler: [app.authenticate, requireHousehold(db), requireOwner],
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          properties: { name: { type: "string", minLength: 1, maxLength: 100 }, shareTrainingData: { type: "boolean" } },
        },
      },
    },
    async (request) => {
      const { householdId } = request.household!;
      const [updated] = await db.update(households).set(request.body).where(eq(households.id, householdId)).returning();
      return { id: updated!.id, name: updated!.name, plan: effectivePlan(updated!, new Date()), shareTrainingData: updated!.shareTrainingData };
    },
  );

  /** Owner only: removes a member, signs out their phones (revoked) and drops their push settings. */
  app.delete<{ Params: { userId: string } }>(
    "/household/members/:userId",
    {
      preHandler: [app.authenticate, requireHousehold(db), requireOwner],
      schema: {
        params: { type: "object", required: ["userId"], properties: { userId: { type: "string", format: "uuid" } } },
      },
    },
    async (request, reply) => {
      const { householdId } = request.household!;
      const { userId } = request.params;
      const [member] = await db
        .select({ role: householdMembers.role })
        .from(householdMembers)
        .where(and(eq(householdMembers.householdId, householdId), eq(householdMembers.userId, userId)));
      if (!member) return reply.code(404).send({ error: "not_found" });
      if (member.role === "owner") return reply.code(400).send({ error: "cannot_remove_owner" });

      await db.transaction(async (tx) => {
        await tx
          .delete(householdMembers)
          .where(and(eq(householdMembers.householdId, householdId), eq(householdMembers.userId, userId)));
        await tx
          .update(devices)
          .set({ status: "revoked", apnsToken: null, deviceSecretHash: null })
          .where(and(eq(devices.householdId, householdId), eq(devices.userId, userId)));
        await tx.delete(notificationPrefs).where(eq(notificationPrefs.userId, userId));
      });
      opts.sessions?.closeAll(RealtimeSessions.user(userId), "no_household");
      return reply.code(204).send();
    },
  );

  /** Owner only: deletes the household with its dogs, cameras, events, summaries, invites and stored files. Members keep their accounts. */
  app.delete("/household", { preHandler: [app.authenticate, requireHousehold(db), requireOwner] }, async (request, reply) => {
    try {
      await deleteHousehold(db, storage, request.household!.householdId);
    } catch (err) {
      if (err instanceof StorageUnavailableError) return reply.code(503).send({ error: "storage_not_configured" });
      throw err;
    }
    opts.sessions?.closeAll(RealtimeSessions.household(request.household!.householdId), "no_household");
    return reply.code(204).send();
  });
}
