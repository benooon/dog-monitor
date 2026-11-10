import { and, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { households } from "../db/schema.js";
import type { VerifiedTransaction } from "./app-store.js";

/**
 * Records a verified App Store transaction on a household: extends premium, never shortens the
 * same subscription with an older transaction (they can arrive out of order), and ends premium on
 * a refund or revocation.
 */
export async function applyTransaction(db: Database, householdId: string, transaction: VerifiedTransaction, at: Date): Promise<void> {
  if (transaction.revokedAt) {
    await db
      .update(households)
      .set({ plan: "free", planExpiresAt: null })
      .where(and(eq(households.id, householdId), eq(households.planOriginalTransactionId, transaction.originalTransactionId)));
    return;
  }

  const [current] = await db
    .select({ expiresAt: households.planExpiresAt, original: households.planOriginalTransactionId })
    .from(households)
    .where(eq(households.id, householdId));
  const sameSubscription = current?.original === transaction.originalTransactionId;
  const currentActive = Boolean(current?.expiresAt && current.expiresAt > at);
  const extendsPremium = !current?.expiresAt || transaction.expiresAt > current.expiresAt;
  if (!extendsPremium && (sameSubscription || currentActive)) return;
  await db
    .update(households)
    .set({
      plan: transaction.expiresAt > at ? "premium" : "free",
      planExpiresAt: transaction.expiresAt,
      planProductId: transaction.productId,
      planOriginalTransactionId: transaction.originalTransactionId,
      planEnvironment: transaction.environment,
    })
    .where(eq(households.id, householdId));
}
