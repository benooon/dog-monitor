import { eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { households } from "../db/schema.js";
import { cameraLimit } from "./plans.js";

type Queryable = Pick<Database, "select">;

/** Cameras this household may have, from its plan (see `cameraLimit`). */
export async function householdCameraLimit(db: Queryable, householdId: string, now: Date, enforce: boolean): Promise<number> {
  const [row] = await db.select({ planExpiresAt: households.planExpiresAt }).from(households).where(eq(households.id, householdId));
  return cameraLimit({ planExpiresAt: row?.planExpiresAt ?? null }, now, enforce);
}
