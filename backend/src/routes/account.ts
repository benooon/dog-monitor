import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices, householdMembers, users } from "../db/schema.js";
import { StorageUnavailableError, deleteHousehold } from "../households/delete.js";
import type { MediaStorage } from "../storage/storage.js";

/**
 * `DELETE /me`: permanently deletes the caller's account (App Store Guideline 5.1.1(v), GDPR Art. 17).
 *
 * - A member: their membership, phones (push tokens), push settings and Live Activities go.
 * - An owner living alone in the household: the whole household goes, with its dogs, cameras,
 *   events, daily summaries, and every stored clip and snapshot.
 * - An owner with other members: refused (409), so nobody else loses their household by surprise.
 *   The owner removes the members first (or they leave).
 *
 * Apple subscriptions are managed by Apple and are not cancelled here.
 */
export async function accountRoutes(app: FastifyInstance, opts: { db: Database; storage?: MediaStorage }): Promise<void> {
  const { db, storage } = opts;

  app.delete("/me", { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.user!.userId;
    const [user] = await db.select({ id: users.id }).from(users).where(eq(users.id, userId));
    if (!user) return reply.code(401).send({ error: "unauthorized" });

    const [membership] = await db
      .select({ householdId: householdMembers.householdId, role: householdMembers.role })
      .from(householdMembers)
      .where(eq(householdMembers.userId, userId));

    if (membership?.role === "owner") {
      const members = await db
        .select({ userId: householdMembers.userId })
        .from(householdMembers)
        .where(eq(householdMembers.householdId, membership.householdId));
      if (members.some((m) => m.userId !== userId)) {
        return reply.code(409).send({ error: "household_has_members" });
      }
    }

    // Viewer phones keep their push token otherwise (devices.user_id only goes to null).
    const removeUser = async (tx: Pick<Database, "delete">) => {
      await tx.delete(devices).where(eq(devices.userId, userId));
      await tx.delete(users).where(eq(users.id, userId));
    };
    try {
      if (membership?.role === "owner") {
        // The household row references the owner, so it goes first (and its files before that).
        await deleteHousehold(db, storage, membership.householdId, removeUser);
      } else {
        await db.transaction(removeUser);
      }
    } catch (err) {
      if (err instanceof StorageUnavailableError) return reply.code(503).send({ error: "storage_not_configured" });
      throw err;
    }
    request.log.info("account deleted");
    return reply.code(204).send();
  });
}
