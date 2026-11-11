import type { FastifyBaseLogger } from "fastify";
import { and, asc, eq, inArray, isNotNull, isNull, lte, or } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices, dogs, events, notificationPrefs, type EventPlace, type EventType } from "../db/schema.js";
import { isDeadToken, type ApnsSender } from "./apns.js";
import type { MediaStorage } from "../storage/storage.js";
import { buildEventPayload, enabledByDefault, interruptionLevel } from "./payload.js";
import { inQuietHours } from "./quiet-hours.js";

/** Long enough to open a notification a while after it arrived. */
export const SNAPSHOT_URL_TTL_SECONDS = 6 * 60 * 60;

export interface EventNotification {
  householdId: string;
  cameraId: string;
  eventId: string;
  type: EventType;
  /** forbiddenZone: which copy to use ("on the sofa" or "somewhere off-limits"). */
  place?: EventPlace | null;
  snapshotKey?: string | null;
  escalationSeconds?: number;
  /** dailySummary: the day's highlight reel is already attached. */
  hasReel?: boolean;
}

export interface NotifyResult {
  sent: number;
  failed: number;
  /** Viewers who turned this event type off, or are in quiet hours. */
  muted: number;
}

/**
 * Fans an event out as APNs pushes to the household's viewer devices, honoring each user's
 * `notification_prefs` (a per-camera row beats an all-cameras row, which beats the type default).
 * Quiet hours (in each phone's time zone) hold back everything except time-sensitive alerts.
 */
export class EventNotifier {
  constructor(
    private readonly db: Database,
    private readonly apns: ApnsSender | undefined,
    private readonly log: FastifyBaseLogger,
    private readonly storage?: MediaStorage,
    private readonly now: () => Date = () => new Date(),
  ) {}

  async notify(event: EventNotification): Promise<NotifyResult> {
    const result: NotifyResult = { sent: 0, failed: 0, muted: 0 };
    if (!this.apns) {
      this.log.warn({ eventId: event.eventId }, "APNS_* not set: event stored without push");
      return result;
    }

    const [camera] = await this.db.select({ name: devices.name }).from(devices).where(eq(devices.id, event.cameraId));
    const recipients = await this.db
      .select({ id: devices.id, userId: devices.userId, apnsToken: devices.apnsToken, timeZone: devices.timeZone })
      .from(devices)
      .where(
        and(
          eq(devices.householdId, event.householdId),
          eq(devices.role, "viewer"),
          eq(devices.status, "active"),
          isNotNull(devices.apnsToken),
          isNotNull(devices.userId),
          or(isNull(devices.mutedUntil), lte(devices.mutedUntil, new Date())),
        ),
      );
    if (recipients.length === 0) return result;

    const userIds = [...new Set(recipients.map((r) => r.userId!))];
    const prefs = await this.db
      .select({
        userId: notificationPrefs.userId,
        deviceId: notificationPrefs.deviceId,
        enabled: notificationPrefs.enabled,
        quietStart: notificationPrefs.quietStart,
        quietEnd: notificationPrefs.quietEnd,
      })
      .from(notificationPrefs)
      .where(and(inArray(notificationPrefs.userId, userIds), eq(notificationPrefs.eventType, event.type)));
    const now = this.now();
    // Time-sensitive alerts (prolonged barking, camera offline...) still come through quiet hours.
    const quietable = interruptionLevel(event.type) !== "time-sensitive";
    const wants = (userId: string, timeZone: string | null) => {
      const forCamera = prefs.find((p) => p.userId === userId && p.deviceId === event.cameraId);
      const forAll = prefs.find((p) => p.userId === userId && p.deviceId === null);
      const pref = forCamera ?? forAll;
      if (!(pref?.enabled ?? enabledByDefault(event.type))) return false;
      return !(quietable && pref && inQuietHours(now, timeZone, pref.quietStart, pref.quietEnd));
    };

    const [dog] = await this.db
      .select({ name: dogs.name })
      .from(dogs)
      .where(eq(dogs.householdId, event.householdId))
      .orderBy(asc(dogs.createdAt))
      .limit(1);
    const snapshotUrl =
      this.storage && event.snapshotKey
        ? await this.storage.presignDownload(event.snapshotKey, SNAPSHOT_URL_TTL_SECONDS).catch(() => undefined)
        : undefined;
    const payload = buildEventPayload({
      eventId: event.eventId,
      type: event.type,
      place: event.place,
      cameraId: event.cameraId,
      cameraName: camera?.name ?? "Dog Monitor",
      dogName: dog?.name,
      snapshotKey: event.snapshotKey,
      escalationSeconds: event.escalationSeconds,
      hasReel: event.hasReel,
      snapshotUrl,
    });

    const apns = this.apns;
    await Promise.all(
      recipients.map(async (recipient) => {
        if (!wants(recipient.userId!, recipient.timeZone)) {
          result.muted += 1;
          return;
        }
        try {
          const response = await apns.send({
            deviceToken: recipient.apnsToken!,
            payload,
            priority: payload.aps && (payload.aps as Record<string, unknown>)["interruption-level"] === "passive" ? 5 : 10,
            // Escalations replace the original alert instead of stacking up.
            collapseId: event.eventId,
          });
          if (response.status === 200) {
            result.sent += 1;
            return;
          }
          result.failed += 1;
          this.log.warn({ status: response.status, reason: response.reason, deviceId: recipient.id }, "APNs rejected push");
          if (isDeadToken(response)) {
            await this.db.update(devices).set({ apnsToken: null }).where(eq(devices.id, recipient.id));
          }
        } catch (error) {
          result.failed += 1;
          this.log.error({ err: error, deviceId: recipient.id }, "APNs send failed");
        }
      }),
    );
    return result;
  }
}

/** Stores a `cameraOffline` event and pushes it (SPEC §6 Health: no heartbeat for 3 minutes). */
export async function recordCameraOffline(
  db: Database,
  notifier: EventNotifier,
  cameraId: string,
  householdId: string,
  log: FastifyBaseLogger,
): Promise<void> {
  try {
    const [camera] = await db.select({ status: devices.status }).from(devices).where(eq(devices.id, cameraId));
    if (camera?.status !== "active") return; // revoked cameras going quiet is expected
    const [event] = await db
      .insert(events)
      .values({ householdId, deviceId: cameraId, type: "cameraOffline", startedAt: new Date() })
      .returning({ id: events.id });
    await notifier.notify({ householdId, cameraId, eventId: event!.id, type: "cameraOffline" });
  } catch (error) {
    log.error({ err: error, cameraId }, "recording camera offline failed");
  }
}
