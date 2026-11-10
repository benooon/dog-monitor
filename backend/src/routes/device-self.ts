import type { FastifyInstance } from "fastify";
import { eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { devices } from "../db/schema.js";
import { deviceDto } from "../households/dto.js";

/** Routes called by camera devices with device auth. */
export async function deviceSelfRoutes(app: FastifyInstance, opts: { db: Database }): Promise<void> {
  app.addHook("preHandler", app.authenticateDevice);

  app.get("/device/me", async (request) => {
    const [device] = await opts.db.select().from(devices).where(eq(devices.id, request.device!.deviceId));
    return deviceDto(device!);
  });
}
