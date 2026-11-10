import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";

/** Long, URL-safe one-time token for QR codes and invite links. */
export function newInviteToken(): string {
  return randomBytes(24).toString("base64url");
}

/** 6-digit numeric code, zero-padded. */
export function newInviteCode(): string {
  return randomInt(0, 1_000_000).toString().padStart(6, "0");
}

/** High-entropy secret a camera device uses to authenticate. Only its hash is stored. */
export function newDeviceSecret(): string {
  return randomBytes(32).toString("base64url");
}

/** SHA-256 is sufficient here: the secret is 256 random bits, not a password. */
export function hashSecret(secret: string): string {
  return createHash("sha256").update(secret).digest("hex");
}

export function secretMatches(secret: string, storedHash: string): boolean {
  const a = Buffer.from(hashSecret(secret), "hex");
  const b = Buffer.from(storedHash, "hex");
  return a.length === b.length && timingSafeEqual(a, b);
}

export const INVITE_TTL_MS = 10 * 60 * 1000;
