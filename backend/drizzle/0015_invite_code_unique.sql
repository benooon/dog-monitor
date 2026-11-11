-- Invite codes are unique among unused invites (security audit 2026-11, run 2).
-- Expired unused invites can never be accepted: delete them. Then retire all but the newest of any
-- remaining active duplicates.
DELETE FROM "invites" WHERE "used_at" IS NULL AND "expires_at" <= now();--> statement-breakpoint
UPDATE "invites" i SET "used_at" = now()
  WHERE i."used_at" IS NULL AND EXISTS (
    SELECT 1 FROM "invites" o
    WHERE o."code" = i."code" AND o."used_at" IS NULL AND (o."created_at", o."token") > (i."created_at", i."token")
  );--> statement-breakpoint
DROP INDEX "invites_code_idx";--> statement-breakpoint
CREATE UNIQUE INDEX "invites_code_unused_unique" ON "invites" USING btree ("code") WHERE "invites"."used_at" IS NULL;
