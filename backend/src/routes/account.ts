import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices, events, householdMembers, households, users } from "../db/schema.js";
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

    let mediaKeys: string[] = [];
    if (membership?.role === "owner") {
      const members = await db
        .select({ userId: householdMembers.userId })
        .from(householdMembers)
        .where(eq(householdMembers.householdId, membership.householdId));
      if (members.some((m) => m.userId !== userId)) {
        return reply.code(409).send({ error: "household_has_members" });
      }
      const rows = await db
        .select({ clipKey: events.clipKey, snapshotKey: events.snapshotKey })
        .from(events)
        .where(eq(events.householdId, membership.householdId));
      mediaKeys = rows.flatMap((r) => [r.clipKey, r.snapshotKey]).filter((k): k is string => k !== null);
      if (mediaKeys.length > 0 && !storage) return reply.code(503).send({ error: "storage_not_configured" });
    }

    // Files first: if this fails the account is untouched and the call can be repeated.
    if (storage && mediaKeys.length > 0) {
      for (let i = 0; i < mediaKeys.length; i += 1000) await storage.deleteObjects(mediaKeys.slice(i, i + 1000));
    }

    await db.transaction(async (tx) => {
      // Viewer phones keep their push token otherwise (devices.user_id only goes to null).
      await tx.delete(devices).where(eq(devices.userId, userId));
      if (membership?.role === "owner") {
        await tx.delete(households).where(eq(households.id, membership.householdId));
      }
      await tx.delete(users).where(eq(users.id, userId));
    });
    request.log.info("account deleted");
    return reply.code(204).send();
  });
}
