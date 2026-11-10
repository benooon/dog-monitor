import { sql } from "drizzle-orm";
import { createDb, type DbHandle } from "../../src/db/client.js";

export const databaseUrl = process.env.DATABASE_URL;
export const hasDatabase = Boolean(databaseUrl);

export function openTestDb(): DbHandle {
  if (!databaseUrl) throw new Error("DATABASE_URL is not set");
  return createDb(databaseUrl);
}

/** Empties every app table (keeps the migrations table). */
export async function truncateAll(handle: DbHandle): Promise<void> {
  await handle.db.execute(sql`
    TRUNCATE users, households, household_members, dogs, devices, zones, events,
      daily_summaries, notification_prefs, invites, live_activities, dog_photos RESTART IDENTITY CASCADE
  `);
}
