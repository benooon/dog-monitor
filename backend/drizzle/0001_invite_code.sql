ALTER TABLE "invites" ADD COLUMN "code" text NOT NULL;--> statement-breakpoint
CREATE INDEX "invites_code_idx" ON "invites" USING btree ("code");