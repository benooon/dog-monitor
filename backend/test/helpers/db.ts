import { sql } from "drizzle-orm";
import { createDb, type DbHandle } from "../../src/db/client.js";

export const databaseUrl = process.env.DATABASE_URL;
export const hasDatabase = Boolean(databaseUrl);

export function openTestDb(): DbHandle {
  if (!databaseUrl) throw new Error("DATABASE_URL is not set");
  return createDb(databaseUrl);
}

/**
 * Empties every app table (keeps the migrations table).
 *
 * TRUNCATE needs an AccessExclusiveLock on each table. A previous test's app may still be draining
 * fire-and-forget background writes (e.g. the realtime hub's camera-offline event insert, live-activity
 * flushes) that hold a RowShareLock on a parent table, so the two can deadlock on CI's slower runner.
 * We fail fast with a short lock_timeout and retry a few times, which clears once that work drains.
 */
export async function truncateAll(handle: DbHandle): Promise<void> {
  const maxAttempts = 5;
  for (let attempt = 1; ; attempt++) {
    try {
      // A transaction pins one pooled connection, so SET LOCAL and TRUNCATE share a session and the
      // lock_timeout actually applies to the TRUNCATE; SET LOCAL also resets automatically at commit.
      await handle.db.transaction(async (tx) => {
        await tx.execute(sql`SET LOCAL lock_timeout = '2s'`);
        await tx.execute(sql`
          TRUNCATE users, households, household_members, dogs, devices, zones, events,
            daily_summaries, notification_prefs, invites, live_activities, dog_photos, waitlist, media_tombstones RESTART IDENTITY CASCADE
        `);
      });
      return;
    } catch (error) {
      // 40P01 = deadlock_detected, 55P03 = lock_not_available (lock_timeout fired).
      const code = (error as { code?: string } | undefined)?.code;
      if ((code === "40P01" || code === "55P03") && attempt < maxAttempts) {
        await new Promise((resolve) => setTimeout(resolve, 50 * attempt));
        continue;
      }
      throw error;
    }
  }
}
