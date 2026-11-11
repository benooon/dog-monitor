import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { and, eq } from "drizzle-orm";
import type { WebSocket } from "@fastify/websocket";
import type { Database } from "../db/client.js";
import { devices } from "../db/schema.js";
import { LIMITS } from "../households/limits.js";
import { findMembership } from "../households/scope.js";
import type { Peer, RealtimeHub } from "../realtime/hub.js";
import { parseCameraMessage, parseViewerMessage, type ServerMessage } from "../realtime/protocol.js";
import { RealtimeSessions } from "../realtime/sessions.js";

/** Keeps idle connections alive through proxies (Railway) and detects dead peers. */
const PING_INTERVAL_MS = 30_000;
/** Close codes in the 4000–4999 application range. */
const CLOSE_FORBIDDEN = 4003;
/** Policy violation (RFC 6455), used when a peer floods the socket. */
const CLOSE_POLICY = 1008;
/** Per-socket message budget: a burst of 20, refilled at 5 per second. Heartbeats and watches are far below this. */
export const WS_MESSAGE_BURST = 20;
export const WS_MESSAGES_PER_SECOND = 5;

interface RealtimeOptions {
  /** Closes sockets when access is taken away (member removed, device revoked, household deleted). */
  sessions?: RealtimeSessions;
  db: Database;
  hub: RealtimeHub;
  now: () => number;
}

function peerFor(socket: WebSocket): Peer {
  return {
    send(message: ServerMessage) {
      if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message));
    },
  };
}

/** `GET /ws`: realtime channel for cameras (device auth) and viewers (user auth). See realtime/protocol.ts. */
export async function realtimeRoutes(app: FastifyInstance, opts: RealtimeOptions): Promise<void> {
  const { db, hub, now } = opts;

  async function authenticateEither(request: FastifyRequest, reply: FastifyReply) {
    return request.headers.authorization?.startsWith("Device ")
      ? app.authenticateDevice(request, reply)
      : app.authenticate(request, reply);
  }

  app.get("/ws", { websocket: true, preValidation: authenticateEither }, (socket, request) => {
    const peer = peerFor(socket);
    const ping = setInterval(() => socket.ping(), PING_INTERVAL_MS);
    ping.unref();

    // Listeners must be attached synchronously; messages wait until the connection is set up.
    let onMessage: (raw: string) => Promise<void> = async () => {};
    let onClose: () => void = () => {};
    let untrack: () => void = () => {};
    const ready = (request.device ? setUpCamera() : setUpViewer()).catch((error: unknown) => {
      request.log.error({ err: error }, "websocket setup failed");
      socket.close(1011, "internal_error");
    });

    // Messages are handled one at a time per socket, within a token bucket, so one client
    // cannot fan out unbounded concurrent database work.
    let tokens = WS_MESSAGE_BURST;
    let refilledAt = Date.now();
    let queue: Promise<void> = ready;
    socket.on("message", (data) => {
      const at = Date.now();
      tokens = Math.min(WS_MESSAGE_BURST, tokens + ((at - refilledAt) / 1000) * WS_MESSAGES_PER_SECOND);
      refilledAt = at;
      if (tokens < 1) {
        socket.close(CLOSE_POLICY, "rate_limited");
        return;
      }
      tokens -= 1;
      const raw = data.toString();
      queue = queue
        .then(() => (socket.readyState === socket.OPEN ? onMessage(raw) : undefined))
        .catch((error: unknown) => {
          request.log.error({ err: error }, "websocket message failed");
        });
    });
    socket.on("close", () => {
      clearInterval(ping);
      // Setup may still be running; untrack only once it has registered the session, or the entry leaks.
      void ready.then(() => {
        untrack();
        onClose();
      });
    });

    function reject(error: string) {
      peer.send({ type: "error", error });
      socket.close(CLOSE_FORBIDDEN, error);
    }

    async function setUpCamera() {
      const deviceId = request.device!.deviceId;
      const [device] = await db
        .select({ role: devices.role, householdId: devices.householdId, lastHeartbeatAt: devices.lastHeartbeatAt })
        .from(devices)
        .where(eq(devices.id, deviceId));
      if (device?.role !== "camera") return reject("camera_only");
      untrack = opts.sessions?.track([RealtimeSessions.device(deviceId), RealtimeSessions.household(device.householdId)], reject) ?? untrack;

      hub.cameraConnected(deviceId, device.householdId, peer, device.lastHeartbeatAt?.getTime() ?? null, now());
      onClose = () => hub.cameraDisconnected(deviceId, peer);
      onMessage = async (raw) => {
        const message = parseCameraMessage(raw);
        if (!message) return peer.send({ type: "error", error: "bad_message" });
        const at = now();
        // A revoked camera's socket stops here even if it was missed when it was revoked.
        const updated = await db
          .update(devices)
          .set({
            lastHeartbeatAt: new Date(at),
            ...(message.battery !== undefined && { battery: message.battery }),
            ...(message.charging !== undefined && { charging: message.charging }),
            ...(message.thermal !== undefined && { thermal: message.thermal }),
            ...(message.state !== undefined && { dogState: message.state }),
            // Every heartbeat says it; older apps never send it, and they publish as before.
            liveKeyMissing: message.liveKeyMissing ?? false,
            liveKeyId: message.liveKeyId ?? null,
          })
          .where(and(eq(devices.id, deviceId), eq(devices.status, "active")))
          .returning({ id: devices.id });
        if (updated.length === 0) return reject("device_revoked");
        hub.heartbeat(deviceId, at, message.state);
      };
    }

    async function setUpViewer() {
      const membership = await findMembership(db, request.user!.userId);
      if (!membership) return reject("no_household");
      const { householdId } = membership;
      const userId = request.user!.userId;
      untrack = opts.sessions?.track([RealtimeSessions.user(userId), RealtimeSessions.household(householdId)], reject) ?? untrack;

      const cameras = await db
        .select({ id: devices.id, lastHeartbeatAt: devices.lastHeartbeatAt, dogState: devices.dogState })
        .from(devices)
        .where(and(eq(devices.householdId, householdId), eq(devices.role, "camera"), eq(devices.status, "active")));
      hub.viewerConnected(
        peer,
        householdId,
        cameras.map((c) => ({ id: c.id, lastHeartbeatAt: c.lastHeartbeatAt?.getTime() ?? null, dogState: c.dogState })),
        now(),
        request.user!.userId,
      );
      onClose = () => hub.viewerDisconnected(peer);
      onMessage = async (raw) => {
        const message = parseViewerMessage(raw);
        if (!message) return peer.send({ type: "error", error: "bad_message" });
        if (message.type === "unwatch") return hub.unwatch(peer, message.cameraId);
        if ((await findMembership(db, userId))?.householdId !== householdId) return reject("no_household");

        const [camera] = await db
          .select({ id: devices.id })
          .from(devices)
          .where(
            and(
              eq(devices.id, message.cameraId),
              eq(devices.householdId, householdId),
              eq(devices.role, "camera"),
              eq(devices.status, "active"),
            ),
          );
        if (!camera) return peer.send({ type: "error", error: "not_found" });
        if (hub.viewerCount(camera.id) >= LIMITS.viewersPerCamera && !hub.isWatching(camera.id, request.user!.userId)) {
          return peer.send({ type: "error", error: "viewer_limit_reached" });
        }
        hub.watch(peer, camera.id);
      };
    }
  });
}
