import type { ServerMessage } from "./protocol.js";

/** A camera without a heartbeat for this long is offline (SPEC §6 Health). */
export const OFFLINE_AFTER_MS = 3 * 60 * 1000;

/** Anything we can push a message to (a WebSocket in production, a stub in tests). */
export interface Peer {
  send(message: ServerMessage): void;
}

interface CameraState {
  householdId: string;
  lastHeartbeatAt: number | null;
  online: boolean;
  peers: Set<Peer>;
}

interface ViewerState {
  householdId: string;
  userId: string | null;
  watching: Set<string>;
}

export interface HubEvents {
  /** A camera's online state changed (e.g. to send the "camera offline" push later). */
  onPresenceChange?: (cameraId: string, householdId: string, online: boolean) => void;
}

/**
 * In-memory presence for one API instance: which cameras are online, which viewers watch which
 * camera. Pure bookkeeping (no sockets, no DB, time passed in), so it is unit-testable.
 * MVP runs a single instance on Railway; scaling out would need a shared store (DECISIONS.md).
 */
export class RealtimeHub {
  private readonly cameras = new Map<string, CameraState>();
  private readonly viewers = new Map<Peer, ViewerState>();
  /** cameraId → viewer peers watching it. */
  private readonly watchers = new Map<string, Set<Peer>>();

  constructor(private readonly events: HubEvents = {}) {}

  // MARK: cameras

  /**
   * Registers a camera connection. `lastHeartbeatAt` comes from the DB so a quick reconnect
   * keeps the camera online.
   */
  cameraConnected(cameraId: string, householdId: string, peer: Peer, lastHeartbeatAt: number | null, now: number): void {
    const state = this.camera(cameraId, householdId);
    state.peers.add(peer);
    if (lastHeartbeatAt !== null && (state.lastHeartbeatAt ?? 0) < lastHeartbeatAt) {
      state.lastHeartbeatAt = lastHeartbeatAt;
    }
    this.updateOnline(cameraId, state, now);
    // Tell the camera right away whether anyone is already watching.
    const count = this.viewerCount(cameraId);
    if (count > 0) peer.send({ type: "viewers", count, change: "joined" });
  }

  /** The camera stays "online" until its heartbeat goes stale, so short network drops don't flap. */
  cameraDisconnected(cameraId: string, peer: Peer): void {
    this.cameras.get(cameraId)?.peers.delete(peer);
  }

  heartbeat(cameraId: string, now: number): void {
    const state = this.cameras.get(cameraId);
    if (!state) return;
    state.lastHeartbeatAt = now;
    this.updateOnline(cameraId, state, now);
  }

  isOnline(cameraId: string): boolean {
    return this.cameras.get(cameraId)?.online ?? false;
  }

  /** Marks cameras offline whose heartbeat is older than OFFLINE_AFTER_MS. Call periodically. */
  sweep(now: number): void {
    for (const [cameraId, state] of this.cameras) {
      this.updateOnline(cameraId, state, now);
      if (!state.online && state.peers.size === 0 && !this.watchers.has(cameraId)) {
        this.cameras.delete(cameraId);
      }
    }
  }

  // MARK: viewers

  viewerConnected(
    peer: Peer,
    householdId: string,
    cameras: { id: string; lastHeartbeatAt: number | null }[],
    now: number,
    userId: string | null = null,
  ): void {
    this.viewers.set(peer, { householdId, userId, watching: new Set() });
    peer.send({
      type: "cameras",
      cameras: cameras.map((c) => {
        const known = this.cameras.get(c.id);
        const online = known ? known.online : c.lastHeartbeatAt !== null && now - c.lastHeartbeatAt < OFFLINE_AFTER_MS;
        return { id: c.id, online };
      }),
    });
  }

  viewerDisconnected(peer: Peer): void {
    const viewer = this.viewers.get(peer);
    if (!viewer) return;
    for (const cameraId of [...viewer.watching]) this.unwatch(peer, cameraId);
    this.viewers.delete(peer);
  }

  /** The caller must have checked that the camera belongs to the viewer's household. */
  watch(peer: Peer, cameraId: string): void {
    const viewer = this.viewers.get(peer);
    if (!viewer || viewer.watching.has(cameraId)) return;
    viewer.watching.add(cameraId);
    const set = this.watchers.get(cameraId) ?? new Set<Peer>();
    set.add(peer);
    this.watchers.set(cameraId, set);
    this.notifyCamera(cameraId, "joined");
  }

  unwatch(peer: Peer, cameraId: string): void {
    const viewer = this.viewers.get(peer);
    if (!viewer?.watching.delete(cameraId)) return;
    const set = this.watchers.get(cameraId);
    set?.delete(peer);
    if (set && set.size === 0) this.watchers.delete(cameraId);
    this.notifyCamera(cameraId, "left");
  }

  viewerCount(cameraId: string): number {
    return this.watchers.get(cameraId)?.size ?? 0;
  }

  /** Whether `userId` already watches `cameraId` from any connection. */
  isWatching(cameraId: string, userId: string): boolean {
    for (const peer of this.watchers.get(cameraId) ?? []) {
      if (this.viewers.get(peer)?.userId === userId) return true;
    }
    return false;
  }

  // MARK: private

  private camera(cameraId: string, householdId: string): CameraState {
    let state = this.cameras.get(cameraId);
    if (!state) {
      state = { householdId, lastHeartbeatAt: null, online: false, peers: new Set() };
      this.cameras.set(cameraId, state);
    }
    return state;
  }

  private updateOnline(cameraId: string, state: CameraState, now: number): void {
    const online = state.lastHeartbeatAt !== null && now - state.lastHeartbeatAt < OFFLINE_AFTER_MS;
    if (online === state.online) return;
    state.online = online;
    for (const [peer, viewer] of this.viewers) {
      if (viewer.householdId === state.householdId) peer.send({ type: "presence", cameraId, online });
    }
    this.events.onPresenceChange?.(cameraId, state.householdId, online);
  }

  private notifyCamera(cameraId: string, change: "joined" | "left"): void {
    const count = this.viewerCount(cameraId);
    for (const peer of this.cameras.get(cameraId)?.peers ?? []) {
      peer.send({ type: "viewers", count, change });
    }
  }
}
