import pg from "pg";
import { runMigrations } from "../src/db/migrate.js";

/** Resets the test database schema and applies migrations once per run (only when DATABASE_URL is set). */
export default async function setup(): Promise<void> {
  const url = process.env.DATABASE_URL;
  if (!url) {
    console.warn("DATABASE_URL not set: database tests will be skipped");
    return;
  }
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  try {
    await client.query("DROP SCHEMA IF EXISTS public CASCADE; DROP SCHEMA IF EXISTS drizzle CASCADE; CREATE SCHEMA public;");
  } finally {
    await client.end();
  }
  await runMigrations(url);
}
