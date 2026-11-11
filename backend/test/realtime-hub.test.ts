import { describe, expect, it } from "vitest";
import { OFFLINE_AFTER_MS, RealtimeHub, type Peer } from "../src/realtime/hub.js";
import { parseCameraMessage, parseViewerMessage, type ServerMessage } from "../src/realtime/protocol.js";

class StubPeer implements Peer {
  messages: ServerMessage[] = [];
  send(message: ServerMessage) {
    this.messages.push(message);
  }
  take() {
    const out = this.messages;
    this.messages = [];
    return out;
  }
}

const H = "household-1";
const CAM = "11111111-1111-4111-8111-111111111111";
const T0 = 1_000_000;

describe("RealtimeHub", () => {
  it("tells the camera when viewers join and when all have left", () => {
    const hub = new RealtimeHub();
    const camera = new StubPeer();
    hub.cameraConnected(CAM, H, camera, null, T0);
    const a = new StubPeer();
    const b = new StubPeer();
    hub.viewerConnected(a, H, [{ id: CAM, lastHeartbeatAt: null }], T0);
    hub.viewerConnected(b, H, [{ id: CAM, lastHeartbeatAt: null }], T0);

    hub.watch(a, CAM);
    hub.watch(a, CAM); // duplicate watch is ignored
    hub.watch(b, CAM);
    expect(camera.take()).toEqual([
      { type: "viewers", count: 1, change: "joined" },
      { type: "viewers", count: 2, change: "joined" },
    ]);
    expect(hub.viewerCount(CAM)).toBe(2);

    hub.unwatch(a, CAM);
    hub.viewerDisconnected(b);
    expect(camera.take()).toEqual([
      { type: "viewers", count: 1, change: "left" },
      { type: "viewers", count: 0, change: "left" },
    ]);
  });

  it("knows which users watch a camera", () => {
    const hub = new RealtimeHub();
    const phone = new StubPeer();
    hub.viewerConnected(phone, H, [], T0, "user-1");
    expect(hub.isWatching(CAM, "user-1")).toBe(false);
    hub.watch(phone, CAM);
    expect(hub.isWatching(CAM, "user-1")).toBe(true);
    expect(hub.isWatching(CAM, "user-2")).toBe(false);
    hub.viewerDisconnected(phone);
    expect(hub.isWatching(CAM, "user-1")).toBe(false);
  });

  it("tells a (re)connecting camera that viewers are already waiting", () => {
    const hub = new RealtimeHub();
    const viewer = new StubPeer();
    hub.viewerConnected(viewer, H, [], T0);
    hub.watch(viewer, CAM);
    const camera = new StubPeer();
    hub.cameraConnected(CAM, H, camera, null, T0);
    expect(camera.take()).toEqual([{ type: "viewers", count: 1, change: "joined" }]);
  });

  it("goes online on heartbeat and offline 3 minutes after the last one", () => {
    const changes: [string, boolean][] = [];
    const hub = new RealtimeHub({ onPresenceChange: (id, _h, online) => changes.push([id, online]) });
    const viewer = new StubPeer();
    const stranger = new StubPeer();
    hub.viewerConnected(viewer, H, [{ id: CAM, lastHeartbeatAt: null }], T0);
    hub.viewerConnected(stranger, "other-household", [], T0);
    expect(viewer.take()).toEqual([{ type: "cameras", cameras: [{ id: CAM, online: false, state: null }] }]);

    const camera = new StubPeer();
    hub.cameraConnected(CAM, H, camera, null, T0);
    expect(hub.isOnline(CAM)).toBe(false);
    hub.heartbeat(CAM, T0 + 1000);
    expect(hub.isOnline(CAM)).toBe(true);
    expect(viewer.take()).toEqual([{ type: "presence", cameraId: CAM, online: true }]);

    hub.cameraDisconnected(CAM, camera);
    hub.sweep(T0 + 1000 + OFFLINE_AFTER_MS - 1);
    expect(hub.isOnline(CAM)).toBe(true); // a dropped socket alone doesn't flap presence

    hub.sweep(T0 + 1000 + OFFLINE_AFTER_MS);
    expect(hub.isOnline(CAM)).toBe(false);
    expect(viewer.take()).toEqual([{ type: "presence", cameraId: CAM, online: false }]);
    expect(stranger.take()).toEqual([{ type: "cameras", cameras: [] }]);
    expect(changes).toEqual([
      [CAM, true],
      [CAM, false],
    ]);
  });

  it("relays dog state changes to the household, once per change", () => {
    const hub = new RealtimeHub();
    const viewer = new StubPeer();
    hub.cameraConnected(CAM, H, new StubPeer(), null, T0);
    hub.viewerConnected(viewer, H, [{ id: CAM, lastHeartbeatAt: null }], T0);
    viewer.take();
    hub.heartbeat(CAM, T0, "barking");
    hub.heartbeat(CAM, T0 + 1, "barking");
    hub.heartbeat(CAM, T0 + 2);
    hub.heartbeat(CAM, T0 + 3, "resting");
    expect(viewer.take()).toEqual([
      { type: "presence", cameraId: CAM, online: true },
      { type: "cameraState", cameraId: CAM, state: "barking" },
      { type: "cameraState", cameraId: CAM, state: "resting" },
    ]);
    const late = new StubPeer();
    hub.viewerConnected(late, H, [{ id: CAM, lastHeartbeatAt: T0, dogState: "barking" }], T0 + 4);
    expect(late.take()).toEqual([{ type: "cameras", cameras: [{ id: CAM, online: true, state: "resting" }] }]);
  });

  it("keeps a camera online across a quick reconnect using the stored heartbeat", () => {
    const hub = new RealtimeHub();
    hub.cameraConnected(CAM, H, new StubPeer(), T0, T0 + 10_000);
    expect(hub.isOnline(CAM)).toBe(true);
    hub.cameraConnected("22222222-2222-4222-8222-222222222222", H, new StubPeer(), T0, T0 + OFFLINE_AFTER_MS);
    expect(hub.isOnline("22222222-2222-4222-8222-222222222222")).toBe(false);
  });

  it("reports stored presence for cameras it has not seen", () => {
    const hub = new RealtimeHub();
    const viewer = new StubPeer();
    hub.viewerConnected(viewer, H, [{ id: CAM, lastHeartbeatAt: T0 }], T0 + 60_000);
    expect(viewer.take()).toEqual([{ type: "cameras", cameras: [{ id: CAM, online: true, state: null }] }]);
  });
});

describe("protocol parsing", () => {
  it("accepts valid heartbeats and rejects bad fields", () => {
    expect(parseCameraMessage('{"type":"heartbeat"}')).toEqual({ type: "heartbeat" });
    expect(parseCameraMessage('{"type":"heartbeat","battery":0.5,"charging":true,"thermal":"fair"}')).toEqual({
      type: "heartbeat",
      battery: 0.5,
      charging: true,
      thermal: "fair",
    });
    expect(parseCameraMessage('{"type":"heartbeat","state":"barking"}')).toEqual({ type: "heartbeat", state: "barking" });
    expect(parseCameraMessage('{"type":"heartbeat","state":"dancing"}')).toBeNull();
    expect(parseCameraMessage('{"type":"heartbeat","battery":2}')).toBeNull();
    expect(parseCameraMessage('{"type":"heartbeat","thermal":"hot"}')).toBeNull();
    expect(parseCameraMessage('{"type":"heartbeat","charging":"yes"}')).toBeNull();
    expect(parseCameraMessage('{"type":"heartbeat","liveKeyMissing":true}')).toEqual({ type: "heartbeat", liveKeyMissing: true });
    expect(parseCameraMessage('{"type":"heartbeat","liveKeyMissing":"yes"}')).toBeNull();
    expect(parseCameraMessage("not json")).toBeNull();
    expect(parseCameraMessage("[]")).toBeNull();
  });

  it("accepts watch/unwatch with a uuid", () => {
    expect(parseViewerMessage(`{"type":"watch","cameraId":"${CAM}"}`)).toEqual({ type: "watch", cameraId: CAM });
    expect(parseViewerMessage(`{"type":"unwatch","cameraId":"${CAM}"}`)).toEqual({ type: "unwatch", cameraId: CAM });
    expect(parseViewerMessage('{"type":"watch","cameraId":"nope"}')).toBeNull();
    expect(parseViewerMessage(`{"type":"heartbeat","cameraId":"${CAM}"}`)).toBeNull();
  });
});
