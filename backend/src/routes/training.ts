import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { and, asc, eq, gt, isNotNull, type SQL } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { events, households } from "../db/schema.js";
import { requireHousehold, requireOwner } from "../households/scope.js";
import type { JwtService } from "../auth/jwt.js";
import type { MediaStorage } from "../storage/storage.js";
import { DOWNLOAD_URL_TTL_SECONDS } from "./media.js";

/**
 * `GET /training/labeled?after=<ISO time>`: the owner's export of clips members marked right or
 * wrong, with short-lived download URLs (for `scripts/export-training-data`). Only for households
 * that opted in; oldest first, 200 per page.
 */
export const EXPORT_TOKEN_TTL_SECONDS = 60 * 60;

export async function trainingRoutes(
  app: FastifyInstance,
  opts: { db: Database; storage?: MediaStorage; jwt: JwtService },
): Promise<void> {
  const { db } = opts;
  // The export key only reads GET /training/labeled; every other route (including minting a new key)
  // needs a real session.
  const sessionOrExportKey = async (request: FastifyRequest, reply: FastifyReply) => {
    const header = request.headers.authorization;
    const token = header?.startsWith("Bearer ") ? header.slice("Bearer ".length).trim() : undefined;
    const claims = token ? ((await opts.jwt.verify(token)) ?? (await opts.jwt.verify(token, "trainingExport"))) : null;
    if (!claims) return reply.code(401).send({ error: "unauthorized" });
    request.user = claims;
    return undefined;
  };
  const scoped = [requireHousehold(db), requireOwner];

  async function optedIn(householdId: string): Promise<boolean> {
    const [household] = await db.select({ optedIn: households.shareTrainingData }).from(households).where(eq(households.id, householdId));
    return household?.optedIn ?? false;
  }

  /** A one-hour token for the export script, so the app's long-lived session never leaves the phone. */
  app.post("/training/export-token", { preHandler: [app.authenticate, ...scoped] }, async (request, reply) => {
    if (!(await optedIn(request.household!.householdId))) return reply.code(403).send({ error: "training_not_enabled" });
    const token = await opts.jwt.issue({ userId: request.user!.userId }, EXPORT_TOKEN_TTL_SECONDS, "trainingExport");
    return { token, expiresAt: new Date(Date.now() + EXPORT_TOKEN_TTL_SECONDS * 1000).toISOString() };
  });

  app.get<{ Querystring: { after?: string } }>(
    "/training/labeled",
    {
      preHandler: [sessionOrExportKey, ...scoped],
      schema: {
        querystring: {
          type: "object",
          additionalProperties: false,
          properties: { after: { type: "string", format: "date-time" } },
        },
      },
    },
    async (request, reply) => {
      const { householdId } = request.household!;
      if (!(await optedIn(householdId))) return reply.code(403).send({ error: "training_not_enabled" });
      if (!opts.storage) return reply.code(503).send({ error: "storage_not_configured" });

      const filters: SQL[] = [eq(events.householdId, householdId), isNotNull(events.feedback), isNotNull(events.clipKey)];
      if (request.query.after) filters.push(gt(events.startedAt, new Date(request.query.after)));
      const rows = await db.select().from(events).where(and(...filters)).orderBy(asc(events.startedAt)).limit(200);
      const storage = opts.storage;
      const items = await Promise.all(
        rows.map(async (row) => ({
          eventId: row.id,
          cameraId: row.deviceId,
          type: row.type,
          state: row.state,
          startedAt: row.startedAt.toISOString(),
          feedback: row.feedback,
          clipUrl: await storage.presignDownload(row.clipKey!, DOWNLOAD_URL_TTL_SECONDS),
          snapshotUrl: row.snapshotKey ? await storage.presignDownload(row.snapshotKey, DOWNLOAD_URL_TTL_SECONDS) : null,
        })),
      );
      return { items, next: rows.length === 200 ? rows[rows.length - 1]!.startedAt.toISOString() : null };
    },
  );
}
