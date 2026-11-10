-- Nothing wrote household-level summaries yet; they become per camera.
DELETE FROM "daily_summaries";--> statement-breakpoint
ALTER TABLE "daily_summaries" DROP CONSTRAINT "daily_summaries_household_id_date_pk";--> statement-breakpoint
ALTER TABLE "daily_summaries" ADD COLUMN "device_id" uuid NOT NULL;--> statement-breakpoint
ALTER TABLE "daily_summaries" ADD CONSTRAINT "daily_summaries_device_id_date_pk" PRIMARY KEY("device_id","date");--> statement-breakpoint
ALTER TABLE "daily_summaries" ADD COLUMN "state_minutes" jsonb DEFAULT '{}'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "daily_summaries" ADD COLUMN "notified_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "daily_summaries" ADD COLUMN "updated_at" timestamp with time zone DEFAULT now() NOT NULL;--> statement-breakpoint
ALTER TABLE "daily_summaries" ADD CONSTRAINT "daily_summaries_device_id_devices_id_fk" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "daily_summaries_household_date_idx" ON "daily_summaries" USING btree ("household_id","date");
