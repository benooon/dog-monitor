import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import type { DbHandle } from "../src/db/client.js";
import { dailySummaries, devices, events, households, mediaTombstones, users } from "../src/db/schema.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";
import { TOMBSTONE_KEEP_MS, purgeExpiredRecords, purgeMediaTombstones } from "../src/storage/retention.js";
import { FakeStorage } from "./helpers/storage.js";

describe.skipIf(!hasDatabase)("DELETE /me", () => {
  let h: DbHandle;
  let ctx: Awaited<ReturnType<typeof buildTestApp>>;
  let app: FastifyInstance;
  const storage = new FakeStorage();

  beforeAll(async () => {
    h = openTestDb();
    ctx = await buildTestApp(h, { storage });
    app = ctx.app;
  });
  afterAll(async () => {
    await app.close();
    await h.close();
  });
  beforeEach(async () => {
    await truncateAll(h);
    storage.deleted = [];
    storage.deletedPrefixes = [];
    storage.failPrefixDeletes = false;
  });

  async function signIn(sub: string) {
    const res = await app.inject({
      method: "POST",
      url: "/auth/apple",
      payload: { identityToken: await ctx.apple.sign({ sub }), nonce: TEST_NONCE, name: sub },
    });
    const body = res.json();
    return { userId: body.user.id as string, auth: { authorization: `Bearer ${body.token}` } };
  }

  async function ownerWithHousehold() {
    const owner = await signIn("owner");
    const created = await app.inject({ method: "POST", url: "/households", headers: owner.auth, payload: { name: "Home" } });
    return { ...owner, householdId: created.json().id as string };
  }

  it("requires sign-in", async () => {
    expect((await app.inject({ method: "DELETE", url: "/me" })).statusCode).toBe(401);
  });

  it("exports the caller's data without secrets or file keys", async () => {
    const { userId, auth, householdId } = await ownerWithHousehold();
    await h.db.insert(devices).values({ householdId, name: "Kitchen", role: "camera", apnsToken: "a".repeat(64), deviceSecretHash: "hash" });
    await h.db.insert(events).values({ householdId, type: "whining", startedAt: new Date(), clipKey: "secret-key" });

    const res = await app.inject({ method: "GET", url: "/me/export", headers: auth });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.user.id).toBe(userId);
    expect(body.household).toMatchObject({ name: "Home", role: "owner" });
    expect(body.devices).toHaveLength(1);
    expect(body.events).toHaveLength(1);
    const text = res.body;
    expect(text).not.toContain("secret-key");
    expect(text).not.toContain("hash");
    expect(text).not.toContain("a".repeat(64));
  });

  it("exports a user without a household, and requires sign-in", async () => {
    const { auth } = await signIn("lonely");
    expect((await app.inject({ method: "GET", url: "/me/export", headers: auth })).json().household).toBeNull();
    expect((await app.inject({ method: "GET", url: "/me/export" })).statusCode).toBe(401);
  });

  it("deletes a user who has no household", async () => {
    const { userId, auth } = await signIn("lonely");
    expect((await app.inject({ method: "DELETE", url: "/me", headers: auth })).statusCode).toBe(204);
    expect(await h.db.select().from(users).where(eq(users.id, userId))).toHaveLength(0);
  });

  it("deletes a lone owner's household, events and stored files", async () => {
    const { userId, auth, householdId } = await ownerWithHousehold();
    const [camera] = await h.db
      .insert(devices)
      .values({ householdId, name: "Kitchen", role: "camera" })
      .returning();
    await h.db.insert(events).values({
      householdId,
      deviceId: camera!.id,
      type: "prolongedBarking",
      startedAt: new Date(),
      clipKey: "clip-key",
      snapshotKey: "snap-key",
    });

    expect((await app.inject({ method: "DELETE", url: "/me", headers: auth })).statusCode).toBe(204);

    expect(storage.deleted.sort()).toEqual(["clip-key", "snap-key"]);
    expect(await h.db.select().from(households)).toHaveLength(0);
    expect(await h.db.select().from(events)).toHaveLength(0);
    expect(await h.db.select().from(devices)).toHaveLength(0);
    expect(await h.db.select().from(users).where(eq(users.id, userId))).toHaveLength(0);
    // The old token no longer works.
    expect((await app.inject({ method: "GET", url: "/me", headers: auth })).statusCode).toBe(401);
  });

  it("refuses to delete an owner while other members are in the household", async () => {
    const { auth, householdId } = await ownerWithHousehold();
    const member = await signIn("member");
    const { householdMembers } = await import("../src/db/schema.js");
    await h.db.insert(householdMembers).values({ householdId, userId: member.userId, role: "member" });

    const res = await app.inject({ method: "DELETE", url: "/me", headers: auth });
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: "household_has_members" });
    expect(await h.db.select().from(households)).toHaveLength(1);
    expect(storage.deleted).toEqual([]);
  });

  it("deletes a member and their phones but keeps the household", async () => {
    const { householdId } = await ownerWithHousehold();
    const member = await signIn("member");
    const { householdMembers } = await import("../src/db/schema.js");
    await h.db.insert(householdMembers).values({ householdId, userId: member.userId, role: "member" });
    await h.db.insert(devices).values({
      householdId,
      userId: member.userId,
      name: "Member phone",
      role: "viewer",
      apnsToken: "a".repeat(64),
    });

    expect((await app.inject({ method: "DELETE", url: "/me", headers: member.auth })).statusCode).toBe(204);

    expect(await h.db.select().from(devices)).toHaveLength(0);
    expect(await h.db.select().from(households)).toHaveLength(1);
    expect(await h.db.select().from(users).where(eq(users.id, member.userId))).toHaveLength(0);
  });

  describe("DELETE /household", () => {
    it("is owner only", async () => {
      const { householdId } = await ownerWithHousehold();
      const member = await signIn("member");
      const { householdMembers } = await import("../src/db/schema.js");
      await h.db.insert(householdMembers).values({ householdId, userId: member.userId, role: "member" });
      expect((await app.inject({ method: "DELETE", url: "/household", headers: member.auth })).statusCode).toBe(403);
      expect(await h.db.select().from(households)).toHaveLength(1);
    });

    it("removes the household and its files but keeps every account", async () => {
      const { userId, auth, householdId } = await ownerWithHousehold();
      const member = await signIn("member");
      const { householdMembers } = await import("../src/db/schema.js");
      await h.db.insert(householdMembers).values({ householdId, userId: member.userId, role: "member" });
      await h.db.insert(events).values({ householdId, type: "whining", startedAt: new Date(), clipKey: "c1" });

      expect((await app.inject({ method: "DELETE", url: "/household", headers: auth })).statusCode).toBe(204);

      expect(storage.deleted).toEqual(["c1"]);
      expect(await h.db.select().from(households)).toHaveLength(0);
      expect(await h.db.select().from(events)).toHaveLength(0);
      expect(await h.db.select().from(users).where(eq(users.id, userId))).toHaveLength(1);
      expect(await h.db.select().from(users).where(eq(users.id, member.userId))).toHaveLength(1);
    });

    // Security audit 2026-11, run 2: files uploaded during or after the delete are not in the key list.
    it("deletes the household's whole storage prefix and tombstones it for late uploads", async () => {
      const { auth, householdId } = await ownerWithHousehold();
      storage.failPrefixDeletes = true;
      expect((await app.inject({ method: "DELETE", url: "/household", headers: auth })).statusCode).toBe(204);
      const prefix = `households/${householdId}/`;
      expect(await h.db.select().from(mediaTombstones)).toMatchObject([{ prefix }]);

      storage.failPrefixDeletes = false;
      await purgeMediaTombstones(h.db, storage, new Date());
      expect(storage.deletedPrefixes).toEqual([prefix]);
      expect(await h.db.select().from(mediaTombstones)).toHaveLength(1);

      await purgeMediaTombstones(h.db, storage, new Date(Date.now() + TOMBSTONE_KEEP_MS + 60_000));
      expect(storage.deletedPrefixes).toEqual([prefix, prefix]);
      expect(await h.db.select().from(mediaTombstones)).toHaveLength(0);
    });
  });

  describe("record retention", () => {
    it("deletes old events and summaries, keeps recent ones and events that still have files", async () => {
      const { householdId } = await ownerWithHousehold();
      const [camera] = await h.db.insert(devices).values({ householdId, name: "Cam", role: "camera" }).returning();
      const now = new Date("2026-11-11T12:00:00Z");
      await h.db.insert(events).values([
        { householdId, type: "whining", startedAt: new Date("2025-01-01T00:00:00Z") },
        { householdId, type: "whining", startedAt: new Date("2025-01-01T00:00:00Z"), clipKey: "still-there" },
        { householdId, type: "whining", startedAt: new Date("2026-11-01T00:00:00Z") },
      ]);
      await h.db.insert(dailySummaries).values([
        { householdId, deviceId: camera!.id, date: "2025-01-01" },
        { householdId, deviceId: camera!.id, date: "2026-11-10" },
      ]);

      expect(await purgeExpiredRecords(h.db, 365, now)).toBe(2);

      expect(await h.db.select().from(events)).toHaveLength(2);
      expect(await h.db.select().from(dailySummaries)).toHaveLength(1);
    });
  });
});
