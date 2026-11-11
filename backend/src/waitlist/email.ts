export const WAITLIST_LOCALES = ["he", "en"] as const;
export type WaitlistLocale = (typeof WAITLIST_LOCALES)[number];

const EMAIL = /^[^\s@]+@[^\s@.]+(\.[^\s@.]+)*\.[^\s@.]{2,}$/;

/** Trimmed and lowercased, or null when it doesn't look like an email address (RFC 5321 length limit). */
export function normalizeEmail(raw: string): string | null {
  const email = raw.trim().toLowerCase();
  if (email.length > 254 || !EMAIL.test(email)) return null;
  return email;
}
