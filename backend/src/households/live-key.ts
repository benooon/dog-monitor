import { and, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { households } from "../db/schema.js";

/** A live key id as the phones make it: random, unpadded base64url (it is never the key). */
export const LIVE_KEY_ID_PATTERN = "^[A-Za-z0-9_-]{8,64}$";
const LIVE_KEY_ID_RE = new RegExp(LIVE_KEY_ID_PATTERN);

export function isLiveKeyId(value: unknown): value is string {
  return typeof value === "string" && LIVE_KEY_ID_RE.test(value);
}

/**
 * Someone who held the live key left (member removed, device revoked). Only matters when live
 * video is encrypted; the owner's phone then makes a new key on its next household load.
 */
export async function requestLiveKeyRotation(db: Pick<Database, "update">, householdId: string): Promise<void> {
  await db
    .update(households)
    .set({ liveKeyRotationNeeded: true })
    .where(and(eq(households.id, householdId), eq(households.liveEncrypted, true)));
}

/**
 * Whether a camera can't publish live video the household's viewers can decrypt: it said it has
 * no key, or the key it holds isn't the household's current one. Keys made before ids existed
 * (household id null) are never treated as stale.
 */
export function cameraNeedsLiveKey(
  camera: { liveKeyMissing: boolean; liveKeyId: string | null },
  household: { liveEncrypted: boolean; liveKeyId: string | null },
): boolean {
  if (camera.liveKeyMissing) return true;
  if (!household.liveEncrypted || household.liveKeyId === null) return false;
  return camera.liveKeyId !== household.liveKeyId;
}
