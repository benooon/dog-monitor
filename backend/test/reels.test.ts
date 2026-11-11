import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import type { DbHandle } from "../src/db/client.js";
import { dailySummaries, households } from "../src/db/schema.js";
import { purgeExpiredMedia } from "../src/storage/retention.js";
import { reelMediaKey } from "../src/storage/storage.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";
import { FakeStorage } from "./helpers/storage.js";

const NOW = new Date("2026-11-11T12:00:00Z");
const DAY = 24 * 60 * 60 * 1000;

describe.skipIf(!hasDatabase)("daily highlight reels", () => {
  let h: DbHandle;
  const storage = new FakeStorage();
  let open: FastifyInstance;
  let enforced: Awaited<ReturnType<typeof buildTestApp>>;
  let openCtx: Awaited<ReturnType<typeof buildTestApp>>;

  beforeAll(async () => {
    h = openTestDb();
    openCtx = await buildTestApp(h, { storage, now: () => NOW.getTime() });
    open = openCtx.app;
    enforced = await buildTestApp(h, { storage, enforcePlanLimits: true, now: () => NOW.getTime() });
  });
  afterAll(async () => {
    await open.close();
    await enforced.app.close();
    await h.close();
  });
  beforeEach(async () => {
    await truncateAll(h);
    storage.deleted = [];
  });

  async function setup(ctx = openCtx) {
    const app = ctx.app;
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
    const camera = { authorization: `Device ${cam.device.id}:${cam.deviceSecret}` };
    const summary = {
      restMinutes: 300,
      barkCount: 6,
      activityByHour: Array.from({ length: 24 }, () => 0),
      stateMinutes: { resting: 300 },
    };
    await app.inject({ method: "PUT", url: "/device/summaries/2026-11-10", headers: camera, payload: summary });
    return { app, owner, camera, householdId: household.id as string, cameraId: cam.device.id as string };
  }

  it("uploads under the camera's reel key, attaches it, and lets viewers download it", async () => {
    const { app, owner, camera, householdId, cameraId } = await setup();
    const key = reelMediaKey(householdId, cameraId, "2026-11-10");
    expect(key).toBe(`households/${householdId}/cameras/${cameraId}/reels/2026-11-10.mp4`);

    const upload = await app.inject({ method: "POST", url: "/device/reels/2026-11-10/upload", headers: camera });
    expect(upload.statusCode).toBe(200);
    expect(upload.json().upload).toMatchObject({ key, headers: { "Content-Type": "video/mp4" } });

    const before = await app.inject({ method: "GET", url: `/summaries/${cameraId}/2026-11-10/reel`, headers: owner });
    expect(before.statusCode).toBe(404);
    expect((await app.inject({ method: "GET", url: "/summaries", headers: owner })).json().summaries[0].hasReel).toBe(false);

    const attach = await app.inject({ method: "PUT", url: "/device/reels/2026-11-10", headers: camera });
    expect(attach.statusCode).toBe(200);
    expect((await app.inject({ method: "GET", url: "/summaries", headers: owner })).json().summaries[0].hasReel).toBe(true);

    const reel = await app.inject({ method: "GET", url: `/summaries/${cameraId}/2026-11-10/reel`, headers: owner });
    expect(reel.statusCode).toBe(200);
    expect(reel.json().url).toBe(`https://bucket.test/${key}?get&ttl=600`);
  });

  it("needs that day's summary, a camera, and the viewer's own household", async () => {
    const { app, owner, camera, cameraId } = await setup();
    expect((await app.inject({ method: "POST", url: "/device/reels/2026-11-09/upload", headers: camera })).statusCode).toBe(404);
    expect((await app.inject({ method: "PUT", url: "/device/reels/2026-11-09", headers: camera })).statusCode).toBe(404);
    expect((await app.inject({ method: "POST", url: "/device/reels/2026-11-10/upload", headers: owner })).statusCode).toBe(401);
    expect((await app.inject({ method: "POST", url: "/device/reels/not-a-date/upload", headers: camera })).statusCode).toBe(400);

    await app.inject({ method: "PUT", url: "/device/reels/2026-11-10", headers: camera });
    const strangerToken = (
      await app.inject({
        method: "POST",
        url: "/auth/apple",
        payload: { identityToken: await openCtx.apple.sign({ sub: "stranger" }), nonce: TEST_NONCE, name: "stranger" },
      })
    ).json().token;
    const stranger = { authorization: `Bearer ${strangerToken}` };
    await app.inject({ method: "POST", url: "/households", headers: stranger, payload: { name: "Elsewhere" } });
    const peek = await app.inject({ method: "GET", url: `/summaries/${cameraId}/2026-11-10/reel`, headers: stranger });
    expect(peek.statusCode).toBe(404);
  });

  it("is Premium when plan limits are enforced", async () => {
    const { app, camera, householdId } = await setup(enforced);
    const free = await app.inject({ method: "POST", url: "/device/reels/2026-11-10/upload", headers: camera });
    expect(free.statusCode).toBe(403);
    expect(free.json()).toEqual({ error: "premium_required" });
    expect((await app.inject({ method: "PUT", url: "/device/reels/2026-11-10", headers: camera })).statusCode).toBe(403);

    await h.db.update(households).set({ planExpiresAt: new Date(NOW.getTime() + 30 * DAY) }).where(eq(households.id, householdId));
    expect((await app.inject({ method: "POST", url: "/device/reels/2026-11-10/upload", headers: camera })).statusCode).toBe(200);
  });

  it("deletes reels with the household's clip retention", async () => {
    const { app, camera, householdId, cameraId } = await setup();
    await app.inject({ method: "PUT", url: "/device/reels/2026-11-10", headers: camera });
    const key = reelMediaKey(householdId, cameraId, "2026-11-10");

    // Free plan keeps a day: the reel of 10 Nov stays until the end of 11 Nov.
    await purgeExpiredMedia(h.db, storage, 7, new Date("2026-11-11T23:00:00Z"), { byPlan: true });
    expect(storage.deleted).toEqual([]);
    expect(await purgeExpiredMedia(h.db, storage, 7, new Date("2026-11-12T01:00:00Z"), { byPlan: true })).toBe(1);
    expect(storage.deleted).toEqual([key]);
    const [row] = await h.db.select().from(dailySummaries).where(eq(dailySummaries.deviceId, cameraId));
    expect(row!.reelKey).toBeNull();
  });
});
