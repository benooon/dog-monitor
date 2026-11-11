import { eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { events, households } from "../db/schema.js";
import type { MediaStorage } from "../storage/storage.js";

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
  await db.transaction(async (tx) => {
    await tx.delete(households).where(eq(households.id, householdId));
    if (extra) await extra(tx);
  });
}
