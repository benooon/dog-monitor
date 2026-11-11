import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import type { DbHandle } from "../src/db/client.js";
import { devices, events, notificationPrefs } from "../src/db/schema.js";
import type { ApnsNotification, ApnsResult, ApnsSender } from "../src/notifications/apns.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";
import { FakeStorage } from "./helpers/storage.js";
import { eventMediaKey } from "../src/storage/storage.js";
import { EVENT_CREATES_PER_MINUTE } from "../src/routes/events.js";

class FakeApns implements ApnsSender {
  sent: ApnsNotification[] = [];
  respond: (n: ApnsNotification) => ApnsResult = () => ({ status: 200 });
  async send(n: ApnsNotification) {
    this.sent.push(n);
    return this.respond(n);
  }
}

const tokenA = "a".repeat(64);
const tokenB = "b".repeat(64);

describe.skipIf(!hasDatabase)("camera events and push fan-out", () => {
  let h: DbHandle;
  let ctx: Awaited<ReturnType<typeof buildTestApp>>;
  let app: FastifyInstance;
  const apns = new FakeApns();

  beforeAll(async () => {
    h = openTestDb();
    ctx = await buildTestApp(h, { apns, storage: new FakeStorage() });
    app = ctx.app;
  });
  afterAll(async () => {
    await app.close();
    await h.close();
  });
  beforeEach(async () => {
    await truncateAll(h);
    apns.sent = [];
    apns.respond = () => ({ status: 200 });
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

  /** Owner + member with phones registered for push, a dog, and a paired camera. */
  async function setup() {
    const owner = await signIn("owner");
    const household = (await app.inject({ method: "POST", url: "/households", headers: owner.auth, payload: { name: "Home" } })).json();
    await app.inject({ method: "POST", url: "/dogs", headers: owner.auth, payload: { name: "Rex" } });
    const ownerPhone = (
      await app.inject({ method: "POST", url: "/devices", headers: owner.auth, payload: { name: "Owner phone", role: "viewer", apnsToken: tokenA } })
    ).json();

    const invite = (await app.inject({ method: "POST", url: "/invites", headers: owner.auth })).json();
    const member = await signIn("member");
    await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, headers: member.auth, payload: { as: "member" } });
    const memberPhone = (
      await app.inject({ method: "POST", url: "/devices", headers: member.auth, payload: { name: "Member phone", role: "viewer", apnsToken: tokenB } })
    ).json();

    const camInvite = (await app.inject({ method: "POST", url: "/invites", headers: owner.auth })).json();
    const accepted = (
      await app.inject({ method: "POST", url: `/invites/${camInvite.token}/accept`, payload: { as: "camera", deviceName: "Living room" } })
    ).json();
    return {
      householdId: household.id as string,
      owner,
      member,
      ownerPhone: ownerPhone.id as string,
      memberPhone: memberPhone.id as string,
      camera: { id: accepted.device.id as string, auth: { authorization: `Device ${accepted.device.id}:${accepted.deviceSecret}` } },
    };
  }

  const eventId = "22222222-2222-4222-8222-222222222222";
  const postEvent = (auth: Record<string, string>, extra: Record<string, unknown> = {}) =>
    app.inject({
      method: "POST",
      url: "/events",
      headers: auth,
      payload: { id: eventId, type: "prolongedBarking", startedAt: "2026-11-10T08:00:00.000Z", confidence: 0.9, ...extra },
    });

  it("stores the event and pushes to every viewer phone", async () => {
    const { camera, householdId } = await setup();
    const snapshotKey = eventMediaKey(householdId, camera.id, eventId, "snapshot");
    const res = await postEvent(camera.auth, { snapshotKey });
    expect(res.statusCode).toBe(201);
    expect(res.json()).toMatchObject({ id: eventId, householdId, cameraId: camera.id, type: "prolongedBarking", confidence: 0.9 });

    expect(apns.sent.map((n) => n.deviceToken).sort()).toEqual([tokenA, tokenB]);
    const push = apns.sent[0]!;
    expect(push.collapseId).toBe(eventId);
    expect(push.priority).toBe(10);
    expect(push.payload).toMatchObject({
      aps: { alert: { title: "Living room", "loc-key": "%@ has been barking", "loc-args": ["Rex"] }, "mutable-content": 1 },
      cameraId: camera.id,
      snapshotKey,
      snapshotUrl: `https://bucket.test/${snapshotKey}?get&ttl=21600`,
    });
  });

  // Security audit 2026-11, run 2: a camera cannot flood events (DB rows + a push per member each).
  it("rate-limits a camera's new events with 429 and Retry-After", async () => {
    const { camera } = await setup();
    const codes: number[] = [];
    for (let i = 0; i < EVENT_CREATES_PER_MINUTE + 1; i++) {
      const id = `33333333-3333-4333-8333-${String(i).padStart(12, "0")}`;
      codes.push((await postEvent(camera.auth, { id })).statusCode);
    }
    expect(codes.slice(0, EVENT_CREATES_PER_MINUTE).every((c) => c === 201)).toBe(true);
    const last = await postEvent(camera.auth, { id: "44444444-4444-4444-8444-444444444444" });
    expect(last.statusCode).toBe(429);
    expect(last.json()).toEqual({ error: "rate_limited" });
    expect(Number(last.headers["retry-after"])).toBeGreaterThanOrEqual(1);
  });

  it("is idempotent on the event id (offline queue retries)", async () => {
    const { camera } = await setup();
    expect((await postEvent(camera.auth)).statusCode).toBe(201);
    const again = await postEvent(camera.auth);
    expect(again.statusCode).toBe(200);
    expect(apns.sent).toHaveLength(2); // only the first post pushed
    expect(await h.db.select().from(events)).toHaveLength(1);
  });

  it("honors notification prefs: per-camera beats all-cameras beats the default", async () => {
    const { camera, owner, member } = await setup();
    await h.db.insert(notificationPrefs).values([
      { userId: owner.userId, deviceId: null, eventType: "prolongedBarking", enabled: false },
      { userId: member.userId, deviceId: null, eventType: "prolongedBarking", enabled: false },
      { userId: member.userId, deviceId: camera.id, eventType: "prolongedBarking", enabled: true },
    ]);
    await postEvent(camera.auth);
    expect(apns.sent.map((n) => n.deviceToken)).toEqual([tokenB]);

    // atDoor is off by default (SPEC §5).
    apns.sent = [];
    await postEvent(camera.auth, { id: "33333333-3333-4333-8333-333333333333", type: "atDoor" });
    expect(apns.sent).toHaveLength(0);
  });

  it("skips phones muted with the Mute 1h action", async () => {
    const { camera, owner, ownerPhone } = await setup();
    const until = new Date(Date.now() + 60 * 60 * 1000).toISOString();
    const mute = await app.inject({ method: "PATCH", url: `/devices/${ownerPhone}`, headers: owner.auth, payload: { mutedUntil: until } });
    expect(mute.statusCode).toBe(200);
    expect(mute.json().mutedUntil).toBe(until);
    await postEvent(camera.auth);
    expect(apns.sent.map((n) => n.deviceToken)).toEqual([tokenB]);

    await app.inject({ method: "PATCH", url: `/devices/${ownerPhone}`, headers: owner.auth, payload: { mutedUntil: null } });
    apns.sent = [];
    await postEvent(camera.auth, { id: "44444444-4444-4444-8444-444444444444" });
    expect(apns.sent).toHaveLength(2);
  });

  it("holds back non-urgent pushes during quiet hours in the phone's time zone", async () => {
    const quiet = await buildTestApp(h, { apns, now: () => Date.parse("2026-11-10T21:00:00Z") }); // 23:00 in Jerusalem
    try {
      const { camera, owner, ownerPhone } = await setup();
      const tz = await quiet.app.inject({ method: "PATCH", url: `/devices/${ownerPhone}`, headers: owner.auth, payload: { timeZone: "Asia/Jerusalem" } });
      expect(tz.json().timeZone).toBe("Asia/Jerusalem");
      expect(
        (await quiet.app.inject({ method: "PATCH", url: `/devices/${ownerPhone}`, headers: owner.auth, payload: { timeZone: "Mars/Base" } })).statusCode,
      ).toBe(400);
      for (const eventType of ["atDoor", "prolongedBarking"] as const) {
        await h.db.insert(notificationPrefs).values({ userId: owner.userId, deviceId: null, eventType, enabled: true, quietStart: "22:00", quietEnd: "07:00" });
      }

      await quiet.app.inject({
        method: "POST",
        url: "/events",
        headers: camera.auth,
        payload: { id: "66666666-6666-4666-8666-666666666666", type: "atDoor", startedAt: "2026-11-10T21:00:00.000Z" },
      });
      expect(apns.sent).toHaveLength(0); // owner is in quiet hours; member has atDoor off by default

      await quiet.app.inject({
        method: "POST",
        url: "/events",
        headers: camera.auth,
        payload: { id: "77777777-7777-4777-8777-777777777777", type: "prolongedBarking", startedAt: "2026-11-10T21:00:00.000Z" },
      });
      expect(apns.sent.map((n) => n.deviceToken).sort()).toEqual([tokenA, tokenB]); // time-sensitive gets through
    } finally {
      await quiet.app.close();
    }
  });

  it("clears tokens APNs reports as dead", async () => {
    const { camera, memberPhone } = await setup();
    apns.respond = (n) => (n.deviceToken === tokenB ? { status: 410, reason: "Unregistered" } : { status: 200 });
    await postEvent(camera.auth);
    const [phone] = await h.db.select().from(devices).where(eq(devices.id, memberPhone));
    expect(phone!.apnsToken).toBeNull();
  });

  it("ends events and pushes escalations that replace the alert", async () => {
    const { camera, householdId } = await setup();
    const clipKey = eventMediaKey(householdId, camera.id, eventId, "clip");
    await postEvent(camera.auth);
    apns.sent = [];

    const esc = await app.inject({ method: "PATCH", url: `/events/${eventId}`, headers: camera.auth, payload: { escalationSeconds: 300 } });
    expect(esc.statusCode).toBe(200);
    expect(apns.sent).toHaveLength(2);
    expect(apns.sent[0]!.collapseId).toBe(eventId);
    expect(apns.sent[0]!.payload).toMatchObject({ aps: { alert: { "loc-args": ["Rex", "5"] } } });

    apns.sent = [];
    const end = await app.inject({
      method: "PATCH",
      url: `/events/${eventId}`,
      headers: camera.auth,
      payload: { endedAt: "2026-11-10T08:07:00.000Z", clipKey },
    });
    expect(end.json()).toMatchObject({ endedAt: "2026-11-10T08:07:00.000Z", clipKey });
    expect(apns.sent).toHaveLength(0);
  });

  it("validates input and scopes events to the reporting camera", async () => {
    const { camera, owner } = await setup();
    expect((await postEvent(camera.auth, { type: "cameraOffline" })).statusCode).toBe(400);
    expect((await postEvent(camera.auth, { confidence: 2 })).statusCode).toBe(400);
    expect((await postEvent(camera.auth, { snapshotKey: "households/other/x.jpg" })).statusCode).toBe(400);
    expect((await postEvent(owner.auth)).statusCode).toBe(401);
    expect((await app.inject({ method: "PATCH", url: `/events/${eventId}`, headers: camera.auth, payload: { endedAt: null } })).statusCode).toBe(404);
  });
});

describe.skipIf(!hasDatabase)("camera offline push", () => {
  it("stores a cameraOffline event and pushes when presence goes offline", async () => {
    const { RealtimeHub } = await import("../src/realtime/hub.js");
    const h = openTestDb();
    await truncateAll(h);
    const apns = new FakeApns();
    const hub = new RealtimeHub();
    const ctx = await buildTestApp(h, { apns, hub });
    const app = ctx.app;
    try {
      const signIn = await app.inject({
        method: "POST",
        url: "/auth/apple",
        payload: { identityToken: await ctx.apple.sign({ sub: "owner" }), nonce: TEST_NONCE, name: "owner" },
      });
      const auth = { authorization: `Bearer ${signIn.json().token}` };
      await app.inject({ method: "POST", url: "/households", headers: auth, payload: { name: "Home" } });
      await app.inject({ method: "POST", url: "/devices", headers: auth, payload: { name: "Phone", role: "viewer", apnsToken: tokenA } });
      const invite = (await app.inject({ method: "POST", url: "/invites", headers: auth })).json();
      const cam = (
        await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, payload: { as: "camera", deviceName: "Hall" } })
      ).json();

      hub.cameraConnected(cam.device.id, cam.householdId, { send() {} }, null, 0);
      hub.heartbeat(cam.device.id, 0);
      hub.sweep(3 * 60 * 1000);

      for (let i = 0; i < 100 && apns.sent.length === 0; i++) await new Promise((r) => setTimeout(r, 20));
      expect(apns.sent).toHaveLength(1);
      expect(apns.sent[0]!.payload).toMatchObject({ type: "cameraOffline", aps: { alert: { title: "Hall", "loc-key": "The camera is offline" } } });
      const stored = await h.db.select().from(events);
      expect(stored).toMatchObject([{ type: "cameraOffline", deviceId: cam.device.id }]);
    } finally {
      await app.close();
      await h.close();
    }
  });
});
