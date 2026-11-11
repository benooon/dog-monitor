/** Unique index on household_members.user_id: one household per user. */
export const HOUSEHOLD_MEMBER_USER_UNIQUE = "household_members_user_unique";

/** True when a Postgres unique violation (23505) caused this error, directly or wrapped by Drizzle. */
export function isUniqueViolation(error: unknown, constraint?: string): boolean {
  for (let e: unknown = error, depth = 0; e && typeof e === "object" && depth < 4; e = (e as { cause?: unknown }).cause, depth++) {
    const pg = e as { code?: unknown; constraint?: unknown };
    if (pg.code === "23505") return constraint === undefined || pg.constraint === constraint;
  }
  return false;
}
