import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { and, eq } from "drizzle-orm";
import type { DbHandle } from "../src/db/client.js";
import {
  dailySummaries,
  devices,
  events,
  householdMembers,
  households,
  invites,
  notificationPrefs,
  users,
  zones,
} from "../src/db/schema.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

describe.skipIf(!hasDatabase)("database schema", () => {
  let h: DbHandle;

  beforeAll(() => {
    h = openTestDb();
  });
  afterAll(async () => {
    await h.close();
  });
  beforeEach(async () => {
    await truncateAll(h);
  });

  async function seedHousehold() {
    const [owner] = await h.db.insert(users).values({ appleSub: "apple-1", name: "Ben" }).returning();
    const [household] = await h.db.insert(households).values({ name: "Home", ownerId: owner!.id }).returning();
    await h.db.insert(householdMembers).values({ householdId: household!.id, userId: owner!.id, role: "owner" });
    const [camera] = await h.db
      .insert(devices)
      .values({ householdId: household!.id, name: "Living room", role: "camera" })
      .returning();
    return { owner: owner!, household: household!, camera: camera! };
  }

  it("creates a household with members, cameras and zones", async () => {
    const { household, camera } = await seedHousehold();
    expect(household.plan).toBe("free");
    expect(camera.status).toBe("active");

    await h.db.insert(zones).values({
      deviceId: camera.id,
      kind: "door",
      polygon: [
        { x: 0, y: 0 },
        { x: 0.5, y: 0 },
        { x: 0.5, y: 0.5 },
      ],
    });
    const [zone] = await h.db.select().from(zones).where(eq(zones.deviceId, camera.id));
    expect(zone!.polygon).toHaveLength(3);
  });

  it("stores events and cascades on household delete", async () => {
    const { household, camera } = await seedHousehold();
    await h.db.insert(events).values({
      householdId: household.id,
      deviceId: camera.id,
      type: "prolongedBarking",
      state: "barking",
      startedAt: new Date("2026-11-10T08:00:00Z"),
      confidence: 0.9,
    });
    await h.db.insert(dailySummaries).values({
      householdId: household.id,
      date: "2026-11-10",
      restMinutes: 300,
      barkCount: 12,
      activityByHour: Array.from({ length: 24 }, () => 0),
    });
    expect(await h.db.$count(events)).toBe(1);

    await h.db.delete(households).where(eq(households.id, household.id));
    expect(await h.db.$count(events)).toBe(0);
    expect(await h.db.$count(devices)).toBe(0);
    expect(await h.db.$count(dailySummaries)).toBe(0);
  });

  it("rejects duplicate Apple users", async () => {
    await h.db.insert(users).values({ appleSub: "dup" });
    await expect(h.db.insert(users).values({ appleSub: "dup" })).rejects.toThrow();
  });

  it("allows one notification pref per user, camera (or all cameras) and type", async () => {
    const { owner, camera } = await seedHousehold();
    await h.db.insert(notificationPrefs).values({ userId: owner.id, eventType: "atDoor", enabled: true });
    // Same user + type with null device (= all cameras) is a duplicate.
    await expect(
      h.db.insert(notificationPrefs).values({ userId: owner.id, eventType: "atDoor", enabled: false }),
    ).rejects.toThrow();
    // A camera-specific pref is fine.
    await h.db
      .insert(notificationPrefs)
      .values({ userId: owner.id, deviceId: camera.id, eventType: "atDoor", enabled: false, quietStart: "22:00", quietEnd: "07:00" });
    const prefs = await h.db
      .select()
      .from(notificationPrefs)
      .where(and(eq(notificationPrefs.userId, owner.id), eq(notificationPrefs.eventType, "atDoor")));
    expect(prefs).toHaveLength(2);
  });

  it("stores invites", async () => {
    const { owner, household } = await seedHousehold();
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
    await h.db.insert(invites).values({ token: "tok", code: "123456", householdId: household.id, createdBy: owner.id, expiresAt });
    const [invite] = await h.db.select().from(invites).where(eq(invites.token, "tok"));
    expect(invite!.usedAt).toBeNull();
    expect(invite!.expiresAt.getTime()).toBe(expiresAt.getTime());
  });
});
