import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { TokenVerifier } from "livekit-server-sdk";
import type { DbHandle } from "../src/db/client.js";
import { LIVE_TOKEN_TTL_SECONDS, createLiveKitIssuer, roomForCamera } from "../src/live/livekit.js";
import { RealtimeHub } from "../src/realtime/hub.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

const LIVEKIT = { url: "wss://test.livekit.cloud", apiKey: "APItestkey", apiSecret: "test-livekit-secret-0123456789abcdef" };
const verifier = new TokenVerifier(LIVEKIT.apiKey, LIVEKIT.apiSecret);

describe("LiveKit token issuer", () => {
  const issuer = createLiveKitIssuer(LIVEKIT, () => new Date("2026-01-01T00:00:00Z"));
  const deviceId = "11111111-1111-4111-8111-111111111111";

  it("gives viewers subscribe + microphone-only publish in the camera's room", async () => {
    const res = await issuer.viewerToken({ deviceId, userId: "u1", name: "Ben" });
    expect(res).toMatchObject({ url: LIVEKIT.url, room: roomForCamera(deviceId), expiresAt: "2026-01-01T00:10:00.000Z" });
    expect(res.identity).toMatch(/^viewer:u1:[0-9a-f]{8}$/);

    const claims = await verifier.verify(res.token);
    expect(claims.sub).toBe(res.identity);
    expect(claims.name).toBe("Ben");
    expect(claims.video).toMatchObject({
      room: `camera-${deviceId}`,
      roomJoin: true,
      canSubscribe: true,
      canPublish: true,
      canPublishData: false,
      canPublishSources: ["microphone"],
    });
    expect(claims.exp! - claims.nbf!).toBe(LIVE_TOKEN_TTL_SECONDS);
  });

  it("gives each viewer session a distinct identity", async () => {
    const a = await issuer.viewerToken({ deviceId, userId: "u1" });
    const b = await issuer.viewerToken({ deviceId, userId: "u1" });
    expect(a.identity).not.toBe(b.identity);
  });

  it("lets the camera publish camera and microphone", async () => {
    const res = await issuer.cameraToken({ deviceId, name: "Living room" });
    expect(res.identity).toBe(`camera:${deviceId}`);
    const claims = await verifier.verify(res.token);
    expect(claims.video).toMatchObject({
      room: roomForCamera(deviceId),
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishSources: ["camera", "microphone"],
    });
  });

  it("signs with the configured secret", async () => {
    const res = await issuer.cameraToken({ deviceId });
    await expect(new TokenVerifier(LIVEKIT.apiKey, "wrong-secret-wrong-secret-wrong").verify(res.token)).rejects.toThrow();
  });
});

describe.skipIf(!hasDatabase)("live token routes", () => {
  let h: DbHandle;
  let ctx: Awaited<ReturnType<typeof buildTestApp>>;
  let app: FastifyInstance;
  let unconfigured: FastifyInstance;
  const hub = new RealtimeHub();

  beforeAll(async () => {
    h = openTestDb();
    ctx = await buildTestApp(h, { live: createLiveKitIssuer(LIVEKIT), hub });
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

  /** Owner with a household and one paired camera. */
  async function setup() {
    const owner = await signIn("owner");
    await app.inject({ method: "POST", url: "/households", headers: owner.auth, payload: { name: "Home" } });
    const invite = (await app.inject({ method: "POST", url: "/invites", headers: owner.auth })).json();
    const accepted = (
      await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, payload: { as: "camera", deviceName: "Living room" } })
    ).json();
    const camera = {
      id: accepted.device.id as string,
      auth: { authorization: `Device ${accepted.device.id}:${accepted.deviceSecret}` },
    };
    return { owner, camera };
  }

  it("mints a viewer token for a household camera", async () => {
    const { owner, camera } = await setup();
    const res = await app.inject({ method: "POST", url: `/cameras/${camera.id}/live-token`, headers: owner.auth });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body).toMatchObject({ url: LIVEKIT.url, room: roomForCamera(camera.id) });
    const claims = await verifier.verify(body.token);
    expect(claims.name).toBe("owner");
    expect(claims.sub).toMatch(new RegExp(`^viewer:${owner.userId}:`));
  });

  it("tells viewer and camera whether live video is end-to-end encrypted", async () => {
    const { owner, camera } = await setup();
    const viewerToken = () => app.inject({ method: "POST", url: `/cameras/${camera.id}/live-token`, headers: owner.auth });
    const cameraToken = () => app.inject({ method: "POST", url: "/device/live-token", headers: camera.auth });
    expect((await viewerToken()).json().encrypted).toBe(false);
    expect((await cameraToken()).json().encrypted).toBe(false);

    await app.inject({ method: "PATCH", url: "/household", headers: owner.auth, payload: { liveEncrypted: true } });
    expect((await viewerToken()).json().encrypted).toBe(true);
    expect((await cameraToken()).json().encrypted).toBe(true);
  });

  it("hides cameras of other households and non-camera devices", async () => {
    const { camera } = await setup();
    const stranger = await signIn("stranger");
    await app.inject({ method: "POST", url: "/households", headers: stranger.auth, payload: { name: "Other" } });
    const res = await app.inject({ method: "POST", url: `/cameras/${camera.id}/live-token`, headers: stranger.auth });
    expect(res.statusCode).toBe(404);

    const viewer = (
      await app.inject({ method: "POST", url: "/devices", headers: stranger.auth, payload: { name: "Phone", role: "viewer" } })
    ).json();
    const asCamera = await app.inject({ method: "POST", url: `/cameras/${viewer.id}/live-token`, headers: stranger.auth });
    expect(asCamera.statusCode).toBe(404);
  });

  it("requires sign-in and a household", async () => {
    const { camera } = await setup();
    expect((await app.inject({ method: "POST", url: `/cameras/${camera.id}/live-token` })).statusCode).toBe(401);
    const loner = await signIn("loner");
    const res = await app.inject({ method: "POST", url: `/cameras/${camera.id}/live-token`, headers: loner.auth });
    expect(res.statusCode).toBe(403);
  });

  it("enforces 5 viewers per camera, without counting a user twice", async () => {
    const { owner, camera } = await setup();
    const peers = Array.from({ length: 5 }, () => ({ send() {} }));
    peers.forEach((peer, i) => {
      hub.viewerConnected(peer, "h", [], 0, i === 0 ? owner.userId : `other-${i}`);
      hub.watch(peer, camera.id);
    });
    try {
      // The owner is one of the five (e.g. a second phone or a reconnect): allowed.
      const again = await app.inject({ method: "POST", url: `/cameras/${camera.id}/live-token`, headers: owner.auth });
      expect(again.statusCode).toBe(200);

      const member = await signIn("member");
      const { householdMembers, households } = await import("../src/db/schema.js");
      const [home] = await h.db.select().from(households);
      await h.db.insert(householdMembers).values({ householdId: home!.id, userId: member.userId, role: "member" });
      const sixth = await app.inject({ method: "POST", url: `/cameras/${camera.id}/live-token`, headers: member.auth });
      expect(sixth.statusCode).toBe(409);
      expect(sixth.json()).toEqual({ error: "viewer_limit_reached", limit: 5 });
    } finally {
      peers.forEach((peer) => hub.viewerDisconnected(peer));
    }
  });

  it("refuses revoked cameras", async () => {
    const { owner, camera } = await setup();
    await app.inject({ method: "POST", url: `/devices/${camera.id}/revoke`, headers: owner.auth });
    const res = await app.inject({ method: "POST", url: `/cameras/${camera.id}/live-token`, headers: owner.auth });
    expect(res.statusCode).toBe(409);
  });

  it("mints a publisher token for the camera itself", async () => {
    const { camera } = await setup();
    const res = await app.inject({ method: "POST", url: "/device/live-token", headers: camera.auth });
    expect(res.statusCode).toBe(200);
    const claims = await verifier.verify(res.json().token);
    expect(claims.sub).toBe(`camera:${camera.id}`);
    expect(claims.video?.room).toBe(roomForCamera(camera.id));
    expect((await app.inject({ method: "POST", url: "/device/live-token" })).statusCode).toBe(401);
  });

  it("answers 503 when LiveKit is not configured", async () => {
    const { owner, camera } = await setup();
    const viewer = await unconfigured.inject({ method: "POST", url: `/cameras/${camera.id}/live-token`, headers: owner.auth });
    expect(viewer.statusCode).toBe(503);
    expect(viewer.json()).toEqual({ error: "live_not_configured" });
    const cam = await unconfigured.inject({ method: "POST", url: "/device/live-token", headers: camera.auth });
    expect(cam.statusCode).toBe(503);
  });
});
