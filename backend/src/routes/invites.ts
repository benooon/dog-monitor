import type { FastifyInstance } from "fastify";
import { and, count, eq, gt, isNull } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices, householdMembers, invites } from "../db/schema.js";
import { deviceDto } from "../households/dto.js";
import { LIMITS } from "../households/limits.js";
import { householdCameraLimit } from "../billing/camera-limit.js";
import { findMembership, requireHousehold, requireOwner } from "../households/scope.js";
import { AttemptLimiter } from "../pairing/attempt-limiter.js";
import { INVITE_TTL_MS, hashSecret, newDeviceSecret, newInviteCode, newInviteToken } from "../pairing/secrets.js";

type AcceptBody =
  | { as: "member" }
  | { as: "camera"; deviceName: string; model?: string | null; appVersion?: string | null };

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
  opts: { db: Database; limiter?: AttemptLimiter; now?: () => Date; enforcePlanLimits?: boolean },
): Promise<void> {
  const { db } = opts;
  const limiter = opts.limiter ?? new AttemptLimiter(10, 10 * 60 * 1000);
  const now = opts.now ?? (() => new Date());

  app.post(
    "/invites",
    { preHandler: [app.authenticate, requireHousehold(db), requireOwner] },
    async (request, reply) => {
      const { householdId } = request.household!;
      const createdAt = now();
      const expiresAt = new Date(createdAt.getTime() + INVITE_TTL_MS);
      // Pick a code that no other active invite uses.
      for (let attempt = 0; attempt < 10; attempt++) {
        const code = newInviteCode();
        const [clash] = await db
          .select({ token: invites.token })
          .from(invites)
          .where(and(eq(invites.code, code), isNull(invites.usedAt), gt(invites.expiresAt, createdAt)))
          .limit(1);
        if (clash) continue;
        const token = newInviteToken();
        await db.insert(invites).values({ token, code, householdId, createdBy: request.user!.userId, expiresAt });
        return reply.code(201).send({ token, code, expiresAt });
      }
      throw new Error("could not allocate a unique invite code");
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
      if (limiter.isBlocked(limiterKey)) {
        return reply.code(429).send({ error: "too_many_attempts" });
      }

      // Members must be signed in; cameras need no user (SPEC §3).
      let userId: string | undefined;
      if (request.body.as === "member") {
        const authReply = await app.authenticate(request, reply);
        if (authReply) return authReply;
        userId = request.user!.userId;
        if (await findMembership(db, userId)) {
          return reply.code(409).send({ error: "already_in_household" });
        }
      }

      const param = request.params.token;
      const byCode = /^\d{6}$/.test(param);
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
        return reply.code(result.status).send(result.payload);
      } catch (err) {
        if (err instanceof AcceptError) {
          if (err.status === 404) limiter.recordFailure(limiterKey);
          return reply.code(err.status).send({ error: err.code, ...err.extra });
        }
        throw err;
      }
    },
  );
}
