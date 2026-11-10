import type { FastifyInstance } from "fastify";
import { and, asc, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { DOG_ALERT_STYLES, DOG_LIFE_STAGES, DOG_TRAITS, dogPhotos, dogs } from "../db/schema.js";
import { dogDto } from "../households/dto.js";
import { requireHousehold } from "../households/scope.js";

const idParams = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string", format: "uuid" } },
} as const;

const dogFields = {
  name: { type: "string", minLength: 1, maxLength: 100 },
  photoKey: { type: ["string", "null"], maxLength: 500 },
  lifeStage: { type: ["string", "null"], enum: [...DOG_LIFE_STAGES, null] },
  traits: { type: "array", maxItems: DOG_TRAITS.length, uniqueItems: true, items: { type: "string", enum: [...DOG_TRAITS] } },
  alertStyle: { type: ["string", "null"], enum: [...DOG_ALERT_STYLES, null] },
} as const;

interface DogBody {
  name: string;
  photoKey?: string | null;
  lifeStage?: string | null;
  traits?: string[];
  alertStyle?: string | null;
}

/** Photos are resized on the phone (about 512 px); this leaves room without inviting big uploads. */
export const DOG_PHOTO_MAX_BYTES = 512 * 1024;

function isJpeg(body: Buffer): boolean {
  return body.length > 3 && body[0] === 0xff && body[1] === 0xd8 && body[2] === 0xff;
}

export async function dogRoutes(app: FastifyInstance, opts: { db: Database }): Promise<void> {
  const { db } = opts;
  app.addHook("preHandler", app.authenticate);
  app.addHook("preHandler", requireHousehold(db));

  const scoped = (householdId: string, id: string) => and(eq(dogs.id, id), eq(dogs.householdId, householdId));

  app.get("/dogs", async (request) => {
    const rows = await db
      .select()
      .from(dogs)
      .where(eq(dogs.householdId, request.household!.householdId))
      .orderBy(asc(dogs.createdAt));
    return rows.map(dogDto);
  });

  app.post<{ Body: DogBody }>(
    "/dogs",
    {
      schema: {
        body: { type: "object", required: ["name"], additionalProperties: false, properties: dogFields },
      },
    },
    async (request, reply) => {
      const [dog] = await db
        .insert(dogs)
        .values({
          householdId: request.household!.householdId,
          name: request.body.name,
          photoKey: request.body.photoKey ?? null,
          lifeStage: request.body.lifeStage ?? null,
          traits: request.body.traits ?? [],
          alertStyle: request.body.alertStyle ?? null,
        })
        .returning();
      return reply.code(201).send(dogDto(dog!));
    },
  );

  app.get<{ Params: { id: string } }>("/dogs/:id", { schema: { params: idParams } }, async (request, reply) => {
    const [dog] = await db.select().from(dogs).where(scoped(request.household!.householdId, request.params.id));
    return dog ? dogDto(dog) : reply.code(404).send({ error: "not_found" });
  });

  app.patch<{ Params: { id: string }; Body: Partial<DogBody> }>(
    "/dogs/:id",
    {
      schema: {
        params: idParams,
        body: { type: "object", minProperties: 1, additionalProperties: false, properties: dogFields },
      },
    },
    async (request, reply) => {
      const [dog] = await db
        .update(dogs)
        .set(request.body)
        .where(scoped(request.household!.householdId, request.params.id))
        .returning();
      return dog ? dogDto(dog) : reply.code(404).send({ error: "not_found" });
    },
  );

  // Raw JPEG bodies for the photo endpoints only.
  app.addContentTypeParser("image/jpeg", { parseAs: "buffer", bodyLimit: DOG_PHOTO_MAX_BYTES }, (_request, body, done) => {
    done(null, body);
  });

  app.put<{ Params: { id: string }; Body: Buffer }>(
    "/dogs/:id/photo",
    { schema: { params: idParams } },
    async (request, reply) => {
      if (!Buffer.isBuffer(request.body) || !isJpeg(request.body)) {
        return reply.code(415).send({ error: "jpeg_required" });
      }
      const jpeg = request.body;
      const dog = await db.transaction(async (tx) => {
        const now = new Date();
        const [updated] = await tx
          .update(dogs)
          .set({ photoUpdatedAt: now })
          .where(scoped(request.household!.householdId, request.params.id))
          .returning();
        if (!updated) return undefined;
        await tx
          .insert(dogPhotos)
          .values({ dogId: updated.id, jpeg, updatedAt: now })
          .onConflictDoUpdate({ target: dogPhotos.dogId, set: { jpeg, updatedAt: now } });
        return updated;
      });
      return dog ? dogDto(dog) : reply.code(404).send({ error: "not_found" });
    },
  );

  app.get<{ Params: { id: string } }>("/dogs/:id/photo", { schema: { params: idParams } }, async (request, reply) => {
    const [row] = await db
      .select({ jpeg: dogPhotos.jpeg, updatedAt: dogPhotos.updatedAt })
      .from(dogPhotos)
      .innerJoin(dogs, eq(dogs.id, dogPhotos.dogId))
      .where(scoped(request.household!.householdId, request.params.id));
    if (!row) return reply.code(404).send({ error: "not_found" });
    return reply
      .header("content-type", "image/jpeg")
      .header("cache-control", "private, max-age=86400")
      .header("last-modified", row.updatedAt.toUTCString())
      .send(row.jpeg);
  });

  app.delete<{ Params: { id: string } }>("/dogs/:id/photo", { schema: { params: idParams } }, async (request, reply) => {
    const [dog] = await db
      .update(dogs)
      .set({ photoUpdatedAt: null })
      .where(scoped(request.household!.householdId, request.params.id))
      .returning();
    if (!dog) return reply.code(404).send({ error: "not_found" });
    await db.delete(dogPhotos).where(eq(dogPhotos.dogId, dog.id));
    return dogDto(dog);
  });

  app.delete<{ Params: { id: string } }>("/dogs/:id", { schema: { params: idParams } }, async (request, reply) => {
    const deleted = await db
      .delete(dogs)
      .where(scoped(request.household!.householdId, request.params.id))
      .returning({ id: dogs.id });
    return deleted.length > 0 ? reply.code(204).send() : reply.code(404).send({ error: "not_found" });
  });
}
