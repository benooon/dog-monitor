import type { FastifyInstance } from "fastify";
import { and, asc, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { dogs } from "../db/schema.js";
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
} as const;

interface DogBody {
  name: string;
  photoKey?: string | null;
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
        .values({ householdId: request.household!.householdId, name: request.body.name, photoKey: request.body.photoKey ?? null })
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

  app.delete<{ Params: { id: string } }>("/dogs/:id", { schema: { params: idParams } }, async (request, reply) => {
    const deleted = await db
      .delete(dogs)
      .where(scoped(request.household!.householdId, request.params.id))
      .returning({ id: dogs.id });
    return deleted.length > 0 ? reply.code(204).send() : reply.code(404).send({ error: "not_found" });
  });
}
