-- A user belongs to at most one household (security audit 2026-11, run 2).
-- Drop extra member rows left by the old create/accept race, keeping an owner row or the oldest one.
DELETE FROM "household_members" m USING "household_members" o
  WHERE m."user_id" = o."user_id" AND m."household_id" <> o."household_id" AND m."role" = 'member'
    AND (o."role" = 'owner' OR o."created_at" < m."created_at" OR (o."created_at" = m."created_at" AND o."household_id" < m."household_id"));--> statement-breakpoint
DROP INDEX "household_members_user_idx";--> statement-breakpoint
CREATE UNIQUE INDEX "household_members_user_unique" ON "household_members" USING btree ("user_id");
