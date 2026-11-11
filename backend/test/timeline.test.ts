import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import type { DbHandle } from "../src/db/client.js";
import { events } from "../src/db/schema.js";
import { decodeCursor, encodeCursor } from "../src/routes/timeline.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

describe("timeline cursor", () => {
  it("round-trips and rejects garbage", () => {
    const at = new Date("2026-11-10T08:00:00.123Z");
    const id = "22222222-2222-4222-8222-222222222222";
    expect(decodeCursor(encodeCursor(at, id))).toEqual({ startedAt: at, id });
    expect(decodeCursor("nope")).toBeNull();
    expect(decodeCursor("2026-11-10T08:00:00Z_not-a-uuid")).toBeNull();
    expect(decodeCursor(`yesterday_${id}`)).toBeNull();
  });
});

describe.skipIf(!hasDatabase)("timeline routes", () => {
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
    return { authorization: `Bearer ${res.json().token}` };
  }

  async function household(name: string, sub: string) {
    const owner = await signIn(sub);
    const created = (await app.inject({ method: "POST", url: "/households", headers: owner, payload: { name } })).json();
    const invite = (await app.inject({ method: "POST", url: "/invites", headers: owner })).json();
    const cam = (
      await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, payload: { as: "camera", deviceName: `${name} cam` } })
    ).json();
    return {
      owner,
      householdId: created.id as string,
      cameraId: cam.device.id as string,
      camera: { authorization: `Device ${cam.device.id}:${cam.deviceSecret}` },
    };
  }

  const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

  async function seed(householdId: string, deviceId: string, count: number, startAt = 1) {
    const base = Date.parse("2026-11-10T00:00:00Z");
    await h.db.insert(events).values(
      Array.from({ length: count }, (_, i) => ({
        id: id(startAt + i),
        householdId,
        deviceId,
        type: i % 2 === 0 ? ("prolongedBarking" as const) : ("whining" as const),
        startedAt: new Date(base + (startAt + i) * 60_000),
      })),
    );
  }

  it("lists the household's events newest first, page by page", async () => {
    const home = await household("Home", "owner");
    await seed(home.householdId, home.cameraId, 5);

    const first = await app.inject({ method: "GET", url: "/events?limit=2", headers: home.owner });
    expect(first.statusCode).toBe(200);
    const page1 = first.json();
    expect(page1.events.map((e: { id: string }) => e.id)).toEqual([id(5), id(4)]);
    expect(page1.events[0]).toMatchObject({ cameraId: home.cameraId, type: "prolongedBarking", feedback: null, mediaExpired: false });
    expect(page1.nextCursor).toBeTypeOf("string");

    const page2 = (
      await app.inject({ method: "GET", url: `/events?limit=2&cursor=${encodeURIComponent(page1.nextCursor)}`, headers: home.owner })
    ).json();
    expect(page2.events.map((e: { id: string }) => e.id)).toEqual([id(3), id(2)]);

    const page3 = (
      await app.inject({ method: "GET", url: `/events?limit=2&cursor=${encodeURIComponent(page2.nextCursor)}`, headers: home.owner })
    ).json();
    expect(page3.events.map((e: { id: string }) => e.id)).toEqual([id(1)]);
    expect(page3.nextCursor).toBeNull();
  });

  it("pages through events that share a start time", async () => {
    const home = await household("Home", "owner");
    const at = new Date("2026-11-10T08:00:00Z");
    await h.db.insert(events).values(
      [1, 2, 3].map((n) => ({ id: id(n), householdId: home.householdId, deviceId: home.cameraId, type: "whining" as const, startedAt: at })),
    );
    const page1 = (await app.inject({ method: "GET", url: "/events?limit=2", headers: home.owner })).json();
    const page2 = (
      await app.inject({ method: "GET", url: `/events?limit=2&cursor=${encodeURIComponent(page1.nextCursor)}`, headers: home.owner })
    ).json();
    expect([...page1.events, ...page2.events].map((e: { id: string }) => e.id)).toEqual([id(3), id(2), id(1)]);
  });

  it("filters by type and camera, and validates the query", async () => {
    const home = await household("Home", "owner");
    await seed(home.householdId, home.cameraId, 4);

    const whining = (await app.inject({ method: "GET", url: "/events?types=whining", headers: home.owner })).json();
    expect(whining.events.map((e: { type: string }) => e.type)).toEqual(["whining", "whining"]);

    const both = (await app.inject({ method: "GET", url: "/events?types=whining,prolongedBarking", headers: home.owner })).json();
    expect(both.events).toHaveLength(4);

    const otherCamera = (
      await app.inject({ method: "GET", url: "/events?cameraId=33333333-3333-4333-8333-333333333333", headers: home.owner })
    ).json();
    expect(otherCamera.events).toEqual([]);

    const own = (await app.inject({ method: "GET", url: `/events?cameraId=${home.cameraId}`, headers: home.owner })).json();
    expect(own.events).toHaveLength(4);

    expect((await app.inject({ method: "GET", url: "/events?types=sneezing", headers: home.owner })).statusCode).toBe(400);
    expect((await app.inject({ method: "GET", url: "/events?cursor=bad", headers: home.owner })).statusCode).toBe(400);
    expect((await app.inject({ method: "GET", url: "/events?limit=500", headers: home.owner })).statusCode).toBe(400);
  });

  it("never shows another household's events and needs a user", async () => {
    const home = await household("Home", "owner");
    const other = await household("Other", "neighbor");
    await seed(other.householdId, other.cameraId, 3);

    const res = (await app.inject({ method: "GET", url: "/events", headers: home.owner })).json();
    expect(res.events).toEqual([]);
    expect((await app.inject({ method: "GET", url: "/events", headers: home.camera })).statusCode).toBe(401);
    expect((await app.inject({ method: "GET", url: "/events" })).statusCode).toBe(401);
  });

  it("records right/wrong feedback within the household", async () => {
    const home = await household("Home", "owner");
    const other = await household("Other", "neighbor");
    await seed(home.householdId, home.cameraId, 1);

    const wrong = await app.inject({ method: "PUT", url: `/events/${id(1)}/feedback`, headers: home.owner, payload: { feedback: "wrong" } });
    expect(wrong.statusCode).toBe(200);
    expect(wrong.json()).toMatchObject({ id: id(1), feedback: "wrong" });

    const cleared = await app.inject({ method: "PUT", url: `/events/${id(1)}/feedback`, headers: home.owner, payload: { feedback: null } });
    expect(cleared.json().feedback).toBeNull();

    const bad = await app.inject({ method: "PUT", url: `/events/${id(1)}/feedback`, headers: home.owner, payload: { feedback: "maybe" } });
    expect(bad.statusCode).toBe(400);

    const foreign = await app.inject({ method: "PUT", url: `/events/${id(1)}/feedback`, headers: other.owner, payload: { feedback: "correct" } });
    expect(foreign.statusCode).toBe(404);
  });
});
