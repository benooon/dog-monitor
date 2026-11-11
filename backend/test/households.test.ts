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

  it("creates households one at a time per user, even concurrently", async () => {
    const { userId, auth } = await signIn("double");
    const results = await Promise.all([createHousehold(auth, "A"), createHousehold(auth, "B"), createHousehold(auth, "C")]);
    expect(results.map((r) => r.statusCode).sort()).toEqual([201, 409, 409]);
    const { householdMembers } = await import("../src/db/schema.js");
    const { eq } = await import("drizzle-orm");
    expect(await h.db.select().from(householdMembers).where(eq(householdMembers.userId, userId))).toHaveLength(1);
  });

  it("caps dogs per household, even concurrently", async () => {
    const { auth } = await signIn("dogs");
    await createHousehold(auth);
    const results = await Promise.all(
      Array.from({ length: 12 }, (_, i) => app.inject({ method: "POST", url: "/dogs", headers: auth, payload: { name: `Dog ${i}` } })),
    );
    expect(results.filter((r) => r.statusCode === 201)).toHaveLength(10);
    const refused = results.find((r) => r.statusCode === 409)!;
    expect(refused.json()).toEqual({ error: "dog_limit_reached", limit: 10 });
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

  it("stores the dog's profile from onboarding", async () => {
    const { auth } = await signIn("owner");
    await createHousehold(auth);

    const created = await app.inject({
      method: "POST",
      url: "/dogs",
      headers: auth,
      payload: { name: "Rex", lifeStage: "adult", traits: ["barksAtNoises", "waitsAtDoor"], alertStyle: "balanced" },
    });
    expect(created.statusCode).toBe(201);
    const dog = created.json();
    expect(dog).toMatchObject({
      lifeStage: "adult",
      traits: ["barksAtNoises", "waitsAtDoor"],
      alertStyle: "balanced",
      photoUpdatedAt: null,
    });

    const plain = (await app.inject({ method: "POST", url: "/dogs", headers: auth, payload: { name: "Bella" } })).json();
    expect(plain).toMatchObject({ lifeStage: null, traits: [], alertStyle: null });

    const patched = await app.inject({
      method: "PATCH",
      url: `/dogs/${dog.id}`,
      headers: auth,
      payload: { traits: ["mostlySleeps"], alertStyle: "important", lifeStage: null },
    });
    expect(patched.json()).toMatchObject({ traits: ["mostlySleeps"], alertStyle: "important", lifeStage: null, name: "Rex" });

    const household = (await app.inject({ method: "GET", url: "/household", headers: auth })).json();
    expect(household.dogs.find((d: { id: string }) => d.id === dog.id)).toMatchObject({ traits: ["mostlySleeps"] });

    for (const payload of [
      { traits: ["chasesCats"] },
      { traits: ["whines", "whines"] },
      { lifeStage: "teen" },
      { alertStyle: "loud" },
    ]) {
      const res = await app.inject({ method: "PATCH", url: `/dogs/${dog.id}`, headers: auth, payload });
      expect(res.statusCode, JSON.stringify(payload)).toBe(400);
    }
  });

  it("stores, serves and removes the dog's photo", async () => {
    const a = await signIn("a");
    const b = await signIn("b");
    await createHousehold(a.auth, "A");
    await createHousehold(b.auth, "B");
    const dog = (await app.inject({ method: "POST", url: "/dogs", headers: a.auth, payload: { name: "Rex" } })).json();
    const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(2048, 7)]);
    const put = (headers: Record<string, string>, body: Buffer, id = dog.id, type = "image/jpeg") =>
      app.inject({ method: "PUT", url: `/dogs/${id}/photo`, headers: { ...headers, "content-type": type }, payload: body });

    expect((await app.inject({ method: "GET", url: `/dogs/${dog.id}/photo`, headers: a.auth })).statusCode).toBe(404);

    const stored = await put(a.auth, jpeg);
    expect(stored.statusCode).toBe(200);
    expect(stored.json().photoUpdatedAt).toEqual(expect.any(String));

    const got = await app.inject({ method: "GET", url: `/dogs/${dog.id}/photo`, headers: a.auth });
    expect(got.statusCode).toBe(200);
    expect(got.headers["content-type"]).toBe("image/jpeg");
    expect(got.rawPayload.equals(jpeg)).toBe(true);

    // Replacing keeps one photo.
    const second = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xdb]), Buffer.alloc(16, 1)]);
    expect((await put(a.auth, second)).statusCode).toBe(200);
    const again = await app.inject({ method: "GET", url: `/dogs/${dog.id}/photo`, headers: a.auth });
    expect(again.rawPayload.equals(second)).toBe(true);

    // Not a JPEG, too large, wrong household.
    expect((await put(a.auth, Buffer.from("not an image"))).statusCode).toBe(415);
    expect((await put(a.auth, Buffer.from("{}"), dog.id, "application/json")).statusCode).toBe(415);
    const huge = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(600 * 1024)]);
    expect((await put(a.auth, huge)).statusCode).toBe(413);
    expect((await put(b.auth, jpeg)).statusCode).toBe(404);
    expect((await app.inject({ method: "GET", url: `/dogs/${dog.id}/photo`, headers: b.auth })).statusCode).toBe(404);

    const removed = await app.inject({ method: "DELETE", url: `/dogs/${dog.id}/photo`, headers: a.auth });
    expect(removed.json()).toMatchObject({ photoUpdatedAt: null });
    expect((await app.inject({ method: "GET", url: `/dogs/${dog.id}/photo`, headers: a.auth })).statusCode).toBe(404);
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

  it("lets only the owner turn on end-to-end encrypted live video, and never off", async () => {
    const owner = await signIn("owner");
    const member = await signIn("member");
    const household = (await createHousehold(owner.auth)).json();
    await addMember(household.id, member.userId);
    expect((await app.inject({ method: "GET", url: "/household", headers: member.auth })).json().liveEncrypted).toBe(false);

    const patch = (auth: Record<string, string>, liveEncrypted: boolean) =>
      app.inject({ method: "PATCH", url: "/household", headers: auth, payload: { liveEncrypted } });
    expect((await patch(member.auth, true)).statusCode).toBe(403);
    const on = await patch(owner.auth, true);
    expect(on.statusCode).toBe(200);
    expect(on.json()).toMatchObject({ liveEncrypted: true });
    expect((await patch(owner.auth, false)).statusCode).toBe(400);
    expect((await app.inject({ method: "GET", url: "/household", headers: member.auth })).json().liveEncrypted).toBe(true);
  });

  it("asks the owner's phone for a new live key when someone holding it leaves", async () => {
    const owner = await signIn("owner");
    const member = await signIn("member");
    const household = (await createHousehold(owner.auth)).json();
    await addMember(household.id, member.userId);
    const get = async () => (await app.inject({ method: "GET", url: "/household", headers: owner.auth })).json();
    const patch = (auth: Record<string, string>, payload: object) =>
      app.inject({ method: "PATCH", url: "/household", headers: auth, payload });
    const camera = (
      await app.inject({ method: "POST", url: "/devices", headers: owner.auth, payload: { name: "Cam", role: "camera" } })
    ).json();

    // Not encrypted yet: revoking changes nothing about keys.
    await app.inject({ method: "POST", url: `/devices/${camera.id}/revoke`, headers: owner.auth });
    expect(await get()).toMatchObject({ liveKeyId: null, liveKeyRotationNeeded: false });

    expect((await patch(owner.auth, { liveEncrypted: true, liveKeyId: "first-key-id" })).json()).toMatchObject({
      liveEncrypted: true,
      liveKeyId: "first-key-id",
      liveKeyRotationNeeded: false,
    });
    expect((await patch(member.auth, { liveKeyId: "members-key" })).statusCode).toBe(403);
    expect((await patch(owner.auth, { liveKeyId: "short" })).statusCode).toBe(400);
    expect((await patch(owner.auth, { liveKeyId: "has spaces in it" })).statusCode).toBe(400);

    // Revoking an already revoked device doesn't ask again.
    await app.inject({ method: "POST", url: `/devices/${camera.id}/revoke`, headers: owner.auth });
    expect((await get()).liveKeyRotationNeeded).toBe(false);

    const removed = await app.inject({ method: "DELETE", url: `/household/members/${member.userId}`, headers: owner.auth });
    expect(removed.statusCode).toBe(204);
    expect(await get()).toMatchObject({ liveKeyId: "first-key-id", liveKeyRotationNeeded: true });

    // The owner's phone made a new key: sending its id clears the flag.
    expect((await patch(owner.auth, { liveEncrypted: true, liveKeyId: "second-key-id" })).json()).toMatchObject({
      liveKeyId: "second-key-id",
      liveKeyRotationNeeded: false,
    });

    const camera2 = (
      await app.inject({ method: "POST", url: "/devices", headers: owner.auth, payload: { name: "Cam 2", role: "camera" } })
    ).json();
    await app.inject({ method: "POST", url: `/devices/${camera2.id}/revoke`, headers: owner.auth });
    expect((await get()).liveKeyRotationNeeded).toBe(true);
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
