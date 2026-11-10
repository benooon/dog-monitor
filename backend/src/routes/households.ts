import type { FastifyInstance } from "fastify";
import { and, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices, dogs, householdMembers, households, notificationPrefs, users } from "../db/schema.js";
import { deviceDto, dogDto } from "../households/dto.js";
import { findMembership, requireHousehold, requireOwner } from "../households/scope.js";

export async function householdRoutes(app: FastifyInstance, opts: { db: Database }): Promise<void> {
  const { db } = opts;

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
      const household = await db.transaction(async (tx) => {
        const [created] = await tx.insert(households).values({ name: request.body.name, ownerId: userId }).returning();
        await tx.insert(householdMembers).values({ householdId: created!.id, userId, role: "owner" });
        return created!;
      });
      return reply.code(201).send({ id: household.id, name: household.name, plan: household.plan, role: "owner" });
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
    return {
      id: household!.id,
      name: household!.name,
      plan: household!.plan,
      ownerId: household!.ownerId,
      role,
      members,
      dogs: dogRows.map(dogDto),
      devices: deviceRows.map(deviceDto),
    };
  });

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
      return reply.code(204).send();
    },
  );
}
