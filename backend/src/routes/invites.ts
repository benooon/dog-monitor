import type { FastifyInstance } from "fastify";
import { and, count, eq, gt, isNull, lte } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { HOUSEHOLD_MEMBER_USER_UNIQUE, INVITE_CODE_UNIQUE, isUniqueViolation } from "../db/errors.js";
import { devices, householdMembers, households, invites, users } from "../db/schema.js";
import { deviceDto } from "../households/dto.js";
import { LIMITS } from "../households/limits.js";
import { householdCameraLimit } from "../billing/camera-limit.js";
import { findMembership, requireHousehold, requireOwner } from "../households/scope.js";
import { AttemptLimiter } from "../pairing/attempt-limiter.js";
import { INVITE_TTL_MS, hashSecret, newDeviceSecret, newInviteCode, newInviteToken } from "../pairing/secrets.js";

type AcceptBody =
  | { as: "member" }
  | { as: "camera"; deviceName: string; model?: string | null; appVersion?: string | null };

const ALL_CODES = "all-codes";

class AcceptError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly extra: Record<string, unknown> = {},
  ) {
    super(code);
  }
}

export async function inviteRoutes(
  app: FastifyInstance,
  opts: { db: Database; limiter?: AttemptLimiter; codeLimiter?: AttemptLimiter; now?: () => Date; enforcePlanLimits?: boolean },
): Promise<void> {
  const { db } = opts;
  const limiter = opts.limiter ?? new AttemptLimiter(10, 10 * 60 * 1000);
  /**
   * All wrong 6-digit codes together, whatever address they come from: guessing one of 10^6 codes
   * takes far more than this, while families typing a code now and then never reach it.
   */
  const codeLimiter = opts.codeLimiter ?? new AttemptLimiter(200, 10 * 60 * 1000);
  const now = opts.now ?? (() => new Date());

  app.post(
    "/invites",
    { preHandler: [app.authenticate, requireHousehold(db), requireOwner] },
    async (request, reply) => {
      const { householdId } = request.household!;
      const createdAt = now();
      const expiresAt = new Date(createdAt.getTime() + INVITE_TTL_MS);
      // Pick a code no other unused invite holds. The unique index decides under concurrency;
      // an expired invite holding the code is deleted (it can never be accepted).
      for (let attempt = 0; attempt < 10; attempt++) {
        const code = newInviteCode();
        await db.delete(invites).where(and(eq(invites.code, code), isNull(invites.usedAt), lte(invites.expiresAt, createdAt)));
        const token = newInviteToken();
        try {
          await db.insert(invites).values({ token, code, householdId, createdBy: request.user!.userId, expiresAt });
        } catch (error) {
          if (isUniqueViolation(error, INVITE_CODE_UNIQUE)) continue;
          throw error;
        }
        return reply.code(201).send({ token, code, expiresAt });
      }
      throw new Error("could not allocate a unique invite code");
    },
  );

  /**
   * What the joiner sees before accepting: the household's name and the inviter's first name,
   * nothing else. Guessing costs the same attempts as accepting, so it reveals nothing accept wouldn't.
   */
  app.get<{ Params: { token: string } }>(
    "/invites/:token/preview",
    {
      schema: {
        params: {
          type: "object",
          required: ["token"],
          properties: { token: { type: "string", minLength: 6, maxLength: 64 } },
        },
      },
    },
    async (request, reply) => {
      const limiterKey = request.ip;
      const param = request.params.token;
      const byCode = /^\d{6}$/.test(param);
      if (!limiter.tryAcquire(limiterKey)) {
        return reply.code(429).send({ error: "too_many_attempts" });
      }
      if (byCode && !codeLimiter.tryAcquire(ALL_CODES)) {
        limiter.release(limiterKey);
        return reply.code(429).send({ error: "too_many_attempts" });
      }
      const [row] = await db
        .select({ householdName: households.name, inviterName: users.name })
        .from(invites)
        .innerJoin(households, eq(households.id, invites.householdId))
        .leftJoin(users, eq(users.id, invites.createdBy))
        .where(
          and(
            byCode ? eq(invites.code, param) : eq(invites.token, param),
            isNull(invites.usedAt),
            gt(invites.expiresAt, now()),
          ),
        )
        .limit(1);
      if (!row) return reply.code(404).send({ error: "invalid_or_expired_invite" });
      limiter.release(limiterKey);
      if (byCode) codeLimiter.release(ALL_CODES);
      return reply.header("cache-control", "no-store").send({
        household: { name: row.householdName },
        inviter: { firstName: firstName(row.inviterName) },
      });
    },
  );

  app.post<{ Params: { token: string }; Body: AcceptBody }>(
    "/invites/:token/accept",
    {
      schema: {
        params: {
          type: "object",
          required: ["token"],
          properties: { token: { type: "string", minLength: 6, maxLength: 64 } },
        },
        // One schema with if/then rather than oneOf: Fastify's default `removeAdditional`
        // would strip camera fields while trying the member branch.
        body: {
          type: "object",
          required: ["as"],
          additionalProperties: false,
          properties: {
            as: { type: "string", enum: ["member", "camera"] },
            deviceName: { type: "string", minLength: 1, maxLength: 100 },
            model: { type: ["string", "null"], maxLength: 100 },
            appVersion: { type: ["string", "null"], maxLength: 50 },
          },
          if: { properties: { as: { const: "camera" } } },
          then: { required: ["deviceName"] },
          else: { maxProperties: 1 },
        },
      },
    },
    async (request, reply) => {
      const limiterKey = request.ip;
      const param = request.params.token;
      const byCode = /^\d{6}$/.test(param);
      // Attempts are counted before the code is looked up and handed back unless it was wrong.
      if (!limiter.tryAcquire(limiterKey)) {
        return reply.code(429).send({ error: "too_many_attempts" });
      }
      if (byCode && !codeLimiter.tryAcquire(ALL_CODES)) {
        limiter.release(limiterKey);
        return reply.code(429).send({ error: "too_many_attempts" });
      }
      const notAFailure = () => {
        limiter.release(limiterKey);
        if (byCode) codeLimiter.release(ALL_CODES);
      };

      // Members must be signed in; cameras need no user (SPEC §3).
      let userId: string | undefined;
      if (request.body.as === "member") {
        const authReply = await app.authenticate(request, reply);
        if (authReply) {
          notAFailure();
          return authReply;
        }
        userId = request.user!.userId;
        if (await findMembership(db, userId)) {
          notAFailure();
          return reply.code(409).send({ error: "already_in_household" });
        }
      }

      const body = request.body;

      try {
        const result = await db.transaction(async (tx) => {
          const at = now();
          // Atomically consume the invite so it can only be used once.
          const [invite] = await tx
            .update(invites)
            .set({ usedAt: at })
            .where(
              and(
                byCode ? eq(invites.code, param) : eq(invites.token, param),
                isNull(invites.usedAt),
                gt(invites.expiresAt, at),
              ),
            )
            .returning();
          if (!invite) throw new AcceptError(404, "invalid_or_expired_invite");
          const householdId = invite.householdId;
          // Serialise accepts per household so concurrent ones cannot all pass the limit counts below.
          await tx.select({ id: households.id }).from(households).where(eq(households.id, householdId)).for("update");

          if (body.as === "member") {
            const [row] = await tx
              .select({ n: count() })
              .from(householdMembers)
              .where(eq(householdMembers.householdId, householdId));
            if ((row?.n ?? 0) >= LIMITS.usersPerHousehold) {
              throw new AcceptError(409, "member_limit_reached", { limit: LIMITS.usersPerHousehold });
            }
            await tx.insert(householdMembers).values({ householdId, userId: userId!, role: "member" });
            return { status: 200, payload: { householdId, role: "member" } };
          }

          const [row] = await tx
            .select({ n: count() })
            .from(devices)
            .where(and(eq(devices.householdId, householdId), eq(devices.role, "camera"), eq(devices.status, "active")));
          const limit = await householdCameraLimit(tx, householdId, at, opts.enforcePlanLimits ?? false);
          if ((row?.n ?? 0) >= limit) {
            throw new AcceptError(409, "camera_limit_reached", { limit });
          }
          const deviceSecret = newDeviceSecret();
          const [device] = await tx
            .insert(devices)
            .values({
              householdId,
              name: body.deviceName,
              role: "camera",
              model: body.model ?? null,
              appVersion: body.appVersion ?? null,
              deviceSecretHash: hashSecret(deviceSecret),
            })
            .returning();
          // The secret is returned exactly once; the camera stores it in its keychain.
          return { status: 201, payload: { householdId, device: deviceDto(device!), deviceSecret } };
        });
        notAFailure();
        return reply.code(result.status).send(result.payload);
      } catch (err) {
        if (isUniqueViolation(err, HOUSEHOLD_MEMBER_USER_UNIQUE)) {
          // The user joined or created another household concurrently; the invite stays unused (rolled back).
          notAFailure();
          return reply.code(409).send({ error: "already_in_household" });
        }
        if (err instanceof AcceptError) {
          if (err.status !== 404) notAFailure();
          return reply.code(err.status).send({ error: err.code, ...err.extra });
        }
        throw err;
      }
    },
  );
}

/** "Dana Levi" → "Dana"; no name (Apple only shares it once, or the inviter left) → null. */
export function firstName(name: string | null | undefined): string | null {
  const first = name?.trim().split(/\s+/)[0];
  return first ? first.slice(0, 50) : null;
}
