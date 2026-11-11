import { parse as parseQuery } from "node:querystring";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { count, eq, gte, sql } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { waitlist } from "../db/schema.js";
import { AttemptLimiter } from "../pairing/attempt-limiter.js";
import { newWaitlistToken, tokenMatches } from "../waitlist/tokens.js";
import { normalizeEmail, WAITLIST_LOCALES, type WaitlistLocale } from "../waitlist/email.js";

/** Sign-ups allowed per IP per window (every attempt counts, valid or not). */
export const WAITLIST_MAX_PER_IP = 5;
export const WAITLIST_WINDOW_MS = 10 * 60 * 1000;

interface JoinBody {
  email: string;
  locale: WaitlistLocale;
  source?: string;
}

export async function waitlistRoutes(
  app: FastifyInstance,
  opts: { db: Database; adminToken?: string; limiter?: AttemptLimiter; now?: () => Date },
): Promise<void> {
  const { db } = opts;
  const limiter = opts.limiter ?? new AttemptLimiter(WAITLIST_MAX_PER_IP, WAITLIST_WINDOW_MS);
  const now = opts.now ?? (() => new Date());

  // The landing page form works without JavaScript too: a plain form post gets a redirect back.
  app.addContentTypeParser("application/x-www-form-urlencoded", { parseAs: "string", bodyLimit: 2048 }, (_req, body, done) => {
    done(null, parseQuery(body as string));
  });
  const isFormPost = (request: FastifyRequest) =>
    (request.headers["content-type"] ?? "").startsWith("application/x-www-form-urlencoded");
  const backToPage = (request: FastifyRequest<{ Body: JoinBody }>, reply: FastifyReply, result: "joined" | "email" | "busy") => {
    const body = (request.body ?? {}) as Partial<JoinBody>;
    const params = new URLSearchParams(result === "joined" ? { joined: "1" } : { error: result });
    if (typeof body.source === "string" && /^[A-Za-z0-9._-]{1,64}$/.test(body.source)) params.set("s", body.source);
    return reply.redirect(`${landingPath(body.locale)}?${params}`, 303);
  };

  app.post<{ Body: JoinBody }>(
    "/waitlist",
    {
      bodyLimit: 2048,
      attachValidation: true,
      schema: {
        body: {
          type: "object",
          required: ["email", "locale"],
          additionalProperties: false,
          properties: {
            email: { type: "string", maxLength: 320 },
            locale: { type: "string", enum: [...WAITLIST_LOCALES] },
            source: { type: "string", maxLength: 64, pattern: "^[A-Za-z0-9._-]*$" },
          },
        },
      },
    },
    async (request, reply) => {
      const form = isFormPost(request);
      if (limiter.isBlocked(request.ip)) {
        return form ? backToPage(request, reply, "busy") : reply.code(429).send({ error: "rate_limited" });
      }
      limiter.recordFailure(request.ip);

      if (request.validationError) {
        return form ? backToPage(request, reply, "email") : reply.code(400).send({ error: "invalid_body" });
      }
      const email = normalizeEmail(request.body.email);
      if (!email) return form ? backToPage(request, reply, "email") : reply.code(400).send({ error: "invalid_email" });

      // An existing address is left as it is: the answer is the same either way, so the
      // endpoint can't be used to find out who signed up.
      await db
        .insert(waitlist)
        .values({
          email,
          locale: request.body.locale,
          source: request.body.source?.toLowerCase() || null,
          unsubscribeToken: newWaitlistToken(),
        })
        .onConflictDoNothing({ target: waitlist.email });
      return form ? backToPage(request, reply, "joined") : reply.code(202).send({ status: "accepted" });
    },
  );

  const unsubscribe = async (token: string | undefined, reply: FastifyReply) => {
    let locale: WaitlistLocale = "en";
    if (token && token.length <= 128) {
      const [row] = await db
        .delete(waitlist)
        .where(eq(waitlist.unsubscribeToken, token))
        .returning({ locale: waitlist.locale });
      if (row?.locale === "he") locale = "he";
    }
    // Same page for unknown tokens: nothing to learn from it.
    return reply.code(200).type("text/html; charset=utf-8").send(unsubscribedPage(locale));
  };

  app.get<{ Querystring: { token?: string } }>("/waitlist/unsubscribe", async (request, reply) =>
    unsubscribe(request.query.token, reply),
  );
  // RFC 8058 one-click unsubscribe (List-Unsubscribe-Post) posts to the same URL.
  app.post<{ Querystring: { token?: string } }>("/waitlist/unsubscribe", async (request, reply) =>
    unsubscribe(request.query.token, reply),
  );

  app.get("/waitlist/stats", async (request, reply) => {
    const expected = opts.adminToken;
    const header = request.headers.authorization;
    const given = header?.startsWith("Bearer ") ? header.slice(7) : undefined;
    // Unset ADMIN_TOKEN: the route doesn't exist as far as callers can tell.
    if (!expected) return reply.code(404).send({ error: "not_found" });
    if (!given || !tokenMatches(given, expected)) return reply.code(401).send({ error: "unauthorized" });

    const weekAgo = new Date(now().getTime() - 7 * 24 * 60 * 60 * 1000);
    const [[total], [lastWeek], byLocale, bySource] = await Promise.all([
      db.select({ n: count() }).from(waitlist),
      db.select({ n: count() }).from(waitlist).where(gte(waitlist.createdAt, weekAgo)),
      db.select({ key: waitlist.locale, n: count() }).from(waitlist).groupBy(waitlist.locale),
      db
        .select({ key: sql<string>`coalesce(${waitlist.source}, '')`, n: count() })
        .from(waitlist)
        .groupBy(sql`coalesce(${waitlist.source}, '')`),
    ]);
    return {
      total: total?.n ?? 0,
      last7Days: lastWeek?.n ?? 0,
      byLocale: Object.fromEntries(byLocale.map((r) => [r.key, r.n])),
      bySource: Object.fromEntries(bySource.map((r) => [r.key || "direct", r.n])),
    };
  });
}

function landingPath(locale: unknown): string {
  return locale === "he" ? "/he/join" : "/join";
}

function unsubscribedPage(locale: WaitlistLocale): string {
  const he = locale === "he";
  const title = he ? "הוסרת מהרשימה" : "You're off the list";
  const body = he ? "לא נשלח לך עוד מיילים על Dog Monitor." : "We won't email you about Dog Monitor again.";
  return `<!doctype html>
<html lang="${locale}" dir="${he ? "rtl" : "ltr"}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<meta name="color-scheme" content="light dark">
<title>${title}</title>
<style>
  body { font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; margin: 0;
    min-height: 100vh; display: grid; place-items: center; padding: 24px; box-sizing: border-box; }
  main { max-width: 28rem; text-align: center; }
  h1 { font-size: 28px; margin: 0 0 8px; }
  p { margin: 0; opacity: 0.7; }
</style>
</head>
<body><main><h1>${title}</h1><p>${body}</p></main></body>
</html>`;
}
