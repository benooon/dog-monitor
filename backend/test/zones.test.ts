import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { randomUUID } from "node:crypto";
import type { DbHandle } from "../src/db/client.js";
import { offLimitsPlace } from "../src/routes/events.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

describe("offLimitsPlace", () => {
  it("is the sofa only when every off-limits zone is a sofa", () => {
    expect(offLimitsPlace(["sofa"])).toBe("sofa");
    expect(offLimitsPlace(["sofa", "sofa", "door"])).toBe("sofa");
    expect(offLimitsPlace(["sofa", "forbidden"])).toBe("offLimits");
    expect(offLimitsPlace(["forbidden"])).toBe("offLimits");
    expect(offLimitsPlace([])).toBe("offLimits");
  });
});

describe.skipIf(!hasDatabase)("camera zones", () => {
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

  async function pairCamera(sub: string, name: string) {
    const res = await app.inject({
      method: "POST",
      url: "/auth/apple",
      payload: { identityToken: await ctx.apple.sign({ sub }), nonce: TEST_NONCE, name: sub },
    });
    const owner = { authorization: `Bearer ${res.json().token}` };
    await app.inject({ method: "POST", url: "/households", headers: owner, payload: { name: "Home" } });
    const invite = (await app.inject({ method: "POST", url: "/invites", headers: owner })).json();
    const cam = (
      await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, payload: { as: "camera", deviceName: name } })
    ).json();
    return { owner, camera: { authorization: `Device ${cam.device.id}:${cam.deviceSecret}` } };
  }

  const door = { kind: "door", polygon: [{ x: 0.8, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0.8, y: 1 }] };
  const sofa = { kind: "forbidden", polygon: [{ x: 0, y: 0.6 }, { x: 0.3, y: 0.6 }, { x: 0.2, y: 1 }] };

  it("replaces and returns the camera's zones", async () => {
    const { camera } = await pairCamera("owner", "Hall");
    expect((await app.inject({ method: "GET", url: "/device/zones", headers: camera })).json()).toEqual({ zones: [] });

    const put = await app.inject({ method: "PUT", url: "/device/zones", headers: camera, payload: { zones: [door, sofa] } });
    expect(put.statusCode).toBe(200);
    expect(put.json().zones).toEqual([expect.objectContaining(door), expect.objectContaining(sofa)]);

    await app.inject({ method: "PUT", url: "/device/zones", headers: camera, payload: { zones: [sofa] } });
    const get = (await app.inject({ method: "GET", url: "/device/zones", headers: camera })).json();
    expect(get.zones).toHaveLength(1);
    expect(get.zones[0]).toMatchObject(sofa);
    expect(typeof get.zones[0].id).toBe("string");
  });

  it("keeps each camera's zones separate", async () => {
    const a = await pairCamera("a", "A");
    const b = await pairCamera("b", "B");
    await app.inject({ method: "PUT", url: "/device/zones", headers: a.camera, payload: { zones: [door] } });
    expect((await app.inject({ method: "GET", url: "/device/zones", headers: b.camera })).json()).toEqual({ zones: [] });
  });

  it("tells viewers which zone kinds each camera has", async () => {
    const { owner, camera } = await pairCamera("owner", "Hall");
    const cameraOf = async () =>
      (await app.inject({ method: "GET", url: "/household", headers: owner }))
        .json()
        .devices.find((d: { role: string }) => d.role === "camera");
    expect((await cameraOf()).zoneKinds).toEqual([]);

    const sofa2 = { ...sofa, polygon: [{ x: 0.5, y: 0.5 }, { x: 0.6, y: 0.5 }, { x: 0.6, y: 0.6 }] };
    await app.inject({ method: "PUT", url: "/device/zones", headers: camera, payload: { zones: [sofa, door, sofa2] } });
    expect((await cameraOf()).zoneKinds).toEqual(["door", "forbidden"]);
  });

  it("accepts sofa zones and lists them", async () => {
    const { owner, camera } = await pairCamera("owner", "Hall");
    const realSofa = { ...sofa, kind: "sofa" };
    const put = await app.inject({ method: "PUT", url: "/device/zones", headers: camera, payload: { zones: [realSofa, door] } });
    expect(put.statusCode).toBe(200);
    const household = (await app.inject({ method: "GET", url: "/household", headers: owner })).json();
    expect(household.devices.find((d: { role: string }) => d.role === "camera").zoneKinds).toEqual(["door", "sofa"]);
  });

  it("records where a forbidden-zone event happened", async () => {
    const { camera } = await pairCamera("owner", "Hall");
    const post = async (type: string) =>
      (
        await app.inject({
          method: "POST",
          url: "/events",
          headers: camera,
          payload: { id: randomUUID(), type, startedAt: new Date().toISOString() },
        })
      ).json();

    await app.inject({ method: "PUT", url: "/device/zones", headers: camera, payload: { zones: [{ ...sofa, kind: "sofa" }, door] } });
    expect((await post("forbiddenZone")).place).toBe("sofa");
    expect((await post("atDoor")).place).toBeNull();

    await app.inject({ method: "PUT", url: "/device/zones", headers: camera, payload: { zones: [{ ...sofa, kind: "sofa" }, sofa] } });
    expect((await post("forbiddenZone")).place).toBe("offLimits");
  });

  it("validates shapes and requires device auth", async () => {
    const { owner, camera } = await pairCamera("owner", "Hall");
    const bad = [
      { zones: [{ kind: "door", polygon: [{ x: 0, y: 0 }, { x: 1, y: 1 }] }] },
      { zones: [{ kind: "door", polygon: [{ x: 0, y: 0 }, { x: 1.5, y: 1 }, { x: 0, y: 1 }] }] },
      { zones: [{ kind: "garden", polygon: door.polygon }] },
    ];
    for (const payload of bad) {
      expect((await app.inject({ method: "PUT", url: "/device/zones", headers: camera, payload })).statusCode).toBe(400);
    }
    expect((await app.inject({ method: "GET", url: "/device/zones", headers: owner })).statusCode).toBe(401);
  });
});
