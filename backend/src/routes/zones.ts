import type { FastifyInstance } from "fastify";
import { asc, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { zones, type PolygonPoint } from "../db/schema.js";

type ZoneKind = "door" | "forbidden" | "bed" | "sofa";

interface ZoneInput {
  kind: ZoneKind;
  polygon: PolygonPoint[];
}

const point = {
  type: "object",
  required: ["x", "y"],
  additionalProperties: false,
  properties: { x: { type: "number", minimum: 0, maximum: 1 }, y: { type: "number", minimum: 0, maximum: 1 } },
} as const;

function zoneDto(row: typeof zones.$inferSelect) {
  return { id: row.id, kind: row.kind, polygon: row.polygon };
}

/** The camera's zones (door, forbidden, bed, sofa), drawn in camera setup (SPEC §4 Calibration). */
export async function cameraZoneRoutes(app: FastifyInstance, opts: { db: Database }): Promise<void> {
  const { db } = opts;
  app.addHook("preHandler", app.authenticateDevice);

  async function load(deviceId: string) {
    const rows = await db.select().from(zones).where(eq(zones.deviceId, deviceId)).orderBy(asc(zones.createdAt));
    return { zones: rows.map(zoneDto) };
  }

  app.get("/device/zones", async (request) => load(request.device!.deviceId));

  /** Replaces all of this camera's zones. */
  app.put<{ Body: { zones: ZoneInput[] } }>(
    "/device/zones",
    {
      schema: {
        body: {
          type: "object",
          required: ["zones"],
          additionalProperties: false,
          properties: {
            zones: {
              type: "array",
              maxItems: 20,
              items: {
                type: "object",
                required: ["kind", "polygon"],
                additionalProperties: false,
                properties: {
                  kind: { type: "string", enum: ["door", "forbidden", "bed", "sofa"] },
                  polygon: { type: "array", minItems: 3, maxItems: 32, items: point },
                },
              },
            },
          },
        },
      },
    },
    async (request) => {
      const deviceId = request.device!.deviceId;
      // now() is the same for every row in a transaction; stagger createdAt to keep the given order.
      const base = Date.now();
      await db.transaction(async (tx) => {
        await tx.delete(zones).where(eq(zones.deviceId, deviceId));
        if (request.body.zones.length > 0) {
          await tx.insert(zones).values(
            request.body.zones.map((z, i) => ({
              deviceId,
              kind: z.kind,
              polygon: z.polygon.map(({ x, y }) => ({ x, y })),
              createdAt: new Date(base + i),
            })),
          );
        }
      });
      return load(deviceId);
    },
  );
}
