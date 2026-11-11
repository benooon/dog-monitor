import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import type { DbHandle } from "../src/db/client.js";
import { devices, events, households, users } from "../src/db/schema.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";
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
});
