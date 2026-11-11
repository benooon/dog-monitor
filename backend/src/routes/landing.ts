import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { LANDING_COPY } from "../landing/copy.js";
import { renderLandingPage, type LandingState } from "../landing/render.js";
import { serveBytes } from "../landing/static.js";
import type { WaitlistLocale } from "../waitlist/email.js";

/** `public/` sits next to `src/` and `dist/`, so this resolves from both. */
export const publicFolder = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../public");

const STATIC_FILES: Record<string, { file: string; type: string; maxAge: number }> = {
  "/join.css": { file: "join.css", type: "text/css; charset=utf-8", maxAge: 3600 },
  "/join.js": { file: "join.js", type: "text/javascript; charset=utf-8", maxAge: 3600 },
  "/favicon.svg": { file: "favicon.svg", type: "image/svg+xml", maxAge: 86400 },
  "/media/hero.mp4": { file: "media/hero.mp4", type: "video/mp4", maxAge: 86400 },
  "/media/hero.jpg": { file: "media/hero.jpg", type: "image/jpeg", maxAge: 86400 },
  "/media/og-en.jpg": { file: "media/og-en.jpg", type: "image/jpeg", maxAge: 86400 },
  "/media/og-he.jpg": { file: "media/og-he.jpg", type: "image/jpeg", maxAge: 86400 },
  "/media/touch-icon.png": { file: "media/touch-icon.png", type: "image/png", maxAge: 86400 },
};

/** Everything the page loads comes from us; no inline script or style. */
const CSP =
  "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; media-src 'self'; " +
  "connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'";

/**
 * The waitlist landing page ("link in bio" for the reels): `/join` (English), `/he/join` (Hebrew),
 * and `/` redirecting by Accept-Language. Files are read once at startup.
 */
export async function landingRoutes(app: FastifyInstance, opts: { folder?: string } = {}): Promise<void> {
  const folder = opts.folder ?? publicFolder;
  const template = readFileSync(path.join(folder, "join.html"), "utf8");

  for (const [route, { file, type, maxAge }] of Object.entries(STATIC_FILES)) {
    const bytes = readFileSync(path.join(folder, file));
    app.get(route, async (request, reply) => serveBytes(request, reply, bytes, type, maxAge));
  }

  const page = (locale: WaitlistLocale) => async (request: FastifyRequest<{ Querystring: Record<string, string | undefined> }>, reply: FastifyReply) => {
    const q = request.query;
    const state: LandingState = q.joined === "1" ? "joined" : q.error === "email" ? "error-email" : q.error === "busy" ? "error-busy" : "idle";
    const html = renderLandingPage(template, LANDING_COPY[locale], {
      locale,
      origin: publicOrigin(request),
      source: q.s ?? q.source,
      state,
    });
    return reply
      .header("content-type", "text/html; charset=utf-8")
      .header("content-security-policy", CSP)
      .header("x-content-type-options", "nosniff")
      .header("referrer-policy", "strict-origin-when-cross-origin")
      .header("cache-control", "no-cache")
      .header("vary", "Accept-Encoding")
      .send(html);
  };
  app.get("/join", page("en"));
  app.get("/he/join", page("he"));

  app.get("/", async (request, reply) => {
    const query = request.url.includes("?") ? request.url.slice(request.url.indexOf("?")) : "";
    const target = prefersHebrew(request.headers["accept-language"]) ? "/he/join" : "/join";
    return reply.header("vary", "Accept-Language").redirect(target + query, 302);
  });
}

/** True when Hebrew comes before English in Accept-Language (or English isn't listed). */
export function prefersHebrew(header: string | undefined): boolean {
  if (!header) return false;
  const langs = header
    .split(",")
    .map((part) => {
      const [tag = "", ...params] = part.trim().toLowerCase().split(";");
      const qParam = params.find((p) => p.trim().startsWith("q="));
      const quality = qParam ? Number(qParam.trim().slice(2)) : 1;
      return { lang: tag.split("-")[0] ?? "", quality: Number.isFinite(quality) ? quality : 0 };
    })
    .filter((l) => l.quality > 0)
    .sort((a, b) => b.quality - a.quality);
  const first = langs.find((l) => l.lang === "he" || l.lang === "iw" || l.lang === "en");
  return first !== undefined && first.lang !== "en";
}

/** "https://host" for absolute Open Graph URLs; the Host header is only used when it looks like a host name. */
function publicOrigin(request: FastifyRequest): string {
  const host = request.host;
  const safeHost = /^[A-Za-z0-9.-]+(:\d{1,5})?$/.test(host) ? host : "localhost";
  // Railway sets X-Forwarded-Proto (trustProxy), so this is https in production.
  return `${request.protocol}://${safeHost}`;
}
