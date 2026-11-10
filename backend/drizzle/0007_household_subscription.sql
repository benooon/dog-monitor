ALTER TABLE "households" ADD COLUMN "plan_expires_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "households" ADD COLUMN "plan_product_id" text;--> statement-breakpoint
ALTER TABLE "households" ADD COLUMN "plan_original_transaction_id" text;--> statement-breakpoint
ALTER TABLE "households" ADD COLUMN "plan_environment" text;