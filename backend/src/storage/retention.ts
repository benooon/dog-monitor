import type { FastifyBaseLogger } from "fastify";
import { and, eq, inArray, isNotNull, isNull, lt, or, sql } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { dailySummaries, events, households, mediaTombstones } from "../db/schema.js";
import type { MediaStorage } from "./storage.js";

export const DEFAULT_RETENTION_DAYS = 7;
/** Labeled clips of households that share training data are kept this long. */
export const TRAINING_RETENTION_DAYS = 90;

/**
 * Deletes clips and snapshots of events older than the retention period (SPEC §10), and clears
 * their keys. Event rows stay for the timeline and daily summaries. Returns how many objects were deleted.
 */
export async function purgeExpiredMedia(
  db: Database,
  storage: MediaStorage,
  retentionDays: number,
  now: Date = new Date(),
): Promise<number> {
  const day = 24 * 60 * 60 * 1000;
  const cutoff = new Date(now.getTime() - retentionDays * day);
  const trainingCutoff = new Date(now.getTime() - Math.max(TRAINING_RETENTION_DAYS, retentionDays) * day);
  const expired = await db
    .select({ id: events.id, clipKey: events.clipKey, snapshotKey: events.snapshotKey })
    .from(events)
    .innerJoin(households, eq(households.id, events.householdId))
    .where(
      and(
        lt(events.startedAt, cutoff),
        or(isNotNull(events.clipKey), isNotNull(events.snapshotKey)),
        // Labeled clips of opted-in households stay until the training cutoff.
        or(isNull(events.feedback), eq(households.shareTrainingData, false), lt(events.startedAt, trainingCutoff)),
      ),
    )
    .limit(5000);
  if (expired.length === 0) return 0;

  const keys = expired.flatMap((e) => [e.clipKey, e.snapshotKey]).filter((k): k is string => k !== null);
  await storage.deleteObjects(keys);
  await db
    .update(events)
    .set({ clipKey: null, snapshotKey: null })
    .where(
      inArray(
        events.id,
        expired.map((e) => e.id),
      ),
    );
  return keys.length;
}

/** Presigned upload URLs live 15 minutes; tombstones are kept well past that. */
export const TOMBSTONE_KEEP_MS = 60 * 60 * 1000;

/**
 * Deletes the storage prefix of every deleted household again (late uploads), and drops
 * tombstones once they are older than TOMBSTONE_KEEP_MS. Returns how many objects were deleted.
 */
export async function purgeMediaTombstones(db: Database, storage: MediaStorage, now: Date = new Date()): Promise<number> {
  const rows = await db.select().from(mediaTombstones).limit(1000);
  let deleted = 0;
  for (const row of rows) {
    deleted += await storage.deletePrefix(row.prefix);
    if (now.getTime() - row.createdAt.getTime() > TOMBSTONE_KEEP_MS) {
      await db.delete(mediaTombstones).where(eq(mediaTombstones.prefix, row.prefix));
    }
  }
  return deleted;
}

/** Runs the purge now and then daily. Returns a function that stops it. */
export function scheduleRetention(
  db: Database,
  storage: MediaStorage,
  retentionDays: number,
  log: FastifyBaseLogger,
): () => void {
  const run = () => {
    purgeExpiredMedia(db, storage, retentionDays)
      .then((deleted) => {
        if (deleted > 0) log.info({ deleted }, "deleted expired clips and snapshots");
      })
      .catch((error: unknown) => log.error({ err: error }, "media retention failed"));
    purgeMediaTombstones(db, storage)
      .then((deleted) => {
        if (deleted > 0) log.info({ deleted }, "deleted late uploads of deleted households");
      })
      .catch((error: unknown) => log.error({ err: error }, "tombstone purge failed"));
  };
  const first = setTimeout(run, 60_000);
  const daily = setInterval(run, 24 * 60 * 60 * 1000);
  first.unref();
  daily.unref();
  return () => {
    clearTimeout(first);
    clearInterval(daily);
  };
}

export const DEFAULT_RECORD_RETENTION_DAYS = 365;

/**
 * Deletes timeline events and daily summaries older than `days` (storage limitation, GDPR Art. 5(1)(e)).
 * Events that still point at stored files are kept until `purgeExpiredMedia` has removed the files.
 * Returns how many rows were deleted.
 */
export async function purgeExpiredRecords(db: Database, days: number, now: Date = new Date()): Promise<number> {
  const cutoff = new Date(now.getTime() - days * 24 * 60 * 60 * 1000);
  const oldEvents = await db
    .delete(events)
    .where(and(lt(events.startedAt, cutoff), isNull(events.clipKey), isNull(events.snapshotKey)))
    .returning({ id: events.id });
  const oldSummaries = await db
    .delete(dailySummaries)
    .where(lt(dailySummaries.date, sql`${cutoff.toISOString().slice(0, 10)}::date`))
    .returning({ date: dailySummaries.date });
  return oldEvents.length + oldSummaries.length;
}

/** Runs `purgeExpiredRecords` now and then daily. Returns a function that stops it. */
export function scheduleRecordRetention(db: Database, days: number, log: FastifyBaseLogger): () => void {
  const run = () => {
    purgeExpiredRecords(db, days)
      .then((deleted) => {
        if (deleted > 0) log.info({ deleted }, "deleted expired events and daily summaries");
      })
      .catch((error: unknown) => log.error({ err: error }, "record retention failed"));
  };
  const first = setTimeout(run, 120_000);
  const daily = setInterval(run, 24 * 60 * 60 * 1000);
  first.unref();
  daily.unref();
  return () => {
    clearTimeout(first);
    clearInterval(daily);
  };
}
