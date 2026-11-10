CREATE TABLE "dog_photos" (
	"dog_id" uuid PRIMARY KEY NOT NULL,
	"jpeg" "bytea" NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "dogs" ADD COLUMN "life_stage" text;--> statement-breakpoint
ALTER TABLE "dogs" ADD COLUMN "traits" text[] DEFAULT '{}'::text[] NOT NULL;--> statement-breakpoint
ALTER TABLE "dogs" ADD COLUMN "alert_style" text;--> statement-breakpoint
ALTER TABLE "dogs" ADD COLUMN "photo_updated_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "dog_photos" ADD CONSTRAINT "dog_photos_dog_id_dogs_id_fk" FOREIGN KEY ("dog_id") REFERENCES "public"."dogs"("id") ON DELETE cascade ON UPDATE no action;