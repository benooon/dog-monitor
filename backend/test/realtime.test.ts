import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import type { WebSocket } from "ws";
import type { DbHandle } from "../src/db/client.js";
import { devices } from "../src/db/schema.js";
import { OFFLINE_AFTER_MS, RealtimeHub } from "../src/realtime/hub.js";
import type { ServerMessage } from "../src/realtime/protocol.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

/** A test WebSocket client that queues incoming JSON messages. */
interface Client {
  ws: WebSocket;
  next(): Promise<ServerMessage>;
  send(message: unknown): void;
  closed: Promise<number>;
}

describe.skipIf(!hasDatabase)("realtime channel (GET /ws)", () => {
  let h: DbHandle;
  let app: FastifyInstance;
  let ctx: Awaited<ReturnType<typeof buildTestApp>>;
  let hub: RealtimeHub;
  let clock = 1_800_000_000_000;
  const clients: Client[] = [];

  beforeAll(async () => {
    h = openTestDb();
  });
  beforeEach(async () => {
    await truncateAll(h);
    hub = new RealtimeHub();
    ctx = await buildTestApp(h, { hub, now: () => clock });
    app = ctx.app;
    await app.ready();
  });
  afterEach(async () => {
    for (const c of clients.splice(0)) c.ws.terminate();
    await app.close();
  });
  afterAll(async () => {
    await h.close();
  });

  async function connect(headers: Record<string, string>): Promise<Client> {
    const queue: ServerMessage[] = [];
    const waiters: ((m: ServerMessage) => void)[] = [];
    let resolveClosed!: (code: number) => void;
    const closed = new Promise<number>((r) => (resolveClosed = r));
    const ws = await app.injectWS("/ws", { headers }, {
      onInit(socket) {
        socket.on("message", (data) => {
          const message = JSON.parse(data.toString()) as ServerMessage;
          const waiter = waiters.shift();
          if (waiter) waiter(message);
          else queue.push(message);
        });
        socket.on("close", (code) => resolveClosed(code));
      },
    });
    const client: Client = {
      ws,
      closed,
      send: (message) => ws.send(JSON.stringify(message)),
      next: () =>
        new Promise<ServerMessage>((resolve, reject) => {
          const queued = queue.shift();
          if (queued) return resolve(queued);
          const timer = setTimeout(() => reject(new Error("no message within 2s")), 2000);
          waiters.push((m) => {
            clearTimeout(timer);
            resolve(m);
          });
        }),
    };
    clients.push(client);
    return client;
  }

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
    await app.inject({ method: "POST", url: "/households", headers: owner.auth, payload: { name: "Home" } });
    const invite = (await app.inject({ method: "POST", url: "/invites", headers: owner.auth })).json();
    const accepted = (
      await app.inject({ method: "POST", url: `/invites/${invite.token}/accept`, payload: { as: "camera", deviceName: "Living room" } })
    ).json();
    return {
      owner,
      camera: { id: accepted.device.id as string, auth: { authorization: `Device ${accepted.device.id}:${accepted.deviceSecret}` } },
    };
  }

  /** Polls until `check` passes (the server writes heartbeats to the DB asynchronously). */
  async function eventually(check: () => Promise<void>, timeoutMs = 2000) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      try {
        return await check();
      } catch (error) {
        if (Date.now() > deadline) throw error;
        await new Promise((r) => setTimeout(r, 20));
      }
    }
  }

  it("rejects unauthenticated upgrades", async () => {
    await expect(app.injectWS("/ws", { headers: {} })).rejects.toThrow();
    await expect(app.injectWS("/ws", { headers: { authorization: "Bearer nope" } })).rejects.toThrow();
  });

  it("closes viewer connections without a household", async () => {
    const loner = await signIn("loner");
    const client = await connect(loner.auth);
    expect(await client.next()).toEqual({ type: "error", error: "no_household" });
    expect(await client.closed).toBe(4003);
  });

  it("relays presence, heartbeats and viewer joins between camera and viewers", async () => {
    const { owner, camera } = await setup();
    const viewer = await connect(owner.auth);
    expect(await viewer.next()).toEqual({ type: "cameras", cameras: [{ id: camera.id, online: false }] });

    const cam = await connect(camera.auth);
    cam.send({ type: "heartbeat", battery: 0.8, charging: true, thermal: "nominal" });
    expect(await viewer.next()).toEqual({ type: "presence", cameraId: camera.id, online: true });

    await eventually(async () => {
      const [row] = await h.db.select().from(devices).where(eq(devices.id, camera.id));
      expect(row).toMatchObject({ battery: 0.8, charging: true, thermal: "nominal" });
      expect(row!.lastHeartbeatAt?.getTime()).toBe(clock);
    });

    viewer.send({ type: "watch", cameraId: camera.id });
    expect(await cam.next()).toEqual({ type: "viewers", count: 1, change: "joined" });

    viewer.ws.terminate();
    expect(await cam.next()).toEqual({ type: "viewers", count: 0, change: "left" });
  });

  it("marks the camera offline 3 minutes after its last heartbeat", async () => {
    const { owner, camera } = await setup();
    const viewer = await connect(owner.auth);
    await viewer.next();
    const cam = await connect(camera.auth);
    cam.send({ type: "heartbeat" });
    expect(await viewer.next()).toMatchObject({ type: "presence", online: true });

    clock += OFFLINE_AFTER_MS;
    hub.sweep(clock);
    expect(await viewer.next()).toEqual({ type: "presence", cameraId: camera.id, online: false });
  });

  it("refuses to watch cameras outside the household and bad messages", async () => {
    const { camera } = await setup();
    const stranger = await signIn("stranger");
    await app.inject({ method: "POST", url: "/households", headers: stranger.auth, payload: { name: "Other" } });
    const viewer = await connect(stranger.auth);
    expect(await viewer.next()).toEqual({ type: "cameras", cameras: [] });

    viewer.send({ type: "watch", cameraId: camera.id });
    expect(await viewer.next()).toEqual({ type: "error", error: "not_found" });
    expect(hub.viewerCount(camera.id)).toBe(0);

    viewer.send({ type: "dance" });
    expect(await viewer.next()).toEqual({ type: "error", error: "bad_message" });

    const cam = await connect(camera.auth);
    cam.send({ type: "heartbeat", battery: 7 });
    expect(await cam.next()).toEqual({ type: "error", error: "bad_message" });
  });
});
