CREATE TABLE "live_activities" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"household_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"camera_id" uuid NOT NULL,
	"push_token" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "live_activities_push_token_unique" UNIQUE("push_token")
);
--> statement-breakpoint
ALTER TABLE "live_activities" ADD CONSTRAINT "live_activities_household_id_households_id_fk" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "live_activities" ADD CONSTRAINT "live_activities_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "live_activities" ADD CONSTRAINT "live_activities_camera_id_devices_id_fk" FOREIGN KEY ("camera_id") REFERENCES "public"."devices"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "live_activities_camera_idx" ON "live_activities" USING btree ("camera_id");