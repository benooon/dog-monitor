/**
 * WebSocket protocol on `GET /ws` (SPEC §6 Realtime). Every message is one JSON object with a `type`.
 *
 * Camera (Authorization: Device <id>:<secret>):
 *   → { type: "heartbeat", battery?: 0...1, charging?: bool, thermal?: "nominal"|"fair"|"serious"|"critical", state?: DogState }
 *   ← { type: "viewers", count: n, change: "joined" | "left" }   (count 0 = all viewers left)
 *
 * Viewer (Authorization: Bearer <JWT>):
 *   → { type: "watch", cameraId } / { type: "unwatch", cameraId }
 *   ← { type: "cameras", cameras: [{ id, online, state }] }        (once, on connect; state may be null)
 *   ← { type: "presence", cameraId, online }                        (on every change)
 *   ← { type: "cameraState", cameraId, state }                      (when the dog's state changes)
 *
 * Both:
 *   ← { type: "error", error: "<code>" }   (bad_message, not_found, viewer_limit_reached, camera_only, no_household)
 */

import { DOG_STATES, type DogState } from "../db/schema.js";

export const THERMAL_STATES = ["nominal", "fair", "serious", "critical"] as const;
export type ThermalState = (typeof THERMAL_STATES)[number];

export interface HeartbeatMessage {
  type: "heartbeat";
  battery?: number;
  charging?: boolean;
  thermal?: ThermalState;
  state?: DogState;
}

export type CameraInbound = HeartbeatMessage;
export type ViewerInbound = { type: "watch"; cameraId: string } | { type: "unwatch"; cameraId: string };

export type ServerMessage =
  | { type: "viewers"; count: number; change: "joined" | "left" }
  | { type: "cameras"; cameras: { id: string; online: boolean; state: DogState | null }[] }
  | { type: "presence"; cameraId: string; online: boolean }
  | { type: "cameraState"; cameraId: string; state: DogState }
  | { type: "error"; error: string };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function parseObject(raw: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(raw);
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

export function parseCameraMessage(raw: string): CameraInbound | null {
  const msg = parseObject(raw);
  if (msg?.type !== "heartbeat") return null;
  const out: HeartbeatMessage = { type: "heartbeat" };
  if (msg.battery !== undefined) {
    if (typeof msg.battery !== "number" || !Number.isFinite(msg.battery) || msg.battery < 0 || msg.battery > 1) return null;
    out.battery = msg.battery;
  }
  if (msg.charging !== undefined) {
    if (typeof msg.charging !== "boolean") return null;
    out.charging = msg.charging;
  }
  if (msg.thermal !== undefined) {
    if (!THERMAL_STATES.includes(msg.thermal as ThermalState)) return null;
    out.thermal = msg.thermal as ThermalState;
  }
  if (msg.state !== undefined) {
    if (!DOG_STATES.includes(msg.state as DogState)) return null;
    out.state = msg.state as DogState;
  }
  return out;
}

export function parseViewerMessage(raw: string): ViewerInbound | null {
  const msg = parseObject(raw);
  if ((msg?.type !== "watch" && msg?.type !== "unwatch") || typeof msg.cameraId !== "string" || !UUID_RE.test(msg.cameraId)) {
    return null;
  }
  return { type: msg.type, cameraId: msg.cameraId };
}
