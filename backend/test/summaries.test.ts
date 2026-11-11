import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import type { DbHandle } from "../src/db/client.js";
import type { ApnsNotification, ApnsResult, ApnsSender } from "../src/notifications/apns.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

class FakeApns implements ApnsSender {
  sent: ApnsNotification[] = [];
  async send(n: ApnsNotification): Promise<ApnsResult> {
    this.sent.push(n);
    return { status: 200 };
  }
}

const APNS = "b".repeat(64);
const day = (overrides: Record<string, unknown> = {}) => ({
  restMinutes: 300,
  barkCount: 12,
  activityByHour: Array.from({ length: 24 }, (_, hour) => (hour === 9 ? 25 : 0)),
  stateMinutes: { resting: 300, barking: 4 },
  ...overrides,
});

describe.skipIf(!hasDatabase)("daily summaries", () => {
  let h: DbHandle;
  let ctx: Awaited<ReturnType<typeof buildTestApp>>;
  let app: FastifyInstance;
  const apns = new FakeApns();

  beforeAll(async () => {
    h = openTestDb();
    ctx = await buildTestApp(h, { apns });
    app = ctx.app;
  });
  afterAll(async () => {
    await app.close();
    await h.close();
  });
  beforeEach(async () => {
    await truncateAll(h);
    apns.sent = [];
  });

  async function setup() {
    const res = await app.inject({
      method: "POST",
      url: "/auth/apple",
      payload: { identityToken: await ctx.apple.sign({ sub: "owner" }), nonce: TEST_NONCE, name: "owner" },
    });
    const owner = { authorization: `Bearer ${res.json().token}` };
    await app.inject({ method: "POST", url: "/households", headers: owner, payload: { name: "Home" } });
    await app.inject({ method: "POST", url: "/devices", headers: owner, payload: { name: "Phone", role: "viewer", apnsToken: APNS } });
    const invite = (await app.inject({ method: "POST", url: "/invites", headers: owner })).json();
    const cam = (
      await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, payload: { as: "camera", deviceName: "Hall" } })
    ).json();
    return { owner, cameraId: cam.device.id as string, camera: { authorization: `Device ${cam.device.id}:${cam.deviceSecret}` } };
  }

  it("upserts a camera's day and lists it for viewers", async () => {
    const { owner, camera, cameraId } = await setup();
    const first = await app.inject({ method: "PUT", url: "/device/summaries/2026-11-09", headers: camera, payload: day() });
    expect(first.statusCode).toBe(200);
    expect(first.json()).toMatchObject({ cameraId, date: "2026-11-09", restMinutes: 300, isFinal: false });

    await app.inject({ method: "PUT", url: "/device/summaries/2026-11-09", headers: camera, payload: day({ barkCount: 20 }) });
    await app.inject({ method: "PUT", url: "/device/summaries/2026-11-10", headers: camera, payload: day({ restMinutes: 10 }) });

    const list = await app.inject({ method: "GET", url: "/summaries", headers: owner });
    expect(list.statusCode).toBe(200);
    const { summaries } = list.json();
    expect(summaries.map((s: { date: string }) => s.date)).toEqual(["2026-11-10", "2026-11-09"]);
    expect(summaries[1]).toMatchObject({ barkCount: 20, stateMinutes: { resting: 300, barking: 4 } });
    expect(summaries[1].activityByHour[9]).toBe(25);

    const filtered = await app.inject({ method: "GET", url: `/summaries?cameraId=${cameraId}&from=2026-11-10`, headers: owner });
    expect(filtered.json().summaries).toHaveLength(1);
    expect(apns.sent).toHaveLength(0);
  });

  it("pushes once when the day is final and adds it to the timeline", async () => {
    const { owner, camera } = await setup();
    const final = await app.inject({ method: "PUT", url: "/device/summaries/2026-11-09", headers: camera, payload: day({ final: true }) });
    expect(final.json().isFinal).toBe(true);
    await app.inject({ method: "PUT", url: "/device/summaries/2026-11-09", headers: camera, payload: day({ final: true }) });

    expect(apns.sent).toHaveLength(1);
    expect(apns.sent[0]!.payload).toMatchObject({ type: "dailySummary" });
    const timeline = (await app.inject({ method: "GET", url: "/events", headers: owner })).json();
    expect(timeline.events.map((e: { type: string }) => e.type)).toEqual(["dailySummary"]);
  });

  it("says the reel is ready when the camera attached it before the day went final", async () => {
    const { camera } = await setup();
    await app.inject({ method: "PUT", url: "/device/summaries/2026-11-09", headers: camera, payload: day() });
    const attach = await app.inject({ method: "PUT", url: "/device/reels/2026-11-09", headers: camera });
    expect(attach.statusCode).toBe(200);
    const final = await app.inject({ method: "PUT", url: "/device/summaries/2026-11-09", headers: camera, payload: day({ final: true }) });
    expect(final.json()).toMatchObject({ isFinal: true, hasReel: true });

    expect(apns.sent).toHaveLength(1);
    const payload = apns.sent[0]!.payload as { aps: { alert: { "loc-key": string } }; hasReel?: boolean };
    expect(payload.aps.alert["loc-key"]).toBe("Your dog's day in 30 seconds is ready");
    expect(payload.hasReel).toBe(true);
  });

  it("validates input and auth", async () => {
    const { owner, camera } = await setup();
    const bad = [
      { url: "/device/summaries/yesterday", payload: day() },
      { url: "/device/summaries/2026-11-09", payload: day({ activityByHour: [1, 2, 3] }) },
      { url: "/device/summaries/2026-11-09", payload: day({ restMinutes: 2000 }) },
    ];
    for (const { url, payload } of bad) {
      expect((await app.inject({ method: "PUT", url, headers: camera, payload })).statusCode).toBe(400);
    }
    const unknownState = await app.inject({
      method: "PUT",
      url: "/device/summaries/2026-11-09",
      headers: camera,
      payload: day({ stateMinutes: { resting: 5, sleeping: 4 } }),
    });
    expect(unknownState.json().stateMinutes).toEqual({ resting: 5 }); // unknown states are dropped
    expect((await app.inject({ method: "PUT", url: "/device/summaries/2026-11-09", headers: owner, payload: day() })).statusCode).toBe(401);
    expect((await app.inject({ method: "GET", url: "/summaries", headers: camera })).statusCode).toBe(401);
  });
});
