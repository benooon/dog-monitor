CREATE TABLE "media_tombstones" (
	"prefix" text PRIMARY KEY NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
