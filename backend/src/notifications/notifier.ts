import type { FastifyBaseLogger } from "fastify";
import { and, asc, eq, inArray, isNotNull, isNull, lte, or } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices, dogs, events, notificationPrefs, type EventType } from "../db/schema.js";
import { isDeadToken, type ApnsSender } from "./apns.js";
import { buildEventPayload, enabledByDefault } from "./payload.js";

export interface EventNotification {
  householdId: string;
  cameraId: string;
  eventId: string;
  type: EventType;
  snapshotKey?: string | null;
  escalationSeconds?: number;
}

export interface NotifyResult {
  sent: number;
  failed: number;
  /** Viewers who turned this event type off. */
  muted: number;
}

/**
 * Fans an event out as APNs pushes to the household's viewer devices, honoring each user's
 * `notification_prefs` (a per-camera row beats an all-cameras row, which beats the type default).
 * Quiet hours are not applied yet (no user time zone stored; see BACKLOG).
 */
export class EventNotifier {
  constructor(
    private readonly db: Database,
    private readonly apns: ApnsSender | undefined,
    private readonly log: FastifyBaseLogger,
  ) {}

  async notify(event: EventNotification): Promise<NotifyResult> {
    const result: NotifyResult = { sent: 0, failed: 0, muted: 0 };
    if (!this.apns) {
      this.log.warn({ eventId: event.eventId }, "APNS_* not set: event stored without push");
      return result;
    }

    const [camera] = await this.db.select({ name: devices.name }).from(devices).where(eq(devices.id, event.cameraId));
    const recipients = await this.db
      .select({ id: devices.id, userId: devices.userId, apnsToken: devices.apnsToken })
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
      .select({ userId: notificationPrefs.userId, deviceId: notificationPrefs.deviceId, enabled: notificationPrefs.enabled })
      .from(notificationPrefs)
      .where(and(inArray(notificationPrefs.userId, userIds), eq(notificationPrefs.eventType, event.type)));
    const wants = (userId: string) => {
      const forCamera = prefs.find((p) => p.userId === userId && p.deviceId === event.cameraId);
      const forAll = prefs.find((p) => p.userId === userId && p.deviceId === null);
      return (forCamera ?? forAll)?.enabled ?? enabledByDefault(event.type);
    };

    const [dog] = await this.db
      .select({ name: dogs.name })
      .from(dogs)
      .where(eq(dogs.householdId, event.householdId))
      .orderBy(asc(dogs.createdAt))
      .limit(1);
    const payload = buildEventPayload({
      eventId: event.eventId,
      type: event.type,
      cameraId: event.cameraId,
      cameraName: camera?.name ?? "Dog Monitor",
      dogName: dog?.name,
      snapshotKey: event.snapshotKey,
      escalationSeconds: event.escalationSeconds,
    });

    const apns = this.apns;
    await Promise.all(
      recipients.map(async (recipient) => {
        if (!wants(recipient.userId!)) {
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
