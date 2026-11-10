import type { FastifyReply, FastifyRequest } from "fastify";
import { eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { householdMembers } from "../db/schema.js";

export interface HouseholdScope {
  householdId: string;
  role: "owner" | "member";
}

declare module "fastify" {
  interface FastifyRequest {
    /** Set by the `requireHousehold` preHandler. */
    household?: HouseholdScope;
  }
}

/** MVP: each user belongs to at most one household (see DECISIONS.md). */
export async function findMembership(db: Database, userId: string): Promise<HouseholdScope | null> {
  const [row] = await db
    .select({ householdId: householdMembers.householdId, role: householdMembers.role })
    .from(householdMembers)
    .where(eq(householdMembers.userId, userId))
    .limit(1);
  return row ?? null;
}

/** preHandler (after `authenticate`) that scopes the request to the caller's household. */
export function requireHousehold(db: Database) {
  return async (request: FastifyRequest, reply: FastifyReply) => {
    const membership = request.user ? await findMembership(db, request.user.userId) : null;
    if (!membership) {
      return reply.code(403).send({ error: "no_household" });
    }
    request.household = membership;
    return undefined;
  };
}

export async function requireOwner(request: FastifyRequest, reply: FastifyReply) {
  if (request.household?.role !== "owner") {
    return reply.code(403).send({ error: "owner_only" });
  }
  return undefined;
}
