import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { and, eq } from "drizzle-orm";
import type { WebSocket } from "@fastify/websocket";
import type { Database } from "../db/client.js";
import { devices } from "../db/schema.js";
import { LIMITS } from "../households/limits.js";
import { findMembership } from "../households/scope.js";
import type { Peer, RealtimeHub } from "../realtime/hub.js";
import { parseCameraMessage, parseViewerMessage, type ServerMessage } from "../realtime/protocol.js";

/** Keeps idle connections alive through proxies (Railway) and detects dead peers. */
const PING_INTERVAL_MS = 30_000;
/** Close codes in the 4000–4999 application range. */
const CLOSE_FORBIDDEN = 4003;

interface RealtimeOptions {
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
    const ready = (request.device ? setUpCamera() : setUpViewer()).catch((error: unknown) => {
      request.log.error({ err: error }, "websocket setup failed");
      socket.close(1011, "internal_error");
    });

    socket.on("message", (data) => {
      void ready.then(() => onMessage(data.toString())).catch((error: unknown) => {
        request.log.error({ err: error }, "websocket message failed");
      });
    });
    socket.on("close", () => {
      clearInterval(ping);
      void ready.then(() => onClose());
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

      hub.cameraConnected(deviceId, device.householdId, peer, device.lastHeartbeatAt?.getTime() ?? null, now());
      onClose = () => hub.cameraDisconnected(deviceId, peer);
      onMessage = async (raw) => {
        const message = parseCameraMessage(raw);
        if (!message) return peer.send({ type: "error", error: "bad_message" });
        const at = now();
        hub.heartbeat(deviceId, at);
        await db
          .update(devices)
          .set({
            lastHeartbeatAt: new Date(at),
            ...(message.battery !== undefined && { battery: message.battery }),
            ...(message.charging !== undefined && { charging: message.charging }),
            ...(message.thermal !== undefined && { thermal: message.thermal }),
          })
          .where(eq(devices.id, deviceId));
      };
    }

    async function setUpViewer() {
      const membership = await findMembership(db, request.user!.userId);
      if (!membership) return reject("no_household");
      const { householdId } = membership;

      const cameras = await db
        .select({ id: devices.id, lastHeartbeatAt: devices.lastHeartbeatAt })
        .from(devices)
        .where(and(eq(devices.householdId, householdId), eq(devices.role, "camera"), eq(devices.status, "active")));
      hub.viewerConnected(
        peer,
        householdId,
        cameras.map((c) => ({ id: c.id, lastHeartbeatAt: c.lastHeartbeatAt?.getTime() ?? null })),
        now(),
        request.user!.userId,
      );
      onClose = () => hub.viewerDisconnected(peer);
      onMessage = async (raw) => {
        const message = parseViewerMessage(raw);
        if (!message) return peer.send({ type: "error", error: "bad_message" });
        if (message.type === "unwatch") return hub.unwatch(peer, message.cameraId);

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
