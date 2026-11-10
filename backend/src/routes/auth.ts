import type { FastifyInstance } from "fastify";
import { eq, sql } from "drizzle-orm";
import { InvalidAppleTokenError, type AppleTokenVerifier } from "../auth/apple.js";
import type { JwtService } from "../auth/jwt.js";
import type { Database } from "../db/client.js";
import { householdMembers, households, users } from "../db/schema.js";

export interface AuthRoutesOptions {
  db: Database;
  jwt: JwtService;
  apple: AppleTokenVerifier;
}

interface AppleSignInBody {
  identityToken: string;
  /** Apple only sends the name to the client on the first sign-in. */
  name?: string;
}

export async function authRoutes(app: FastifyInstance, opts: AuthRoutesOptions): Promise<void> {
  const { db, jwt, apple } = opts;

  app.post<{ Body: AppleSignInBody }>(
    "/auth/apple",
    {
      schema: {
        body: {
          type: "object",
          required: ["identityToken"],
          additionalProperties: false,
          properties: {
            identityToken: { type: "string", minLength: 1, maxLength: 8192 },
            name: { type: "string", minLength: 1, maxLength: 200 },
          },
        },
      },
    },
    async (request, reply) => {
      let identity;
      try {
        identity = await apple.verify(request.body.identityToken);
      } catch (err) {
        if (err instanceof InvalidAppleTokenError) {
          request.log.info({ reason: err.message }, "rejected Apple identity token");
          return reply.code(401).send({ error: "invalid_identity_token" });
        }
        throw err;
      }

      const name = request.body.name ?? null;
      const [user] = await db
        .insert(users)
        .values({ appleSub: identity.sub, name })
        .onConflictDoUpdate({
          target: users.appleSub,
          // Keep an existing name unless a new one is provided.
          set: { name: sql`coalesce(excluded.name, ${users.name})` },
        })
        .returning();

      const token = await jwt.issue({ userId: user!.id });
      return { token, user: { id: user!.id, name: user!.name } };
    },
  );

  app.get("/me", { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.user!.userId;
    const [user] = await db.select().from(users).where(eq(users.id, userId));
    if (!user) return reply.code(401).send({ error: "unauthorized" });
    const memberships = await db
      .select({ id: households.id, name: households.name, role: householdMembers.role })
      .from(householdMembers)
      .innerJoin(households, eq(households.id, householdMembers.householdId))
      .where(eq(householdMembers.userId, userId));
    return { user: { id: user.id, name: user.name }, households: memberships };
  });
}
