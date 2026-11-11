import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import type { DbHandle } from "../src/db/client.js";
import { events, households } from "../src/db/schema.js";
import { purgeExpiredMedia } from "../src/storage/retention.js";
import { S3MediaStorage, eventMediaKey } from "../src/storage/storage.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";
import { FakeStorage } from "./helpers/storage.js";

describe("S3MediaStorage", () => {
  const storage = new S3MediaStorage(
    {
      endpoint: "https://acct.r2.cloudflarestorage.com",
      region: "auto",
      bucket: "clips",
      accessKeyId: "AKIDEXAMPLE",
      secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    },
    () => Date.parse("2026-11-10T08:00:00Z"),
  );

  it("presigns uploads (path-style for custom endpoints)", async () => {
    const upload = await storage.presignUpload("households/h/cameras/c/events/e/snapshot.jpg", "image/jpeg", 900);
    const url = new URL(upload.url);
    expect(url.host).toBe("acct.r2.cloudflarestorage.com");
    expect(url.pathname).toBe("/clips/households/h/cameras/c/events/e/snapshot.jpg");
    expect(url.searchParams.get("X-Amz-Expires")).toBe("900");
    expect(url.searchParams.get("X-Amz-Signature")).toMatch(/^[0-9a-f]{64}$/);
    expect(url.searchParams.get("X-Amz-SignedHeaders")).toContain("host");
    expect(upload.headers).toEqual({ "Content-Type": "image/jpeg" });
    expect(upload.expiresAt).toBe("2026-11-10T08:15:00.000Z");
  });

  it("presigns downloads", async () => {
    const url = new URL(await storage.presignDownload("a/b.mp4", 600));
    expect(url.pathname).toBe("/clips/a/b.mp4");
    expect(url.searchParams.get("X-Amz-Expires")).toBe("600");
  });
});

describe.skipIf(!hasDatabase)("media routes and retention", () => {
  let h: DbHandle;
  let ctx: Awaited<ReturnType<typeof buildTestApp>>;
  let app: FastifyInstance;
  let unconfigured: FastifyInstance;
  const storage = new FakeStorage();

  beforeAll(async () => {
    h = openTestDb();
    ctx = await buildTestApp(h, { storage });
    app = ctx.app;
    unconfigured = (await buildTestApp(h)).app;
  });
  afterAll(async () => {
    await app.close();
    await unconfigured.close();
    await h.close();
  });
  beforeEach(async () => {
    await truncateAll(h);
    storage.deleted = [];
  });

  async function setup() {
    const res = await app.inject({
      method: "POST",
      url: "/auth/apple",
      payload: { identityToken: await ctx.apple.sign({ sub: "owner" }), nonce: TEST_NONCE, name: "owner" },
    });
    const owner = { authorization: `Bearer ${res.json().token}` };
    const household = (await app.inject({ method: "POST", url: "/households", headers: owner, payload: { name: "Home" } })).json();
    const invite = (await app.inject({ method: "POST", url: "/invites", headers: owner })).json();
    const cam = (
      await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, payload: { as: "camera", deviceName: "Hall" } })
    ).json();
    return {
      owner,
      householdId: household.id as string,
      cameraId: cam.device.id as string,
      camera: { authorization: `Device ${cam.device.id}:${cam.deviceSecret}` },
    };
  }

  const eventId = "22222222-2222-4222-8222-222222222222";

  it("hands cameras upload URLs under the event's own prefix", async () => {
    const { camera, householdId, cameraId } = await setup();
    const res = await app.inject({ method: "POST", url: "/device/uploads", headers: camera, payload: { eventId, kinds: ["snapshot", "clip"] } });
    expect(res.statusCode).toBe(200);
    const { uploads } = res.json();
    expect(uploads.snapshot.key).toBe(eventMediaKey(householdId, cameraId, eventId, "snapshot"));
    expect(uploads.clip.key).toBe(`households/${householdId}/cameras/${cameraId}/events/${eventId}/clip.mp4`);
    expect(uploads.clip.headers).toEqual({ "Content-Type": "video/mp4" });
    expect(uploads.clip.url).toContain("ttl=900");

    const bad = await app.inject({ method: "POST", url: "/device/uploads", headers: camera, payload: { eventId, kinds: ["video"] } });
    expect(bad.statusCode).toBe(400);
    const off = await unconfigured.inject({ method: "POST", url: "/device/uploads", headers: camera, payload: { eventId, kinds: ["clip"] } });
    expect(off.statusCode).toBe(503);
  });

  it("gives household members short-lived download URLs", async () => {
    const { camera, owner, householdId, cameraId } = await setup();
    const snapshotKey = eventMediaKey(householdId, cameraId, eventId, "snapshot");
    await app.inject({
      method: "POST",
      url: "/events",
      headers: camera,
      payload: { id: eventId, type: "prolongedBarking", startedAt: new Date().toISOString(), snapshotKey },
    });
    const res = await app.inject({ method: "GET", url: `/events/${eventId}/media`, headers: owner });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ clipUrl: null, snapshotUrl: `https://bucket.test/${snapshotKey}?get&ttl=600` });

    const missing = await app.inject({ method: "GET", url: "/events/33333333-3333-4333-8333-333333333333/media", headers: owner });
    expect(missing.statusCode).toBe(404);
    expect((await app.inject({ method: "GET", url: `/events/${eventId}/media`, headers: camera })).statusCode).toBe(401);
  });

  it("lists the latest snapshot per camera", async () => {
    const { owner, householdId, cameraId } = await setup();
    const older = "55555555-5555-4555-8555-555555555555";
    await h.db.insert(events).values([
      {
        id: older,
        householdId,
        deviceId: cameraId,
        type: "prolongedBarking",
        startedAt: new Date("2026-11-10T07:00:00Z"),
        snapshotKey: eventMediaKey(householdId, cameraId, older, "snapshot"),
      },
      {
        id: eventId,
        householdId,
        deviceId: cameraId,
        type: "whining",
        startedAt: new Date("2026-11-10T08:00:00Z"),
        snapshotKey: eventMediaKey(householdId, cameraId, eventId, "snapshot"),
      },
      { householdId, deviceId: cameraId, type: "calmedDown", startedAt: new Date("2026-11-10T09:00:00Z") },
    ]);
    const res = await app.inject({ method: "GET", url: "/cameras/snapshots", headers: owner });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual([
      {
        cameraId,
        eventId,
        takenAt: "2026-11-10T08:00:00.000Z",
        url: `https://bucket.test/${eventMediaKey(householdId, cameraId, eventId, "snapshot")}?get&ttl=600`,
      },
    ]);
  });

  it("deletes media older than the retention period and clears the keys", async () => {
    const { householdId, cameraId } = await setup();
    const now = new Date("2026-11-10T08:00:00Z");
    const old = eventMediaKey(householdId, cameraId, eventId, "clip");
    const recentId = "44444444-4444-4444-8444-444444444444";
    await h.db.insert(events).values([
      { id: eventId, householdId, deviceId: cameraId, type: "prolongedBarking", startedAt: new Date("2026-11-01T08:00:00Z"), clipKey: old },
      {
        id: recentId,
        householdId,
        deviceId: cameraId,
        type: "prolongedBarking",
        startedAt: new Date("2026-11-09T08:00:00Z"),
        clipKey: eventMediaKey(householdId, cameraId, recentId, "clip"),
      },
    ]);

    expect(await purgeExpiredMedia(h.db, storage, 7, now)).toBe(1);
    expect(storage.deleted).toEqual([old]);
    const [expired] = await h.db.select().from(events).where(eq(events.id, eventId));
    expect(expired!.clipKey).toBeNull();
    const [recent] = await h.db.select().from(events).where(eq(events.id, recentId));
    expect(recent!.clipKey).not.toBeNull();

    expect(await purgeExpiredMedia(h.db, storage, 7, now)).toBe(0);
  });

  it("keeps clips as long as the household's plan allows when plan limits are enforced", async () => {
    const { householdId, cameraId } = await setup();
    const now = new Date("2026-11-10T08:00:00Z");
    const ids = {
      hoursOld: "77777777-7777-4777-8777-777777777771",
      twoDays: "77777777-7777-4777-8777-777777777772",
      monthOld: "77777777-7777-4777-8777-777777777773",
    };
    const key = (id: string) => eventMediaKey(householdId, cameraId, id, "clip");
    await h.db.insert(events).values([
      { id: ids.hoursOld, householdId, deviceId: cameraId, type: "whining", startedAt: new Date("2026-11-10T02:00:00Z"), clipKey: key(ids.hoursOld) },
      { id: ids.twoDays, householdId, deviceId: cameraId, type: "whining", startedAt: new Date("2026-11-08T08:00:00Z"), clipKey: key(ids.twoDays) },
      { id: ids.monthOld, householdId, deviceId: cameraId, type: "whining", startedAt: new Date("2026-10-05T08:00:00Z"), clipKey: key(ids.monthOld) },
    ]);

    // Premium keeps 30 days: only the clip from October goes.
    await h.db.update(households).set({ planExpiresAt: new Date("2026-12-01T00:00:00Z") }).where(eq(households.id, householdId));
    expect(await purgeExpiredMedia(h.db, storage, 7, now, { byPlan: true })).toBe(1);
    expect(storage.deleted).toEqual([key(ids.monthOld)]);

    // Free keeps one day.
    await h.db.update(households).set({ planExpiresAt: null }).where(eq(households.id, householdId));
    expect(await purgeExpiredMedia(h.db, storage, 7, now, { byPlan: true })).toBe(1);
    expect(storage.deleted).toEqual([key(ids.monthOld), key(ids.twoDays)]);
  });

  it("keeps labeled clips of households that share training data, up to 90 days", async () => {
    const { owner, householdId, cameraId } = await setup();
    const now = new Date("2026-11-10T08:00:00Z");
    const labeled = "55555555-5555-4555-8555-555555555555";
    const ancient = "66666666-6666-4666-8666-666666666666";
    const key = (id: string) => eventMediaKey(householdId, cameraId, id, "clip");
    await h.db.insert(events).values([
      { id: eventId, householdId, deviceId: cameraId, type: "whining", startedAt: new Date("2026-11-01T08:00:00Z"), clipKey: key(eventId) },
      { id: labeled, householdId, deviceId: cameraId, type: "prolongedBarking", startedAt: new Date("2026-10-01T08:00:00Z"), clipKey: key(labeled), feedback: "wrong" },
      { id: ancient, householdId, deviceId: cameraId, type: "prolongedBarking", startedAt: new Date("2026-07-01T08:00:00Z"), clipKey: key(ancient), feedback: "correct" },
    ]);

    // Not opted in: labels don't matter.
    expect(
      (await app.inject({ method: "GET", url: "/training/labeled", headers: owner })).json(),
    ).toEqual({ error: "training_not_enabled" });

    const patch = await app.inject({ method: "PATCH", url: "/household", headers: owner, payload: { shareTrainingData: true } });
    expect(patch.statusCode).toBe(200);
    expect(patch.json().shareTrainingData).toBe(true);
    expect((await app.inject({ method: "GET", url: "/household", headers: owner })).json().shareTrainingData).toBe(true);

    expect(await purgeExpiredMedia(h.db, storage, 7, now)).toBe(2);
    expect(storage.deleted.sort()).toEqual([key(eventId), key(ancient)].sort());

    const exported = await app.inject({ method: "GET", url: "/training/labeled", headers: owner });
    expect(exported.statusCode).toBe(200);
    expect(exported.json().items).toEqual([
      expect.objectContaining({ eventId: labeled, feedback: "wrong", clipUrl: `https://bucket.test/${key(labeled)}?get&ttl=600` }),
    ]);
    expect(exported.json().next).toBeNull();

    const exportToken = await app.inject({ method: "POST", url: "/training/export-token", headers: owner });
    expect(exportToken.statusCode).toBe(200);
    const scripted = await app.inject({
      method: "GET",
      url: "/training/labeled",
      headers: { authorization: `Bearer ${exportToken.json().token}` },
    });
    expect(scripted.json().items).toHaveLength(1);
    // The export key is not a session: no other route, and it can't mint a new key (audit 2026-11).
    const exportKey = { authorization: `Bearer ${exportToken.json().token}` };
    expect((await app.inject({ method: "GET", url: "/me", headers: exportKey })).statusCode).toBe(401);
    expect((await app.inject({ method: "POST", url: "/invites", headers: exportKey })).statusCode).toBe(401);
    expect((await app.inject({ method: "PATCH", url: "/household", headers: exportKey, payload: { name: "x" } })).statusCode).toBe(401);
    expect((await app.inject({ method: "POST", url: "/training/export-token", headers: exportKey })).statusCode).toBe(401);

    await h.db.update(households).set({ shareTrainingData: false }).where(eq(households.id, householdId));
    expect((await app.inject({ method: "POST", url: "/training/export-token", headers: owner })).statusCode).toBe(403);
    expect(await purgeExpiredMedia(h.db, storage, 7, now)).toBe(1);
  });
});
