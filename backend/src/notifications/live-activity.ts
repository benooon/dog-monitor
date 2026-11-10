import { and, eq, inArray, lt, sql } from "drizzle-orm";
import type { FastifyBaseLogger } from "fastify";
import type { Database } from "../db/client.js";
import { devices, householdMembers, liveActivities, type DogState } from "../db/schema.js";
import { isDeadToken, type ApnsSender } from "./apns.js";

/** iOS ends a Live Activity after at most 12 hours (8 h active + 4 h on the Lock Screen). */
const MAX_AGE = sql`now() - interval '12 hours'`;

/** At most one update per camera in this window; the latest state wins. */
export const LIVE_ACTIVITY_MIN_INTERVAL_MS = 15_000;

/** States worth lighting up the Dynamic Island right away (priority 10); the rest go at 5. */
const URGENT_STATES: ReadonlySet<DogState> = new Set<DogState>(["barking", "whining", "atDoor", "forbiddenZone"]);

/** Mirrors the iOS `ActivityAttributes.ContentState` (keep field names in sync). */
export interface LiveActivityContent {
  state: DogState | null;
  online: boolean;
}

export function liveActivityPayload(content: LiveActivityContent, now: Date): Record<string, unknown> {
  return {
    aps: {
      timestamp: Math.floor(now.getTime() / 1000),
      event: "update",
      "content-state": content,
    },
  };
}

export function liveActivityPriority(content: LiveActivityContent): 10 | 5 {
  return !content.online || (content.state !== null && URGENT_STATES.has(content.state)) ? 10 : 5;
}

export interface LiveActivityNotifierOptions {
  /** The current online state and dog state, as the realtime hub knows it. */
  status: (cameraId: string) => { online: boolean; state: DogState | null } | null;
  now?: () => number;
  minIntervalMs?: number;
}

/**
 * Keeps viewers' Live Activities in step with each camera: call `cameraChanged` on a dog-state or
 * online change. Updates are throttled per camera (trailing send with the latest state), activities
 * whose user left the household or that iOS has ended are skipped, and dead tokens are deleted.
 */
export class LiveActivityNotifier {
  private readonly lastSentAt = new Map<string, number>();
  private readonly timers = new Map<string, NodeJS.Timeout>();
  private readonly now: () => number;
  private readonly minIntervalMs: number;

  constructor(
    private readonly db: Database,
    private readonly apns: ApnsSender | undefined,
    private readonly log: FastifyBaseLogger,
    private readonly options: LiveActivityNotifierOptions,
  ) {
    this.now = options.now ?? Date.now;
    this.minIntervalMs = options.minIntervalMs ?? LIVE_ACTIVITY_MIN_INTERVAL_MS;
  }

  cameraChanged(cameraId: string): void {
    if (!this.apns || this.timers.has(cameraId)) return;
    // Always via a timer, so a presence and a state change from the same heartbeat go out as one push.
    const wait = Math.max(0, (this.lastSentAt.get(cameraId) ?? -Infinity) + this.minIntervalMs - this.now());
    const timer = setTimeout(() => {
      this.timers.delete(cameraId);
      void this.flush(cameraId);
    }, wait);
    timer.unref();
    this.timers.set(cameraId, timer);
  }

  /** Sends the camera's current state to every live activity showing it. */
  async flush(cameraId: string): Promise<number> {
    if (!this.apns) return 0;
    this.lastSentAt.set(cameraId, this.now());
    try {
      return await this.send(cameraId);
    } catch (err) {
      this.log.error({ err, cameraId }, "live activity update failed");
      return 0;
    }
  }

  close(): void {
    for (const timer of this.timers.values()) clearTimeout(timer);
    this.timers.clear();
  }

  private async send(cameraId: string): Promise<number> {
    const now = new Date(this.now());
    // Registration time comes from the database clock, so age is measured there too.
    await this.db.delete(liveActivities).where(and(eq(liveActivities.cameraId, cameraId), lt(liveActivities.createdAt, MAX_AGE)));

    const rows = await this.db
      .select({ id: liveActivities.id, pushToken: liveActivities.pushToken })
      .from(liveActivities)
      .innerJoin(
        householdMembers,
        and(eq(householdMembers.householdId, liveActivities.householdId), eq(householdMembers.userId, liveActivities.userId)),
      )
      .where(eq(liveActivities.cameraId, cameraId));
    if (rows.length === 0) return 0;

    const content = await this.content(cameraId);
    const payload = liveActivityPayload(content, now);
    const priority = liveActivityPriority(content);
    const dead: string[] = [];
    let sent = 0;
    for (const row of rows) {
      const result = await this.apns!.send({ deviceToken: row.pushToken, payload, pushType: "liveactivity", priority });
      if (result.status === 200) sent += 1;
      else if (isDeadToken(result)) dead.push(row.id);
      else this.log.warn({ cameraId, status: result.status, reason: result.reason }, "live activity push rejected");
    }
    if (dead.length > 0) await this.db.delete(liveActivities).where(inArray(liveActivities.id, dead));
    return sent;
  }

  private async content(cameraId: string): Promise<LiveActivityContent> {
    const known = this.options.status(cameraId);
    if (known && known.state !== null) return { state: known.state, online: known.online };
    const [row] = await this.db.select({ dogState: devices.dogState }).from(devices).where(eq(devices.id, cameraId));
    return { state: known?.state ?? row?.dogState ?? null, online: known?.online ?? false };
  }
}
