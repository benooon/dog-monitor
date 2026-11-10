import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import type { DbHandle } from "../src/db/client.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

const APNS = "a".repeat(64);

describe.skipIf(!hasDatabase)("households, dogs and devices", () => {
  let h: DbHandle;
  let ctx: Awaited<ReturnType<typeof buildTestApp>>;
  let app: FastifyInstance;

  beforeAll(async () => {
    h = openTestDb();
    ctx = await buildTestApp(h);
    app = ctx.app;
  });
  afterAll(async () => {
    await app.close();
    await h.close();
  });
  beforeEach(async () => {
    await truncateAll(h);
  });

  async function signIn(sub: string, name = sub) {
    const res = await app.inject({
      method: "POST",
      url: "/auth/apple",
      payload: { identityToken: await ctx.apple.sign({ sub }), nonce: TEST_NONCE, name },
    });
    const body = res.json();
    return { userId: body.user.id as string, auth: { authorization: `Bearer ${body.token}` } };
  }

  async function createHousehold(auth: Record<string, string>, name = "Home") {
    return app.inject({ method: "POST", url: "/households", headers: auth, payload: { name } });
  }

  /** Adds `userId` to the owner's household directly (pairing/invites come later). */
  async function addMember(householdId: string, userId: string) {
    const { householdMembers } = await import("../src/db/schema.js");
    await h.db.insert(householdMembers).values({ householdId, userId, role: "member" });
  }

  it("creates a household with the caller as owner, once", async () => {
    const { userId, auth } = await signIn("owner");
    const res = await createHousehold(auth);
    expect(res.statusCode).toBe(201);
    expect(res.json()).toMatchObject({ name: "Home", role: "owner", plan: "free" });

    expect((await createHousehold(auth)).statusCode).toBe(409);

    const get = await app.inject({ method: "GET", url: "/household", headers: auth });
    expect(get.statusCode).toBe(200);
    expect(get.json()).toMatchObject({ ownerId: userId, members: [{ userId, role: "owner" }], dogs: [], devices: [] });
  });

  it("requires auth and a household", async () => {
    expect((await app.inject({ method: "GET", url: "/household" })).statusCode).toBe(401);
    const { auth } = await signIn("lonely");
    for (const url of ["/household", "/dogs", "/devices"]) {
      const res = await app.inject({ method: "GET", url, headers: auth });
      expect(res.statusCode, url).toBe(403);
      expect(res.json()).toEqual({ error: "no_household" });
    }
  });

  it("does CRUD on dogs", async () => {
    const { auth } = await signIn("owner");
    await createHousehold(auth);

    const created = await app.inject({ method: "POST", url: "/dogs", headers: auth, payload: { name: "Rex" } });
    expect(created.statusCode).toBe(201);
    const dog = created.json();
    expect(dog).toMatchObject({ name: "Rex", photoKey: null });

    const patched = await app.inject({
      method: "PATCH",
      url: `/dogs/${dog.id}`,
      headers: auth,
      payload: { name: "Rexy", photoKey: "dogs/rex.jpg" },
    });
    expect(patched.json()).toMatchObject({ id: dog.id, name: "Rexy", photoKey: "dogs/rex.jpg" });

    const list = await app.inject({ method: "GET", url: "/dogs", headers: auth });
    expect(list.json()).toHaveLength(1);

    expect((await app.inject({ method: "PATCH", url: `/dogs/${dog.id}`, headers: auth, payload: {} })).statusCode).toBe(400);
    expect((await app.inject({ method: "GET", url: "/dogs/not-a-uuid", headers: auth })).statusCode).toBe(400);
    expect((await app.inject({ method: "DELETE", url: `/dogs/${dog.id}`, headers: auth })).statusCode).toBe(204);
    expect((await app.inject({ method: "GET", url: `/dogs/${dog.id}`, headers: auth })).statusCode).toBe(404);
  });

  it("isolates households from each other", async () => {
    const a = await signIn("a");
    const b = await signIn("b");
    await createHousehold(a.auth, "A");
    await createHousehold(b.auth, "B");
    const dog = (await app.inject({ method: "POST", url: "/dogs", headers: a.auth, payload: { name: "Rex" } })).json();
    const device = (
      await app.inject({ method: "POST", url: "/devices", headers: a.auth, payload: { name: "Cam", role: "camera" } })
    ).json();

    expect((await app.inject({ method: "GET", url: `/dogs/${dog.id}`, headers: b.auth })).statusCode).toBe(404);
    expect(
      (await app.inject({ method: "PATCH", url: `/dogs/${dog.id}`, headers: b.auth, payload: { name: "Mine" } })).statusCode,
    ).toBe(404);
    expect((await app.inject({ method: "DELETE", url: `/dogs/${dog.id}`, headers: b.auth })).statusCode).toBe(404);
    expect((await app.inject({ method: "GET", url: "/dogs", headers: b.auth })).json()).toEqual([]);
    expect((await app.inject({ method: "GET", url: "/devices", headers: b.auth })).json()).toEqual([]);
    expect(
      (await app.inject({ method: "POST", url: `/devices/${device.id}/revoke`, headers: b.auth })).statusCode,
    ).toBe(404);
  });

  it("registers devices, updates the APNs token and never leaks secrets", async () => {
    const { userId, auth } = await signIn("owner");
    await createHousehold(auth);
    const res = await app.inject({
      method: "POST",
      url: "/devices",
      headers: auth,
      payload: { name: "Ben's iPhone", role: "viewer", model: "iPhone16,1", appVersion: "0.1.0" },
    });
    expect(res.statusCode).toBe(201);
    const device = res.json();
    expect(device).toMatchObject({ userId, role: "viewer", status: "active", hasPushToken: false });
    expect(device).not.toHaveProperty("deviceSecretHash");
    expect(device).not.toHaveProperty("apnsToken");

    const patched = await app.inject({
      method: "PATCH",
      url: `/devices/${device.id}`,
      headers: auth,
      payload: { apnsToken: APNS },
    });
    expect(patched.statusCode).toBe(200);
    expect(patched.json().hasPushToken).toBe(true);

    const badToken = await app.inject({
      method: "PATCH",
      url: `/devices/${device.id}`,
      headers: auth,
      payload: { apnsToken: "not hex!" },
    });
    expect(badToken.statusCode).toBe(400);
    expect((await app.inject({ method: "POST", url: "/devices", headers: auth, payload: { name: "x", role: "tv" } })).statusCode).toBe(400);
  });

  it("enforces the camera limit", async () => {
    const { auth } = await signIn("owner");
    await createHousehold(auth);
    for (let i = 0; i < 4; i++) {
      const res = await app.inject({ method: "POST", url: "/devices", headers: auth, payload: { name: `Cam ${i}`, role: "camera" } });
      expect(res.statusCode).toBe(201);
    }
    const fifth = await app.inject({ method: "POST", url: "/devices", headers: auth, payload: { name: "Cam 5", role: "camera" } });
    expect(fifth.statusCode).toBe(409);
    expect(fifth.json()).toMatchObject({ error: "camera_limit_reached", limit: 4 });
  });

  it("lets the owner remove a member, revoking their phones", async () => {
    const owner = await signIn("owner");
    const member = await signIn("member");
    const household = (await createHousehold(owner.auth)).json();
    await addMember(household.id, member.userId);
    const phone = (
      await app.inject({ method: "POST", url: "/devices", headers: member.auth, payload: { name: "Phone", role: "viewer", apnsToken: APNS } })
    ).json();

    const byMember = await app.inject({ method: "DELETE", url: `/household/members/${owner.userId}`, headers: member.auth });
    expect(byMember.statusCode).toBe(403);
    const self = await app.inject({ method: "DELETE", url: `/household/members/${owner.userId}`, headers: owner.auth });
    expect(self.statusCode).toBe(400);
    expect(self.json()).toEqual({ error: "cannot_remove_owner" });
    const unknown = await app.inject({
      method: "DELETE",
      url: "/household/members/00000000-0000-4000-8000-000000000000",
      headers: owner.auth,
    });
    expect(unknown.statusCode).toBe(404);

    const removed = await app.inject({ method: "DELETE", url: `/household/members/${member.userId}`, headers: owner.auth });
    expect(removed.statusCode).toBe(204);

    const after = (await app.inject({ method: "GET", url: "/household", headers: owner.auth })).json();
    expect(after.members).toEqual([expect.objectContaining({ userId: owner.userId })]);
    expect(after.devices.find((d: { id: string }) => d.id === phone.id)).toMatchObject({ status: "revoked", hasPushToken: false });
    expect((await app.inject({ method: "GET", url: "/household", headers: member.auth })).statusCode).toBe(403);
  });

  it("lets only the owner rename the household or change the training opt-in", async () => {
    const owner = await signIn("owner");
    const member = await signIn("member");
    const household = (await createHousehold(owner.auth)).json();
    await addMember(household.id, member.userId);
    expect((await app.inject({ method: "GET", url: "/household", headers: owner.auth })).json().shareTrainingData).toBe(false);

    const denied = await app.inject({ method: "PATCH", url: "/household", headers: member.auth, payload: { name: "Mine" } });
    expect(denied.statusCode).toBe(403);
    expect((await app.inject({ method: "PATCH", url: "/household", headers: owner.auth, payload: {} })).statusCode).toBe(400);
    const renamed = await app.inject({ method: "PATCH", url: "/household", headers: owner.auth, payload: { name: "Beach house" } });
    expect(renamed.json()).toMatchObject({ name: "Beach house", shareTrainingData: false });
  });

  it("lets only the owner revoke, and only the device's user or owner update", async () => {
    const owner = await signIn("owner");
    const member = await signIn("member");
    const household = (await createHousehold(owner.auth)).json();
    await addMember(household.id, member.userId);

    const ownerDevice = (
      await app.inject({ method: "POST", url: "/devices", headers: owner.auth, payload: { name: "Cam", role: "camera", apnsToken: APNS } })
    ).json();
    const memberDevice = (
      await app.inject({ method: "POST", url: "/devices", headers: member.auth, payload: { name: "Phone", role: "viewer" } })
    ).json();

    expect(
      (await app.inject({ method: "PATCH", url: `/devices/${ownerDevice.id}`, headers: member.auth, payload: { name: "x" } }))
        .statusCode,
    ).toBe(403);
    expect(
      (await app.inject({ method: "PATCH", url: `/devices/${memberDevice.id}`, headers: owner.auth, payload: { name: "Kid's phone" } }))
        .statusCode,
    ).toBe(200);

    const denied = await app.inject({ method: "POST", url: `/devices/${ownerDevice.id}/revoke`, headers: member.auth });
    expect(denied.statusCode).toBe(403);
    expect(denied.json()).toEqual({ error: "owner_only" });

    const revoked = await app.inject({ method: "POST", url: `/devices/${ownerDevice.id}/revoke`, headers: owner.auth });
    expect(revoked.statusCode).toBe(200);
    expect(revoked.json()).toMatchObject({ status: "revoked", hasPushToken: false });

    const afterRevoke = await app.inject({
      method: "PATCH",
      url: `/devices/${ownerDevice.id}`,
      headers: owner.auth,
      payload: { apnsToken: APNS },
    });
    expect(afterRevoke.statusCode).toBe(409);

    // The member sees the household with both devices.
    const view = (await app.inject({ method: "GET", url: "/household", headers: member.auth })).json();
    expect(view.role).toBe("member");
    expect(view.devices).toHaveLength(2);
    expect(view.members).toHaveLength(2);
  });
});
