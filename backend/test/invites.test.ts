import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import type { DbHandle } from "../src/db/client.js";
import { invites } from "../src/db/schema.js";
import { AttemptLimiter } from "../src/pairing/attempt-limiter.js";
import { parseDeviceAuthorization } from "../src/auth/device-plugin.js";
import { hashSecret, newInviteCode, secretMatches } from "../src/pairing/secrets.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

describe("pairing helpers", () => {
  it("makes 6-digit codes", () => {
    for (let i = 0; i < 100; i++) expect(newInviteCode()).toMatch(/^\d{6}$/);
  });

  it("matches secrets by hash", () => {
    const hash = hashSecret("s3cret");
    expect(secretMatches("s3cret", hash)).toBe(true);
    expect(secretMatches("other", hash)).toBe(false);
    expect(secretMatches("s3cret", "abcd")).toBe(false);
  });

  it("parses device authorization headers", () => {
    const id = "6f1c2d3e-4a5b-4c6d-8e7f-001122334455";
    expect(parseDeviceAuthorization(`Device ${id}:abc`)).toEqual({ deviceId: id, secret: "abc" });
    expect(parseDeviceAuthorization(`Bearer ${id}:abc`)).toBeNull();
    expect(parseDeviceAuthorization(`Device not-a-uuid:abc`)).toBeNull();
    expect(parseDeviceAuthorization(`Device ${id}:`)).toBeNull();
    expect(parseDeviceAuthorization(undefined)).toBeNull();
  });

  it("limits failures within a window", () => {
    let t = 0;
    const limiter = new AttemptLimiter(3, 1000, () => t);
    for (let i = 0; i < 3; i++) limiter.recordFailure("ip");
    expect(limiter.isBlocked("ip")).toBe(true);
    expect(limiter.isBlocked("other")).toBe(false);
    t = 1001;
    expect(limiter.isBlocked("ip")).toBe(false);
  });
});

describe.skipIf(!hasDatabase)("invites and device auth", () => {
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
    const household = (await app.inject({ method: "POST", url: "/households", headers: owner.auth, payload: { name: "Home" } })).json();
    return { ...owner, householdId: household.id as string };
  }

  async function createInvite(auth: Record<string, string>) {
    const res = await app.inject({ method: "POST", url: "/invites", headers: auth });
    expect(res.statusCode).toBe(201);
    return res.json() as { token: string; code: string; expiresAt: string };
  }

  const acceptCamera = (token: string, deviceName = "Living room") =>
    app.inject({ method: "POST", url: `/invites/${token}/accept`, payload: { as: "camera", deviceName, model: "iPhone12,1" } });

  it("creates a 10-minute invite with a token and a 6-digit code (owner only)", async () => {
    const owner = await ownerWithHousehold();
    const invite = await createInvite(owner.auth);
    expect(invite.code).toMatch(/^\d{6}$/);
    expect(invite.token.length).toBeGreaterThanOrEqual(32);
    const ttl = new Date(invite.expiresAt).getTime() - Date.now();
    expect(ttl).toBeGreaterThan(9 * 60 * 1000);
    expect(ttl).toBeLessThanOrEqual(10 * 60 * 1000);

    const member = await signIn("member");
    const join = await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, headers: member.auth, payload: { as: "member" } });
    expect(join.statusCode).toBe(200);
    expect((await app.inject({ method: "POST", url: "/invites", headers: member.auth })).statusCode).toBe(403);
  });

  it("pairs a camera that then authenticates with its device secret", async () => {
    const owner = await ownerWithHousehold();
    const invite = await createInvite(owner.auth);
    const res = await acceptCamera(invite.token);
    expect(res.statusCode).toBe(201);
    const { device, deviceSecret, householdId } = res.json();
    expect(householdId).toBe(owner.householdId);
    expect(device).toMatchObject({ role: "camera", userId: null, name: "Living room" });
    expect(typeof deviceSecret).toBe("string");

    const me = await app.inject({ method: "GET", url: "/device/me", headers: { authorization: `Device ${device.id}:${deviceSecret}` } });
    expect(me.statusCode).toBe(200);
    expect(me.json().id).toBe(device.id);

    const wrong = await app.inject({ method: "GET", url: "/device/me", headers: { authorization: `Device ${device.id}:nope` } });
    expect(wrong.statusCode).toBe(401);
    // A user JWT is not device auth.
    expect((await app.inject({ method: "GET", url: "/device/me", headers: owner.auth })).statusCode).toBe(401);

    // Revoking the device kills its credentials.
    await app.inject({ method: "POST", url: `/devices/${device.id}/revoke`, headers: owner.auth });
    const revoked = await app.inject({ method: "GET", url: "/device/me", headers: { authorization: `Device ${device.id}:${deviceSecret}` } });
    expect(revoked.statusCode).toBe(401);
  });

  it("accepts the 6-digit code instead of the token", async () => {
    const owner = await ownerWithHousehold();
    const invite = await createInvite(owner.auth);
    expect((await acceptCamera(invite.code)).statusCode).toBe(201);
  });

  it("is single-use", async () => {
    const owner = await ownerWithHousehold();
    const invite = await createInvite(owner.auth);
    expect((await acceptCamera(invite.token)).statusCode).toBe(201);
    const again = await acceptCamera(invite.token);
    expect(again.statusCode).toBe(404);
    expect(again.json()).toEqual({ error: "invalid_or_expired_invite" });
    expect((await acceptCamera(invite.code)).statusCode).toBe(404);
  });

  it("rejects expired invites", async () => {
    const owner = await ownerWithHousehold();
    const invite = await createInvite(owner.auth);
    await h.db.update(invites).set({ expiresAt: new Date(Date.now() - 1000) }).where(eq(invites.token, invite.token));
    expect((await acceptCamera(invite.token)).statusCode).toBe(404);
  });

  it("requires sign-in to join as a member and rejects users already in a household", async () => {
    const owner = await ownerWithHousehold();
    const invite = await createInvite(owner.auth);
    const anon = await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, payload: { as: "member" } });
    expect(anon.statusCode).toBe(401);
    const self = await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, headers: owner.auth, payload: { as: "member" } });
    expect(self.statusCode).toBe(409);
    // Neither attempt consumed the invite.
    expect((await acceptCamera(invite.token)).statusCode).toBe(201);
  });

  it("validates the body", async () => {
    const owner = await ownerWithHousehold();
    const invite = await createInvite(owner.auth);
    for (const payload of [{}, { as: "camera" }, { as: "admin" }, { as: "member", deviceName: "x" }]) {
      const res = await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, payload });
      expect(res.statusCode, JSON.stringify(payload)).toBe(400);
    }
  });

  it("enforces the member limit without consuming the invite", async () => {
    const owner = await ownerWithHousehold();
    for (let i = 0; i < 5; i++) {
      const u = await signIn(`m${i}`);
      const inv = await createInvite(owner.auth);
      expect((await app.inject({ method: "POST", url: `/invites/${inv.token}/accept`, headers: u.auth, payload: { as: "member" } })).statusCode).toBe(200);
    }
    const seventh = await signIn("m6");
    const inv = await createInvite(owner.auth);
    const res = await app.inject({ method: "POST", url: `/invites/${inv.token}/accept`, headers: seventh.auth, payload: { as: "member" } });
    expect(res.statusCode).toBe(409);
    expect(res.json()).toMatchObject({ error: "member_limit_reached", limit: 6 });
    const [row] = await h.db.select().from(invites).where(eq(invites.token, inv.token));
    expect(row!.usedAt).toBeNull();
  });
});

describe.skipIf(!hasDatabase)("invite brute-force protection", () => {
  it("blocks an IP after repeated failures", async () => {
    const h = openTestDb();
    const ctx = await buildTestApp(h, { inviteLimiter: new AttemptLimiter(3, 60_000) });
    try {
      for (let i = 0; i < 3; i++) {
        const res = await ctx.app.inject({ method: "POST", url: "/invites/000000/accept", payload: { as: "camera", deviceName: "x" } });
        expect(res.statusCode).toBe(404);
      }
      const blocked = await ctx.app.inject({ method: "POST", url: "/invites/000000/accept", payload: { as: "camera", deviceName: "x" } });
      expect(blocked.statusCode).toBe(429);
    } finally {
      await ctx.app.close();
      await h.close();
    }
  });
});
