import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import type { DbHandle } from "../src/db/client.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

describe.skipIf(!hasDatabase)("notification prefs API", () => {
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

  async function setup() {
    const owner = await signIn("owner");
    await app.inject({ method: "POST", url: "/households", headers: owner, payload: { name: "Home" } });
    const invite = (await app.inject({ method: "POST", url: "/invites", headers: owner })).json();
    const cam = (
      await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, payload: { as: "camera", deviceName: "Hall" } })
    ).json();
    return { owner, cameraId: cam.device.id as string };
  }

  it("returns type defaults and no prefs at first", async () => {
    const { owner } = await setup();
    const res = await app.inject({ method: "GET", url: "/notification-prefs", headers: owner });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.prefs).toEqual([]);
    expect(body.types).toContainEqual({ eventType: "atDoor", enabledByDefault: false, bypassesQuietHours: false });
    expect(body.types).toContainEqual({ eventType: "prolongedBarking", enabledByDefault: true, bypassesQuietHours: true });
  });

  it("replaces the caller's prefs", async () => {
    const { owner, cameraId } = await setup();
    const put = await app.inject({
      method: "PUT",
      url: "/notification-prefs",
      headers: owner,
      payload: {
        prefs: [
          { cameraId: null, eventType: "calmedDown", enabled: true, quietStart: "22:00", quietEnd: "07:00" },
          { cameraId, eventType: "atDoor", enabled: true },
        ],
      },
    });
    expect(put.statusCode).toBe(200);
    expect(put.json().prefs).toEqual(
      expect.arrayContaining([
        { cameraId: null, eventType: "calmedDown", enabled: true, quietStart: "22:00", quietEnd: "07:00" },
        { cameraId, eventType: "atDoor", enabled: true, quietStart: null, quietEnd: null },
      ]),
    );

    const second = await app.inject({ method: "PUT", url: "/notification-prefs", headers: owner, payload: { prefs: [] } });
    expect(second.json().prefs).toEqual([]);
  });

  it("validates cameras, duplicates and quiet hours", async () => {
    const { owner, cameraId } = await setup();
    const put = (prefs: unknown[]) => app.inject({ method: "PUT", url: "/notification-prefs", headers: owner, payload: { prefs } });
    expect((await put([{ cameraId: "33333333-3333-4333-8333-333333333333", eventType: "atDoor", enabled: true }])).statusCode).toBe(400);
    expect(
      (
        await put([
          { cameraId, eventType: "atDoor", enabled: true },
          { cameraId, eventType: "atDoor", enabled: false },
        ])
      ).json().error,
    ).toBe("duplicate_pref");
    expect((await put([{ cameraId: null, eventType: "atDoor", enabled: true, quietStart: "22:00" }])).json().error).toBe(
      "incomplete_quiet_hours",
    );
    expect((await put([{ cameraId: null, eventType: "atDoor", enabled: true, quietStart: "24:00", quietEnd: "07:00" }])).statusCode).toBe(400);
    expect((await put([{ cameraId: null, eventType: "nope", enabled: true }])).statusCode).toBe(400);
    expect((await app.inject({ method: "GET", url: "/notification-prefs" })).statusCode).toBe(401);
  });
});
