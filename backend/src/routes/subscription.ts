import type { FastifyInstance } from "fastify";
import { and, count, eq, gt, ne } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices, households } from "../db/schema.js";
import { requireHousehold, requireOwner } from "../households/scope.js";
import { TransactionError, type TransactionVerifier } from "../billing/app-store.js";
import { cameraLimit, effectivePlan } from "../billing/plans.js";
import { applyTransaction } from "../billing/apply-transaction.js";

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

      await applyTransaction(db, householdId, transaction, at);
      return describe(householdId);
    },
  );
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * App Store Server Notifications V2 (`POST /app-store/notifications`, set as the server URL in
 * App Store Connect): renewals, expirations, refunds and revocations reach us even when nobody
 * opens the app. Signed by Apple, so no auth; anything we can't verify gets 400 and Apple retries.
 */
export async function appStoreNotificationRoutes(
  app: FastifyInstance,
  opts: { db: Database; verifier?: TransactionVerifier; now: () => Date },
): Promise<void> {
  const { db, verifier, now } = opts;

  app.post<{ Body: { signedPayload: string } }>(
    "/app-store/notifications",
    {
      schema: {
        body: {
          type: "object",
          required: ["signedPayload"],
          properties: { signedPayload: { type: "string", minLength: 20, maxLength: 100000 } },
        },
      },
    },
    async (request, reply) => {
      if (!verifier) return reply.code(503).send({ error: "purchases_not_configured" });
      const at = now();
      let notification: Record<string, unknown>;
      try {
        notification = await verifier.verifyPayload(request.body.signedPayload, at);
      } catch (err) {
        if (err instanceof TransactionError) return reply.code(400).send({ error: err.code });
        throw err;
      }
      const data = (notification.data ?? {}) as Record<string, unknown>;
      const signedTransaction = typeof data.signedTransactionInfo === "string" ? data.signedTransactionInfo : null;
      // TEST notifications and summaries carry no transaction: acknowledge them.
      if (!signedTransaction) return { ok: true };

      let transaction;
      try {
        transaction = await verifier.verify(signedTransaction, at);
      } catch (err) {
        if (!(err instanceof TransactionError)) throw err;
        // Another app or product on the same account is not ours to handle; Apple must not retry it.
        if (err.code === "wrong_bundle" || err.code === "unknown_product") return { ok: true };
        return reply.code(400).send({ error: err.code });
      }

      const [byOriginal] = await db
        .select({ id: households.id })
        .from(households)
        .where(eq(households.planOriginalTransactionId, transaction.originalTransactionId))
        .limit(1);
      let householdId = byOriginal?.id;
      if (!householdId && transaction.appAccountToken && UUID.test(transaction.appAccountToken)) {
        const [byToken] = await db
          .select({ id: households.id })
          .from(households)
          .where(eq(households.id, transaction.appAccountToken))
          .limit(1);
        householdId = byToken?.id;
      }
      // Unknown subscription: the owner's app reports it on its next launch.
      if (!householdId) return { ok: true };

      await applyTransaction(db, householdId, transaction, at);
      request.log.info(
        { householdId, type: notification.notificationType, subtype: notification.subtype },
        "app store notification applied",
      );
      return { ok: true };
    },
  );
}
