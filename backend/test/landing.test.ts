import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import type { DbHandle } from "../src/db/client.js";
import { waitlist } from "../src/db/schema.js";
import { LANDING_COPY } from "../src/landing/copy.js";
import { escapeHtml } from "../src/landing/render.js";
import { parseRange } from "../src/landing/static.js";
import { prefersHebrew } from "../src/routes/landing.js";
import { AttemptLimiter } from "../src/pairing/attempt-limiter.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

describe("landing helpers", () => {
  it("parses byte ranges", () => {
    expect(parseRange(undefined, 100)).toBeUndefined();
    expect(parseRange("bytes=0-1", 100)).toEqual({ start: 0, end: 1 });
    expect(parseRange("bytes=10-", 100)).toEqual({ start: 10, end: 99 });
    expect(parseRange("bytes=-10", 100)).toEqual({ start: 90, end: 99 });
    expect(parseRange("bytes=50-500", 100)).toEqual({ start: 50, end: 99 });
    expect(parseRange("bytes=100-", 100)).toBe("unsatisfiable");
    expect(parseRange("bytes=5-2", 100)).toBe("unsatisfiable");
    expect(parseRange("bytes=0-1,5-6", 100)).toBeUndefined();
    expect(parseRange("items=0-1", 100)).toBeUndefined();
  });

  it("picks Hebrew from Accept-Language", () => {
    expect(prefersHebrew("he-IL,he;q=0.9,en-US;q=0.8")).toBe(true);
    expect(prefersHebrew("en-US,en;q=0.9,he;q=0.8")).toBe(false);
    expect(prefersHebrew("en;q=0.5,he;q=0.9")).toBe(true);
    expect(prefersHebrew("fr-FR,he;q=0.5")).toBe(true);
    expect(prefersHebrew("fr-FR")).toBe(false);
    expect(prefersHebrew(undefined)).toBe(false);
  });

  it("escapes HTML", () => {
    expect(escapeHtml(`<a href="x">'&'</a>`)).toBe("&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
  });

  it("keeps the copy in voice", () => {
    for (const copy of Object.values(LANDING_COPY)) {
      for (const text of Object.values(copy)) {
        expect(text).not.toContain("!");
        expect(text.toLowerCase()).not.toMatch(/\b(stream|token|ai|encrypted|surveillance)\b/);
      }
    }
  });
});

describe("landing page", () => {
  let app: FastifyInstance;
  beforeAll(async () => {
    app = await buildApp({ logLevel: "silent" });
  });
  afterAll(async () => {
    await app.close();
  });

  it("serves the English page", async () => {
    const res = await app.inject({ method: "GET", url: "/join", headers: { host: "dogs.example.com", "x-forwarded-proto": "https" } });
    expect(res.statusCode).toBe(200);
    expect(res.headers["content-type"]).toMatch(/text\/html/);
    expect(res.headers["content-security-policy"]).toContain("script-src 'self'");
    expect(res.body).toContain('<html lang="en" dir="ltr">');
    expect(res.body).toContain("What does Rex do when you&#39;re out?");
    expect(res.body).toContain('content="https://dogs.example.com/media/og-en.jpg"');
    expect(res.body).toContain('action="/waitlist"');
    expect(res.body).not.toMatch(/\{\{\w+\}\}/);
  });

  it("serves the Hebrew page right to left", async () => {
    const res = await app.inject({ method: "GET", url: "/he/join" });
    expect(res.statusCode).toBe(200);
    expect(res.body).toContain('<html lang="he" dir="rtl">');
    expect(res.body).toContain(LANDING_COPY.he.h1);
    expect(res.body).toContain('name="locale" value="he"');
    expect(res.body).toContain('href="/join"');
  });

  it("carries the source and only a safe one", async () => {
    const ok = await app.inject({ method: "GET", url: "/join?s=IG-Reel2" });
    expect(ok.body).toContain('name="source" value="ig-reel2"');
    expect(ok.body).toContain('href="/he/join?s=ig-reel2"');
    const bad = await app.inject({ method: "GET", url: `/join?s=${encodeURIComponent('"><script>x</script>')}` });
    expect(bad.body).toContain('name="source" value=""');
    expect(bad.body).not.toContain("<script>x");
  });

  it("ignores a host header that isn't a host name", async () => {
    const res = await app.inject({ method: "GET", url: "/join", headers: { host: 'evil"><b>' } });
    expect(res.statusCode).toBe(200);
    expect(res.body).not.toContain("<b>");
  });

  it("shows the result of a form post without JavaScript", async () => {
    const joined = await app.inject({ method: "GET", url: "/join?joined=1" });
    expect(joined.body).toContain('data-state="joined"');
    const error = await app.inject({ method: "GET", url: "/he/join?error=email" });
    expect(error.body).toContain('data-state="error"');
    expect(error.body).toContain(LANDING_COPY.he.errEmail);
  });

  it("redirects / by language and keeps the query", async () => {
    const he = await app.inject({ method: "GET", url: "/?s=ig", headers: { "accept-language": "he-IL,he;q=0.9" } });
    expect(he.statusCode).toBe(302);
    expect(he.headers.location).toBe("/he/join?s=ig");
    const en = await app.inject({ method: "GET", url: "/" });
    expect(en.headers.location).toBe("/join");
  });

  it("serves the assets", async () => {
    for (const [url, type] of [
      ["/join.css", "text/css"],
      ["/join.js", "text/javascript"],
      ["/favicon.svg", "image/svg+xml"],
      ["/media/hero.jpg", "image/jpeg"],
      ["/media/og-he.jpg", "image/jpeg"],
      ["/media/touch-icon.png", "image/png"],
    ] as const) {
      const res = await app.inject({ method: "GET", url });
      expect(res.statusCode, url).toBe(200);
      expect(res.headers["content-type"], url).toContain(type);
    }
  });

  it("serves the hero video in ranges (Safari) and honors ETags", async () => {
    const full = await app.inject({ method: "GET", url: "/media/hero.mp4" });
    expect(full.statusCode).toBe(200);
    expect(full.headers["accept-ranges"]).toBe("bytes");
    const size = full.rawPayload.length;

    const part = await app.inject({ method: "GET", url: "/media/hero.mp4", headers: { range: "bytes=0-1" } });
    expect(part.statusCode).toBe(206);
    expect(part.headers["content-range"]).toBe(`bytes 0-1/${size}`);
    expect(part.rawPayload.length).toBe(2);

    const tooFar = await app.inject({ method: "GET", url: "/media/hero.mp4", headers: { range: `bytes=${size}-` } });
    expect(tooFar.statusCode).toBe(416);

    const cached = await app.inject({ method: "GET", url: "/media/hero.mp4", headers: { "if-none-match": String(full.headers.etag) } });
    expect(cached.statusCode).toBe(304);
  });
});

describe.skipIf(!hasDatabase)("landing form without JavaScript", () => {
  let h: DbHandle;
  let app: FastifyInstance;
  beforeAll(async () => {
    h = openTestDb();
    app = (await buildTestApp(h, { waitlistLimiter: new AttemptLimiter(3, 60_000) })).app;
  });
  afterAll(async () => {
    await app.close();
    await h.close();
  });
  beforeEach(async () => {
    await truncateAll(h);
  });

  const post = (body: string) =>
    app.inject({
      method: "POST",
      url: "/waitlist",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      payload: body,
      remoteAddress: "192.0.2.50",
    });

  it("stores the email and redirects back to the page", async () => {
    const res = await post("locale=he&source=ig&email=Dana%40example.com");
    expect(res.statusCode).toBe(303);
    expect(res.headers.location).toBe("/he/join?joined=1&s=ig");
    const rows = await h.db.select().from(waitlist);
    expect(rows[0]).toMatchObject({ email: "dana@example.com", locale: "he", source: "ig" });
  });

  it("redirects with an error for a bad email, then when rate-limited", async () => {
    expect((await post("locale=en&source=&email=nope")).headers.location).toBe("/join?error=email");
    expect((await post("locale=xx&email=a%40b.io")).headers.location).toBe("/join?error=email");
    await post("locale=en&email=a%40b.io");
    expect((await post("locale=en&email=c%40d.io")).headers.location).toBe("/join?error=busy");
  });
});
