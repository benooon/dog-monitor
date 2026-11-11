ALTER TABLE "devices" ADD COLUMN "live_key_id" text;--> statement-breakpoint
ALTER TABLE "households" ADD COLUMN "live_key_id" text;--> statement-breakpoint
ALTER TABLE "households" ADD COLUMN "live_key_rotation_needed" boolean DEFAULT false NOT NULL;