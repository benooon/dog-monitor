import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { dailySummaries, devices, dogs, events, householdMembers, households, notificationPrefs, users } from "../db/schema.js";
import { StorageUnavailableError, deleteHousehold } from "../households/delete.js";
import type { MediaStorage } from "../storage/storage.js";
import { RealtimeSessions } from "../realtime/sessions.js";

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
export async function accountRoutes(
  app: FastifyInstance,
  opts: { db: Database; storage?: MediaStorage; sessions?: RealtimeSessions },
): Promise<void> {
  const { db, storage } = opts;

  /**
   * `GET /me/export`: everything we hold about the caller as JSON (GDPR Art. 15 and 20, Israeli right of access).
   * Includes the household's dogs, cameras, events and daily summaries, without clips, snapshots or secrets.
   */
  app.get("/me/export", { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.user!.userId;
    const [user] = await db.select({ id: users.id, name: users.name, createdAt: users.createdAt }).from(users).where(eq(users.id, userId));
    if (!user) return reply.code(401).send({ error: "unauthorized" });
    const [membership] = await db
      .select({ householdId: householdMembers.householdId, role: householdMembers.role })
      .from(householdMembers)
      .where(eq(householdMembers.userId, userId));
    const prefs = await db
      .select({ deviceId: notificationPrefs.deviceId, eventType: notificationPrefs.eventType, enabled: notificationPrefs.enabled, quietStart: notificationPrefs.quietStart, quietEnd: notificationPrefs.quietEnd })
      .from(notificationPrefs)
      .where(eq(notificationPrefs.userId, userId));
    const base = { exportedAt: new Date().toISOString(), user, notificationPrefs: prefs };
    if (!membership) return { ...base, household: null };

    const hid = membership.householdId;
    const [household] = await db
      .select({ id: households.id, name: households.name, plan: households.plan, planExpiresAt: households.planExpiresAt, shareTrainingData: households.shareTrainingData, createdAt: households.createdAt })
      .from(households)
      .where(eq(households.id, hid));
    const members = await db
      .select({ userId: householdMembers.userId, name: users.name, role: householdMembers.role })
      .from(householdMembers)
      .innerJoin(users, eq(users.id, householdMembers.userId))
      .where(eq(householdMembers.householdId, hid));
    return {
      ...base,
      household: { ...household, role: membership.role, members },
      dogs: await db
        .select({ id: dogs.id, name: dogs.name, lifeStage: dogs.lifeStage, traits: dogs.traits, alertStyle: dogs.alertStyle, createdAt: dogs.createdAt })
        .from(dogs)
        .where(eq(dogs.householdId, hid)),
      devices: await db
        .select({ id: devices.id, name: devices.name, role: devices.role, model: devices.model, appVersion: devices.appVersion, status: devices.status, timeZone: devices.timeZone, createdAt: devices.createdAt })
        .from(devices)
        .where(eq(devices.householdId, hid)),
      events: await db
        .select({ id: events.id, deviceId: events.deviceId, type: events.type, state: events.state, startedAt: events.startedAt, endedAt: events.endedAt, confidence: events.confidence, feedback: events.feedback })
        .from(events)
        .where(eq(events.householdId, hid)),
      dailySummaries: await db
        .select({ deviceId: dailySummaries.deviceId, date: dailySummaries.date, restMinutes: dailySummaries.restMinutes, barkCount: dailySummaries.barkCount, activityByHour: dailySummaries.activityByHour, stateMinutes: dailySummaries.stateMinutes })
        .from(dailySummaries)
        .where(eq(dailySummaries.householdId, hid)),
    };
  });

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
    opts.sessions?.closeAll(RealtimeSessions.user(userId), "account_deleted");
    if (membership?.role === "owner") opts.sessions?.closeAll(RealtimeSessions.household(membership.householdId), "no_household");
    request.log.info("account deleted");
    return reply.code(204).send();
  });
}
