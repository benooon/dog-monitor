import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

/** Unguessable token for the unsubscribe link (192 bits). */
export function newWaitlistToken(): string {
  return randomBytes(24).toString("base64url");
}

/** Constant-time comparison of two secrets of any length (hashes first so lengths match). */
export function tokenMatches(given: string, expected: string): boolean {
  const a = createHash("sha256").update(given).digest();
  const b = createHash("sha256").update(expected).digest();
  return timingSafeEqual(a, b);
}
