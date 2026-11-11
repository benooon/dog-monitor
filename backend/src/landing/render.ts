import type { WaitlistLocale } from "../waitlist/email.js";
import type { LandingCopy } from "./copy.js";

export type LandingState = "idle" | "joined" | "error-email" | "error-busy";

const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ESCAPES[c]!);
}

/** Fills `{{key}}` placeholders in public/join.html. Every value is HTML-escaped. */
export function renderLandingPage(
  template: string,
  copy: LandingCopy,
  opts: { locale: WaitlistLocale; origin: string; source?: string; state: LandingState },
): string {
  const he = opts.locale === "he";
  const path = he ? "/he/join" : "/join";
  const source = opts.source && /^[A-Za-z0-9._-]{1,64}$/.test(opts.source) ? opts.source.toLowerCase() : "";
  const otherPath = he ? "/join" : "/he/join";
  const values: Record<string, string> = {
    ...copy,
    lang: opts.locale,
    dir: he ? "rtl" : "ltr",
    ogLocale: he ? "he_IL" : "en_US",
    canonical: opts.origin + path,
    alternateEn: `${opts.origin}/join`,
    alternateHe: `${opts.origin}/he/join`,
    ogImage: `${opts.origin}/media/og-${opts.locale}.jpg`,
    source,
    otherHref: source ? `${otherPath}?s=${source}` : otherPath,
    otherLangCode: he ? "en" : "he",
    state: opts.state === "joined" ? "joined" : opts.state === "idle" ? "idle" : "error",
    statusText: opts.state === "error-email" ? copy.errEmail : opts.state === "error-busy" ? copy.errBusy : "",
  };
  return template.replace(/\{\{(\w+)\}\}/g, (match, key: string) => {
    const value = values[key];
    if (value === undefined) throw new Error(`join.html: no value for ${match}`);
    return escapeHtml(value);
  });
}
