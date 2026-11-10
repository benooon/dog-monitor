import { sql } from "drizzle-orm";
import {
  boolean,
  date,
  index,
  integer,
  jsonb,
  pgEnum,
  pgTable,
  primaryKey,
  real,
  text,
  time,
  timestamp,
  unique,
  uuid,
} from "drizzle-orm/pg-core";

// Data model from SPEC §9. Event types and dog states mirror DogMonitorCore's
// `EventType` / `DogState` raw values; they are stored as text so new values
// do not need an enum migration.

export const EVENT_TYPES = [
  "prolongedBarking",
  "whining",
  "forbiddenZone",
  "atDoor",
  "notVisible",
  "calmedDown",
  "cameraOffline",
  "lowBattery",
  "overheating",
  "dailySummary",
] as const;
export type EventType = (typeof EVENT_TYPES)[number];

export const DOG_STATES = [
  "resting",
  "barking",
  "whining",
  "restless",
  "atDoor",
  "forbiddenZone",
  "notVisible",
  "unknown",
] as const;
export type DogState = (typeof DOG_STATES)[number];

export const memberRole = pgEnum("member_role", ["owner", "member"]);
export const deviceRole = pgEnum("device_role", ["camera", "viewer"]);
export const deviceStatus = pgEnum("device_status", ["active", "revoked"]);
export const zoneKind = pgEnum("zone_kind", ["door", "forbidden", "bed"]);
export const eventFeedback = pgEnum("event_feedback", ["correct", "wrong"]);

const createdAt = () => timestamp("created_at", { withTimezone: true }).notNull().defaultNow();

export const users = pgTable("users", {
  id: uuid("id").primaryKey().defaultRandom(),
  appleSub: text("apple_sub").notNull().unique(),
  name: text("name"),
  createdAt: createdAt(),
});

export const households = pgTable("households", {
  id: uuid("id").primaryKey().defaultRandom(),
  name: text("name").notNull(),
  ownerId: uuid("owner_id")
    .notNull()
    .references(() => users.id),
  plan: text("plan").notNull().default("free"),
  /** Premium is paid up until this time (App Store auto-renewable subscription); null: never subscribed. */
  planExpiresAt: timestamp("plan_expires_at", { withTimezone: true }),
  planProductId: text("plan_product_id"),
  /** Identifies the App Store subscription across renewals, so one purchase unlocks one household. */
  planOriginalTransactionId: text("plan_original_transaction_id"),
  planEnvironment: text("plan_environment"),
  /** Owner opted in to keep clips that members marked right/wrong, for training (SPEC §4 Calibration). */
  shareTrainingData: boolean("share_training_data").notNull().default(false),
  createdAt: createdAt(),
});

export const householdMembers = pgTable(
  "household_members",
  {
    householdId: uuid("household_id")
      .notNull()
      .references(() => households.id, { onDelete: "cascade" }),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    role: memberRole("role").notNull().default("member"),
    createdAt: createdAt(),
  },
  (t) => [primaryKey({ columns: [t.householdId, t.userId] }), index("household_members_user_idx").on(t.userId)],
);

export const dogs = pgTable("dogs", {
  id: uuid("id").primaryKey().defaultRandom(),
  householdId: uuid("household_id")
    .notNull()
    .references(() => households.id, { onDelete: "cascade" }),
  name: text("name").notNull(),
  photoKey: text("photo_key"),
  createdAt: createdAt(),
});

export type PolygonPoint = { x: number; y: number };

export const devices = pgTable(
  "devices",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    householdId: uuid("household_id")
      .notNull()
      .references(() => households.id, { onDelete: "cascade" }),
    /** The signed-in user owning a viewer device; null for camera devices. */
    userId: uuid("user_id").references(() => users.id, { onDelete: "set null" }),
    name: text("name").notNull(),
    role: deviceRole("role").notNull(),
    model: text("model"),
    appVersion: text("app_version"),
    apnsToken: text("apns_token"),
    deviceSecretHash: text("device_secret_hash"),
    status: deviceStatus("status").notNull().default("active"),
    lastHeartbeatAt: timestamp("last_heartbeat_at", { withTimezone: true }),
    battery: real("battery"),
    charging: boolean("charging"),
    thermal: text("thermal"),
    /** Camera devices: the dog's state from the latest heartbeat. */
    dogState: text("dog_state").$type<DogState>(),
    /** Viewer devices: IANA time zone of the phone, for quiet hours. */
    timeZone: text("time_zone"),
    /** Viewer devices: no pushes until this time ("Mute 1h" notification action). */
    mutedUntil: timestamp("muted_until", { withTimezone: true }),
    createdAt: createdAt(),
  },
  (t) => [index("devices_household_idx").on(t.householdId)],
);

export const zones = pgTable(
  "zones",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    deviceId: uuid("device_id")
      .notNull()
      .references(() => devices.id, { onDelete: "cascade" }),
    kind: zoneKind("kind").notNull(),
    /** Polygon in normalized (0...1) image coordinates. */
    polygon: jsonb("polygon").$type<PolygonPoint[]>().notNull(),
    createdAt: createdAt(),
  },
  (t) => [index("zones_device_idx").on(t.deviceId)],
);

export const events = pgTable(
  "events",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    householdId: uuid("household_id")
      .notNull()
      .references(() => households.id, { onDelete: "cascade" }),
    deviceId: uuid("device_id").references(() => devices.id, { onDelete: "set null" }),
    type: text("type").$type<EventType>().notNull(),
    state: text("state").$type<DogState>(),
    startedAt: timestamp("started_at", { withTimezone: true }).notNull(),
    endedAt: timestamp("ended_at", { withTimezone: true }),
    confidence: real("confidence"),
    clipKey: text("clip_key"),
    snapshotKey: text("snapshot_key"),
    feedback: eventFeedback("feedback"),
    createdAt: createdAt(),
  },
  (t) => [index("events_household_started_idx").on(t.householdId, t.startedAt.desc())],
);

/** One camera's day, computed on the camera (in its local time) and uploaded as it goes. */
export const dailySummaries = pgTable(
  "daily_summaries",
  {
    householdId: uuid("household_id")
      .notNull()
      .references(() => households.id, { onDelete: "cascade" }),
    deviceId: uuid("device_id")
      .notNull()
      .references(() => devices.id, { onDelete: "cascade" }),
    date: date("date").notNull(),
    restMinutes: integer("rest_minutes").notNull().default(0),
    barkCount: integer("bark_count").notNull().default(0),
    /** 24 numbers, one per local hour: minutes with motion. */
    activityByHour: jsonb("activity_by_hour").$type<number[]>().notNull().default(sql`'[]'::jsonb`),
    /** Minutes spent in each dog state. */
    stateMinutes: jsonb("state_minutes").$type<Partial<Record<DogState, number>>>().notNull().default(sql`'{}'::jsonb`),
    /** Set when the "daily summary is ready" push went out (once per camera and day). */
    notifiedAt: timestamp("notified_at", { withTimezone: true }),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.deviceId, t.date] }), index("daily_summaries_household_date_idx").on(t.householdId, t.date)],
);

export const notificationPrefs = pgTable(
  "notification_prefs",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    /** Camera device the preference applies to; null means all cameras. */
    deviceId: uuid("device_id").references(() => devices.id, { onDelete: "cascade" }),
    eventType: text("event_type").$type<EventType>().notNull(),
    enabled: boolean("enabled").notNull(),
    quietStart: time("quiet_start"),
    quietEnd: time("quiet_end"),
  },
  (t) => [unique("notification_prefs_unique").on(t.userId, t.deviceId, t.eventType).nullsNotDistinct()],
);

export const invites = pgTable(
  "invites",
  {
    token: text("token").primaryKey(),
    /** 6-digit code for typing instead of scanning; only unique among active invites. */
    code: text("code").notNull(),
    householdId: uuid("household_id")
      .notNull()
      .references(() => households.id, { onDelete: "cascade" }),
    createdBy: uuid("created_by").references(() => users.id, { onDelete: "set null" }),
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    usedAt: timestamp("used_at", { withTimezone: true }),
    createdAt: createdAt(),
  },
  (t) => [index("invites_code_idx").on(t.code)],
);

/**
 * A Live Activity on a viewer's phone showing one camera (ActivityKit). Updated by APNs
 * `liveactivity` pushes to `pushToken`; iOS ends activities after at most 12 hours.
 */
export const liveActivities = pgTable(
  "live_activities",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    householdId: uuid("household_id")
      .notNull()
      .references(() => households.id, { onDelete: "cascade" }),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    cameraId: uuid("camera_id")
      .notNull()
      .references(() => devices.id, { onDelete: "cascade" }),
    pushToken: text("push_token").notNull().unique(),
    createdAt: createdAt(),
  },
  (t) => [index("live_activities_camera_idx").on(t.cameraId)],
);
