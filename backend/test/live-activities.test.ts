import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { eq, sql } from "drizzle-orm";
import type { DbHandle } from "../src/db/client.js";
import { householdMembers, liveActivities } from "../src/db/schema.js";
import type { ApnsNotification, ApnsResult, ApnsSender } from "../src/notifications/apns.js";
import {
  LiveActivityNotifier,
  liveActivityPayload,
  liveActivityPriority,
} from "../src/notifications/live-activity.js";
import { RealtimeHub, type Peer } from "../src/realtime/hub.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

class FakeApns implements ApnsSender {
  sent: ApnsNotification[] = [];
  respond: (n: ApnsNotification) => ApnsResult = () => ({ status: 200 });
  async send(n: ApnsNotification) {
    this.sent.push(n);
    return this.respond(n);
  }
}

const silentPeer: Peer = { send: () => {} };
const tokenA = "a1".repeat(32);
const tokenB = "b2".repeat(32);

describe("live activity payload", () => {
  it("carries the content state the iOS widget decodes", () => {
    const payload = liveActivityPayload({ state: "barking", online: true }, new Date("2026-11-10T12:00:00.900Z"));
    expect(payload).toEqual({
      aps: { timestamp: 1_794_312_000, event: "update", "content-state": { state: "barking", online: true } },
    });
  });

  it("is urgent for alerts and going offline only", () => {
    expect(liveActivityPriority({ state: "barking", online: true })).toBe(10);
    expect(liveActivityPriority({ state: "atDoor", online: true })).toBe(10);
    expect(liveActivityPriority({ state: "resting", online: true })).toBe(5);
    expect(liveActivityPriority({ state: null, online: true })).toBe(5);
    expect(liveActivityPriority({ state: "resting", online: false })).toBe(10);
  });
});

describe.skipIf(!hasDatabase)("live activities", () => {
  let h: DbHandle;
  let ctx: Awaited<ReturnType<typeof buildTestApp>>;
  let app: FastifyInstance;
  let hub: RealtimeHub;
  const apns = new FakeApns();
  let clock = 1_800_000_000_000;

  beforeAll(async () => {
    h = openTestDb();
  });
  beforeEach(async () => {
    await truncateAll(h);
    apns.sent = [];
    apns.respond = () => ({ status: 200 });
    hub = new RealtimeHub();
    ctx = await buildTestApp(h, { apns, hub, now: () => clock, liveActivityIntervalMs: 0 });
    app = ctx.app;
  });
  afterEach(async () => {
    await app.close();
  });
  afterAll(async () => {
    await h.close();
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

  async function setup() {
    const owner = await signIn("owner");
    const household = (await app.inject({ method: "POST", url: "/households", headers: owner.auth, payload: { name: "Home" } })).json();
    const invite = (await app.inject({ method: "POST", url: "/invites", headers: owner.auth })).json();
    const member = await signIn("member");
    await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, headers: member.auth, payload: { as: "member" } });
    const camInvite = (await app.inject({ method: "POST", url: "/invites", headers: owner.auth })).json();
    const cam = (
      await app.inject({ method: "POST", url: `/invites/${camInvite.token}/accept`, payload: { as: "camera", deviceName: "Hall" } })
    ).json();
    return { householdId: household.id as string, owner, member, cameraId: cam.device.id as string };
  }

  function register(auth: Record<string, string>, cameraId: string, pushToken: string) {
    return app.inject({ method: "PUT", url: "/live-activities", headers: auth, payload: { cameraId, pushToken } });
  }

  /** The camera reports a new dog state over the realtime channel. */
  function heartbeat(cameraId: string, householdId: string, state: "barking" | "resting") {
    hub.cameraConnected(cameraId, householdId, silentPeer, null, clock);
    hub.heartbeat(cameraId, clock, state);
  }

  it("registers a push token for a camera in the household", async () => {
    const { owner, cameraId } = await setup();
    const res = await register(owner.auth, cameraId, tokenA.toUpperCase());
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ cameraId });

    const rows = await h.db.select().from(liveActivities);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.pushToken).toBe(tokenA);
    expect(rows[0]!.userId).toBe(owner.userId);

    // The same token again moves, it doesn't duplicate.
    const again = await register(owner.auth, cameraId, tokenA);
    expect(again.json().id).toBe(res.json().id);
    expect(await h.db.select().from(liveActivities)).toHaveLength(1);
  });

  it("rejects unknown cameras and malformed tokens", async () => {
    const { owner, cameraId } = await setup();
    const other = await signIn("stranger");
    await app.inject({ method: "POST", url: "/households", headers: other.auth, payload: { name: "Elsewhere" } });

    expect((await register(other.auth, cameraId, tokenA)).statusCode).toBe(404);
    expect((await register(owner.auth, "00000000-0000-4000-8000-000000000000", tokenA)).statusCode).toBe(404);
    expect((await register(owner.auth, cameraId, "not-hex")).statusCode).toBe(400);
    const noHousehold = await signIn("loner");
    expect((await register(noHousehold.auth, cameraId, tokenA)).statusCode).toBe(403);
  });

  it("deletes only the caller's own activity", async () => {
    const { owner, member, cameraId } = await setup();
    const id = (await register(owner.auth, cameraId, tokenA)).json().id as string;

    const notMine = await app.inject({ method: "DELETE", url: `/live-activities/${id}`, headers: member.auth });
    expect(notMine.statusCode).toBe(404);
    const mine = await app.inject({ method: "DELETE", url: `/live-activities/${id}`, headers: owner.auth });
    expect(mine.statusCode).toBe(204);
    expect(await h.db.select().from(liveActivities)).toHaveLength(0);
  });

  it("pushes dog-state changes to every activity showing the camera", async () => {
    const { householdId, owner, member, cameraId } = await setup();
    await register(owner.auth, cameraId, tokenA);
    await register(member.auth, cameraId, tokenB);

    heartbeat(cameraId, householdId, "barking");
    await vi.waitFor(() => expect(apns.sent).toHaveLength(2));

    expect(apns.sent.map((n) => n.deviceToken).sort()).toEqual([tokenA, tokenB]);
    const push = apns.sent[0]!;
    expect(push.pushType).toBe("liveactivity");
    expect(push.priority).toBe(10);
    expect(push.payload).toMatchObject({ aps: { event: "update", "content-state": { state: "barking", online: true } } });
  });

  it("skips members who left, drops dead tokens and forgets ended activities", async () => {
    const { householdId, owner, member, cameraId } = await setup();
    await register(owner.auth, cameraId, tokenA);
    await register(member.auth, cameraId, tokenB);
    await h.db.delete(householdMembers).where(eq(householdMembers.userId, member.userId));
    apns.respond = () => ({ status: 410, reason: "Unregistered" });

    heartbeat(cameraId, householdId, "barking");
    await vi.waitFor(async () => expect(await h.db.select().from(liveActivities)).toHaveLength(1));
    expect(apns.sent.map((n) => n.deviceToken)).toEqual([tokenA]);
    const [left] = await h.db.select().from(liveActivities);
    expect(left!.pushToken).toBe(tokenB); // the member's row stays until it expires

    // iOS ends activities after 12 hours; older rows are removed, not pushed.
    await h.db.execute(sql`UPDATE live_activities SET created_at = now() - interval '13 hours'`);
    apns.sent = [];
    clock += 60_000;
    hub.heartbeat(cameraId, clock, "resting");
    await vi.waitFor(async () => expect(await h.db.select().from(liveActivities)).toHaveLength(0));
    expect(apns.sent).toHaveLength(0);
  });

  it("throttles updates per camera and sends the latest state", async () => {
    const { householdId, owner, cameraId } = await setup();
    await register(owner.auth, cameraId, tokenA);
    // A hub of its own, so the app's notifier doesn't push too.
    const hub = new RealtimeHub();
    hub.cameraConnected(cameraId, householdId, silentPeer, null, clock);

    let now = clock;
    const notifier = new LiveActivityNotifier(h.db, apns, app.log, {
      status: (id) => hub.cameraStatus(id),
      now: () => now,
      minIntervalMs: 15_000,
    });
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    try {
      hub.heartbeat(cameraId, now, "barking");
      notifier.cameraChanged(cameraId);
      vi.advanceTimersByTime(0);
      await vi.waitFor(() => expect(apns.sent.filter((n) => n.pushType === "liveactivity").length).toBeGreaterThan(0));
      apns.sent = [];

      now += 5_000;
      hub.heartbeat(cameraId, now, "resting");
      notifier.cameraChanged(cameraId);
      notifier.cameraChanged(cameraId);
      expect(apns.sent).toHaveLength(0);

      now += 10_000;
      vi.advanceTimersByTime(10_000);
      await vi.waitFor(() => expect(apns.sent).toHaveLength(1));
      expect(apns.sent[0]!.payload).toMatchObject({ aps: { "content-state": { state: "resting" } } });
      expect(apns.sent[0]!.priority).toBe(5);
    } finally {
      notifier.close();
      vi.useRealTimers();
    }
  });
});
