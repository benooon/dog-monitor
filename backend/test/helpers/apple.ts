import { SignJWT, createLocalJWKSet, exportJWK, generateKeyPair, type JWTVerifyGetKey } from "jose";
import { APPLE_ISSUER, hashNonce } from "../../src/auth/apple.js";

export const TEST_NONCE = "test-nonce-0123456789abcdef";

/** A fake "Apple" signing key plus a local JWKS, so tests never hit appleid.apple.com. */
export async function createFakeApple(kid = "test-key") {
  const { privateKey, publicKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid, alg: "RS256", use: "sig" };
  const keySet: JWTVerifyGetKey = createLocalJWKSet({ keys: [jwk] });

  async function sign(
    claims: { sub?: string; email?: string; aud?: string; iss?: string; expiresIn?: string; nonce?: string | null } = {},
  ): Promise<string> {
    const payload: Record<string, string> = {};
    if (claims.email) payload.email = claims.email;
    if (claims.nonce !== null) payload.nonce = hashNonce(claims.nonce ?? TEST_NONCE);
    const jwt = new SignJWT(payload)
      .setProtectedHeader({ alg: "RS256", kid })
      .setIssuer(claims.iss ?? APPLE_ISSUER)
      .setAudience(claims.aud ?? "com.benooon.dogmonitor")
      .setIssuedAt()
      .setExpirationTime(claims.expiresIn ?? "10m");
    if (claims.sub !== "") jwt.setSubject(claims.sub ?? "apple-user-1");
    return jwt.sign(privateKey);
  }

  return { keySet, sign };
}
