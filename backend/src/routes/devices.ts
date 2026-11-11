import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { and, asc, count, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices } from "../db/schema.js";
import { deviceDto } from "../households/dto.js";
import { householdCameraLimit } from "../billing/camera-limit.js";
import { requireHousehold, requireOwner } from "../households/scope.js";
import { isValidTimeZone } from "../notifications/quiet-hours.js";
import { RealtimeSessions } from "../realtime/sessions.js";

const idParams = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string", format: "uuid" } },
} as const;

const optionalFields = {
  timeZone: { type: ["string", "null"], minLength: 1, maxLength: 64 },
  model: { type: ["string", "null"], maxLength: 100 },
  appVersion: { type: ["string", "null"], maxLength: 50 },
  apnsToken: { type: ["string", "null"], pattern: "^[0-9a-fA-F]{32,200}$" },
} as const;

interface RegisterBody {
  name: string;
  role: "camera" | "viewer";
  model?: string | null;
  appVersion?: string | null;
  apnsToken?: string | null;
  timeZone?: string | null;
}

type UpdateBody = Partial<Pick<RegisterBody, "name" | "model" | "appVersion" | "apnsToken" | "timeZone">> & {
  /** ISO time until which this phone gets no pushes, or null to unmute. */
  mutedUntil?: string | null;
};

export async function deviceRoutes(
  app: FastifyInstance,
  opts: { db: Database; enforcePlanLimits?: boolean; sessions?: RealtimeSessions },
): Promise<void> {
  const { db } = opts;
  app.addHook("preHandler", app.authenticate);
  app.addHook("preHandler", requireHousehold(db));

  async function loadDevice(request: FastifyRequest<{ Params: { id: string } }>, reply: FastifyReply) {
    const [device] = await db
      .select()
      .from(devices)
      .where(and(eq(devices.id, request.params.id), eq(devices.householdId, request.household!.householdId)));
    if (!device) {
      await reply.code(404).send({ error: "not_found" });
      return null;
    }
    return device;
  }

  app.get("/devices", async (request) => {
    const rows = await db
      .select()
      .from(devices)
      .where(eq(devices.householdId, request.household!.householdId))
      .orderBy(asc(devices.createdAt));
    return rows.map(deviceDto);
  });

  app.post<{ Body: RegisterBody }>(
    "/devices",
    {
      schema: {
        body: {
          type: "object",
          required: ["name", "role"],
          additionalProperties: false,
          properties: {
            name: { type: "string", minLength: 1, maxLength: 100 },
            role: { type: "string", enum: ["camera", "viewer"] },
            ...optionalFields,
          },
        },
      },
    },
    async (request, reply) => {
      const { householdId } = request.household!;
      if (request.body.timeZone && !isValidTimeZone(request.body.timeZone)) {
        return reply.code(400).send({ error: "invalid_time_zone" });
      }
      if (request.body.role === "camera") {
        const [row] = await db
          .select({ n: count() })
          .from(devices)
          .where(and(eq(devices.householdId, householdId), eq(devices.role, "camera"), eq(devices.status, "active")));
        const limit = await householdCameraLimit(db, householdId, new Date(), opts.enforcePlanLimits ?? false);
        if ((row?.n ?? 0) >= limit) {
          return reply.code(409).send({ error: "camera_limit_reached", limit });
        }
      }
      const [device] = await db
        .insert(devices)
        .values({
          householdId,
          userId: request.user!.userId,
          name: request.body.name,
          role: request.body.role,
          model: request.body.model ?? null,
          appVersion: request.body.appVersion ?? null,
          apnsToken: request.body.apnsToken ?? null,
          timeZone: request.body.timeZone ?? null,
        })
        .returning();
      return reply.code(201).send(deviceDto(device!));
    },
  );

  app.patch<{ Params: { id: string }; Body: UpdateBody }>(
    "/devices/:id",
    {
      schema: {
        params: idParams,
        body: {
          type: "object",
          minProperties: 1,
          additionalProperties: false,
          properties: {
            name: { type: "string", minLength: 1, maxLength: 100 },
            ...optionalFields,
            mutedUntil: { type: ["string", "null"], format: "date-time" },
          },
        },
      },
    },
    async (request, reply) => {
      if (request.body.timeZone && !isValidTimeZone(request.body.timeZone)) {
        return reply.code(400).send({ error: "invalid_time_zone" });
      }
      const device = await loadDevice(request, reply);
      if (!device) return reply;
      const isOwnDevice = device.userId === request.user!.userId;
      if (!isOwnDevice && request.household!.role !== "owner") {
        return reply.code(403).send({ error: "forbidden" });
      }
      if (device.status === "revoked") {
        return reply.code(409).send({ error: "device_revoked" });
      }
      const { mutedUntil, ...rest } = request.body;
      const changes = {
        ...rest,
        ...(mutedUntil !== undefined && { mutedUntil: mutedUntil === null ? null : new Date(mutedUntil) }),
      };
      const [updated] = await db.update(devices).set(changes).where(eq(devices.id, device.id)).returning();
      return deviceDto(updated!);
    },
  );

  app.post<{ Params: { id: string } }>(
    "/devices/:id/revoke",
    { schema: { params: idParams }, preHandler: requireOwner },
    async (request, reply) => {
      const device = await loadDevice(request, reply);
      if (!device) return reply;
      const [updated] = await db
        .update(devices)
        .set({ status: "revoked", apnsToken: null, deviceSecretHash: null })
        .where(eq(devices.id, device.id))
        .returning();
      opts.sessions?.closeAll(RealtimeSessions.device(device.id), "device_revoked");
      return deviceDto(updated!);
    },
  );
}
