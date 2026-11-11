import { eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { events, households, mediaTombstones } from "../db/schema.js";
import { householdMediaPrefix, type MediaStorage } from "../storage/storage.js";

export class StorageUnavailableError extends Error {}

/** Storage keys of every clip and snapshot of a household's events. */
async function mediaKeys(db: Database, householdId: string): Promise<string[]> {
  const rows = await db
    .select({ clipKey: events.clipKey, snapshotKey: events.snapshotKey })
    .from(events)
    .where(eq(events.householdId, householdId));
  return rows.flatMap((r) => [r.clipKey, r.snapshotKey]).filter((k): k is string => k !== null);
}

/**
 * Deletes stored files first (so a failure leaves everything intact and the call can be repeated),
 * then the household row; devices, dogs, events, summaries, members and invites follow by cascade.
 * Pass `extra` to run more deletes in the same transaction.
 *
 * A clip uploaded while this runs (or later, with a URL presigned earlier) is not in the key list,
 * so the household's whole storage prefix is deleted after the transaction and tombstoned for the
 * retention job to delete again (security audit 2026-11, run 2).
 */
export async function deleteHousehold(
  db: Database,
  storage: MediaStorage | undefined,
  householdId: string,
  extra?: (tx: Parameters<Parameters<Database["transaction"]>[0]>[0]) => Promise<void>,
): Promise<void> {
  const keys = await mediaKeys(db, householdId);
  if (keys.length > 0) {
    if (!storage) throw new StorageUnavailableError("storage_not_configured");
    for (let i = 0; i < keys.length; i += 1000) await storage.deleteObjects(keys.slice(i, i + 1000));
  }
  const prefix = householdMediaPrefix(householdId);
  await db.transaction(async (tx) => {
    await tx.delete(households).where(eq(households.id, householdId));
    if (storage) await tx.insert(mediaTombstones).values({ prefix }).onConflictDoNothing();
    if (extra) await extra(tx);
  });
  // Best effort: the data is already gone; the tombstone makes the retention job retry.
  if (storage) await storage.deletePrefix(prefix).catch(() => 0);
}
