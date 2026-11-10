import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import fp from "fastify-plugin";
import { eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices } from "../db/schema.js";
import { secretMatches } from "../pairing/secrets.js";

export interface DeviceClaims {
  deviceId: string;
  householdId: string;
}

declare module "fastify" {
  interface FastifyRequest {
    /** Set by `app.authenticateDevice` for camera devices. */
    device?: DeviceClaims;
  }
  interface FastifyInstance {
    /** preHandler that requires `Authorization: Device <deviceId>:<secret>`. */
    authenticateDevice: (request: FastifyRequest, reply: FastifyReply) => Promise<FastifyReply | undefined>;
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function parseDeviceAuthorization(header: string | undefined): { deviceId: string; secret: string } | null {
  if (!header?.startsWith("Device ")) return null;
  const value = header.slice("Device ".length).trim();
  const sep = value.indexOf(":");
  if (sep <= 0) return null;
  const deviceId = value.slice(0, sep);
  const secret = value.slice(sep + 1);
  if (!UUID_RE.test(deviceId) || secret.length === 0) return null;
  return { deviceId, secret };
}

export const deviceAuthPlugin = fp(
  async (app: FastifyInstance, opts: { db: Database }) => {
    app.decorateRequest("device", undefined);
    app.decorate("authenticateDevice", async (request: FastifyRequest, reply: FastifyReply) => {
      const parsed = parseDeviceAuthorization(request.headers.authorization);
      if (parsed) {
        const [device] = await opts.db
          .select({ id: devices.id, householdId: devices.householdId, status: devices.status, hash: devices.deviceSecretHash })
          .from(devices)
          .where(eq(devices.id, parsed.deviceId));
        if (device && device.status === "active" && device.hash && secretMatches(parsed.secret, device.hash)) {
          request.device = { deviceId: device.id, householdId: device.householdId };
          return undefined;
        }
      }
      return reply.code(401).send({ error: "unauthorized" });
    });
  },
  { name: "device-auth" },
);
