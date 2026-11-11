import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import type { DbHandle } from "../src/db/client.js";
import { waitlist } from "../src/db/schema.js";
import { AttemptLimiter } from "../src/pairing/attempt-limiter.js";
import { normalizeEmail } from "../src/waitlist/email.js";
import { tokenMatches } from "../src/waitlist/tokens.js";
import { loadConfig } from "../src/config.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

const ADMIN = "admin-token-admin-token-admin-token-42";

describe("waitlist helpers", () => {
  it("normalizes emails", () => {
    expect(normalizeEmail("  Dana@Example.COM ")).toBe("dana@example.com");
    expect(normalizeEmail("a.b+rex@mail.co.il")).toBe("a.b+rex@mail.co.il");
    for (const bad of ["", "dana", "dana@", "@example.com", "dana@example", "da na@example.com", "dana@ex..com", `${"a".repeat(250)}@x.io`]) {
      expect(normalizeEmail(bad), bad).toBeNull();
    }
  });

  it("compares tokens of any length", () => {
    expect(tokenMatches("abc", "abc")).toBe(true);
    expect(tokenMatches("abc", "abcd")).toBe(false);
  });

  it("reads ADMIN_TOKEN only when long enough", () => {
    expect(loadConfig({ ADMIN_TOKEN: ADMIN }).adminToken).toBe(ADMIN);
    const short = loadConfig({ ADMIN_TOKEN: "short" });
    expect(short.adminToken).toBeUndefined();
    expect(short.warnings.join()).toMatch(/ADMIN_TOKEN/);
    expect(loadConfig({}).adminToken).toBeUndefined();
  });
});

describe.skipIf(!hasDatabase)("waitlist routes", () => {
  let h: DbHandle;
  let app: FastifyInstance;
  let limiter: AttemptLimiter;

  beforeAll(async () => {
    h = openTestDb();
    limiter = new AttemptLimiter(1000, 60_000);
    app = (await buildTestApp(h, { adminToken: ADMIN, waitlistLimiter: limiter })).app;
  });
  afterAll(async () => {
    await app.close();
    await h.close();
  });
  beforeEach(async () => {
    await truncateAll(h);
  });

  const join = (payload: Record<string, unknown>, ip = "203.0.113.1") =>
    app.inject({ method: "POST", url: "/waitlist", payload, remoteAddress: ip });

  it("stores a lowercased email and answers 202", async () => {
    const res = await join({ email: " Dana@Example.com ", locale: "he", source: "IG-Reel" });
    expect(res.statusCode).toBe(202);
    const rows = await h.db.select().from(waitlist);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ email: "dana@example.com", locale: "he", source: "ig-reel" });
    expect(rows[0]!.unsubscribeToken.length).toBeGreaterThanOrEqual(32);
  });

  it("answers the same for an address that is already on the list", async () => {
    const first = await join({ email: "dana@example.com", locale: "he" });
    const again = await join({ email: "DANA@example.com", locale: "en" });
    expect(again.statusCode).toBe(first.statusCode);
    expect(again.body).toBe(first.body);
    const rows = await h.db.select().from(waitlist);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.locale).toBe("he");
  });

  it("rejects bad input", async () => {
    expect((await join({ email: "nope", locale: "en" })).statusCode).toBe(400);
    expect((await join({ email: "a@b.io", locale: "fr" })).statusCode).toBe(400);
    expect((await join({ email: "a@b.io" })).statusCode).toBe(400);
    expect((await join({ email: "a@b.io", locale: "en", source: "<script>" })).statusCode).toBe(400);
    expect(await h.db.select().from(waitlist)).toHaveLength(0);
    // Unknown fields are dropped, not stored.
    expect((await join({ email: "a@b.io", locale: "en", admin: true })).statusCode).toBe(202);
  });

  it("rate-limits per IP", async () => {
    const strict = (await buildTestApp(h, { waitlistLimiter: new AttemptLimiter(2, 60_000) })).app;
    try {
      const send = (email: string, ip: string) =>
        strict.inject({ method: "POST", url: "/waitlist", payload: { email, locale: "en" }, remoteAddress: ip });
      expect((await send("a@b.io", "198.51.100.7")).statusCode).toBe(202);
      expect((await send("c@d.io", "198.51.100.7")).statusCode).toBe(202);
      expect((await send("e@f.io", "198.51.100.7")).statusCode).toBe(429);
      expect((await send("e@f.io", "198.51.100.8")).statusCode).toBe(202);
    } finally {
      await strict.close();
    }
  });

  it("unsubscribes with the token and shows the page in the signup's language", async () => {
    await join({ email: "dana@example.com", locale: "he" });
    const [row] = await h.db.select().from(waitlist);
    const res = await app.inject({ method: "GET", url: `/waitlist/unsubscribe?token=${row!.unsubscribeToken}` });
    expect(res.statusCode).toBe(200);
    expect(res.headers["content-type"]).toMatch(/text\/html/);
    expect(res.body).toContain('dir="rtl"');
    expect(await h.db.select().from(waitlist)).toHaveLength(0);
  });

  it("supports one-click POST unsubscribe", async () => {
    await join({ email: "dana@example.com", locale: "en" });
    const [row] = await h.db.select().from(waitlist);
    const res = await app.inject({ method: "POST", url: `/waitlist/unsubscribe?token=${row!.unsubscribeToken}` });
    expect(res.statusCode).toBe(200);
    expect(await h.db.select().from(waitlist)).toHaveLength(0);
  });

  it("shows the same page for an unknown token and keeps everyone else", async () => {
    await join({ email: "dana@example.com", locale: "en" });
    for (const url of ["/waitlist/unsubscribe?token=nope", "/waitlist/unsubscribe"]) {
      const res = await app.inject({ method: "GET", url });
      expect(res.statusCode).toBe(200);
      expect(res.body).toContain("off the list");
    }
    expect(await h.db.select().from(waitlist)).toHaveLength(1);
  });

  it("counts sign-ups for the admin only", async () => {
    await join({ email: "a@b.io", locale: "he", source: "ig" });
    await join({ email: "c@d.io", locale: "he", source: "ig" });
    await join({ email: "e@f.io", locale: "en" });

    expect((await app.inject({ method: "GET", url: "/waitlist/stats" })).statusCode).toBe(401);
    const wrong = await app.inject({ method: "GET", url: "/waitlist/stats", headers: { authorization: "Bearer wrong" } });
    expect(wrong.statusCode).toBe(401);

    const res = await app.inject({ method: "GET", url: "/waitlist/stats", headers: { authorization: `Bearer ${ADMIN}` } });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ total: 3, last7Days: 3, byLocale: { he: 2, en: 1 }, bySource: { ig: 2, direct: 1 } });
    expect(res.body).not.toContain("@");
  });

  it("hides stats when ADMIN_TOKEN is not set", async () => {
    const plain = (await buildTestApp(h)).app;
    try {
      const res = await plain.inject({ method: "GET", url: "/waitlist/stats", headers: { authorization: "Bearer anything" } });
      expect(res.statusCode).toBe(404);
    } finally {
      await plain.close();
    }
  });
});
