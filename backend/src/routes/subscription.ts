import type { FastifyInstance } from "fastify";
import { and, count, eq, gt, ne } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices, households } from "../db/schema.js";
import { requireHousehold, requireOwner } from "../households/scope.js";
import { TransactionError, type TransactionVerifier } from "../billing/app-store.js";
import { cameraLimit, effectivePlan } from "../billing/plans.js";

export interface SubscriptionRouteOptions {
  db: Database;
  /** Undefined only in tests that don't exercise purchases. */
  verifier?: TransactionVerifier;
  enforcePlanLimits: boolean;
  now: () => Date;
}

/**
 * `GET /subscription`: the household's plan, limits and usage.
 * `POST /subscription/apple`: the owner's app sends a StoreKit 2 signed transaction after a purchase,
 * a renewal or on launch (`Transaction.currentEntitlements`); we verify it and extend premium.
 */
export async function subscriptionRoutes(app: FastifyInstance, opts: SubscriptionRouteOptions): Promise<void> {
  const { db, verifier, enforcePlanLimits, now } = opts;
  app.addHook("preHandler", app.authenticate);
  app.addHook("preHandler", requireHousehold(db));

  async function describe(householdId: string) {
    const [household] = await db.select().from(households).where(eq(households.id, householdId));
    const [cameras] = await db
      .select({ n: count() })
      .from(devices)
      .where(and(eq(devices.householdId, householdId), eq(devices.role, "camera"), eq(devices.status, "active")));
    const at = now();
    const plan = effectivePlan(household!, at);
    return {
      plan,
      expiresAt: plan === "premium" ? household!.planExpiresAt!.toISOString() : null,
      productId: plan === "premium" ? household!.planProductId : null,
      limits: { cameras: cameraLimit(household!, at, enforcePlanLimits) },
      usage: { cameras: cameras?.n ?? 0 },
    };
  }

  app.get("/subscription", async (request) => describe(request.household!.householdId));

  app.post<{ Body: { signedTransaction: string } }>(
    "/subscription/apple",
    {
      preHandler: requireOwner,
      schema: {
        body: {
          type: "object",
          required: ["signedTransaction"],
          additionalProperties: false,
          properties: { signedTransaction: { type: "string", minLength: 20, maxLength: 20000 } },
        },
      },
    },
    async (request, reply) => {
      if (!verifier) return reply.code(503).send({ error: "purchases_not_configured" });
      const { householdId } = request.household!;
      const at = now();
      let transaction;
      try {
        transaction = await verifier.verify(request.body.signedTransaction, at);
      } catch (err) {
        if (err instanceof TransactionError) return reply.code(400).send({ error: err.code });
        throw err;
      }
      if (transaction.appAccountToken && transaction.appAccountToken !== householdId.toLowerCase()) {
        return reply.code(409).send({ error: "subscription_in_use" });
      }
      // One App Store subscription unlocks one household.
      const [elsewhere] = await db
        .select({ id: households.id })
        .from(households)
        .where(
          and(
            eq(households.planOriginalTransactionId, transaction.originalTransactionId),
            ne(households.id, householdId),
            gt(households.planExpiresAt, at),
          ),
        )
        .limit(1);
      if (elsewhere) return reply.code(409).send({ error: "subscription_in_use" });

      if (transaction.revokedAt) {
        // Refunded or revoked: end premium if it came from this subscription.
        await db
          .update(households)
          .set({ plan: "free", planExpiresAt: null })
          .where(and(eq(households.id, householdId), eq(households.planOriginalTransactionId, transaction.originalTransactionId)));
        return describe(householdId);
      }

      const [current] = await db
        .select({ expiresAt: households.planExpiresAt, original: households.planOriginalTransactionId })
        .from(households)
        .where(eq(households.id, householdId));
      // An older transaction (sent out of order) never shortens the same subscription.
      const sameSubscription = current?.original === transaction.originalTransactionId;
      const currentActive = Boolean(current?.expiresAt && current.expiresAt > at);
      const extendsPremium = !current?.expiresAt || transaction.expiresAt > current.expiresAt;
      if (extendsPremium || (!sameSubscription && !currentActive)) {
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
      return describe(householdId);
    },
  );
}
