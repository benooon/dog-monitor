import { SignJWT, createLocalJWKSet, exportJWK, generateKeyPair, type JWTVerifyGetKey } from "jose";
import { APPLE_ISSUER } from "../../src/auth/apple.js";

/** A fake "Apple" signing key plus a local JWKS, so tests never hit appleid.apple.com. */
export async function createFakeApple(kid = "test-key") {
  const { privateKey, publicKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid, alg: "RS256", use: "sig" };
  const keySet: JWTVerifyGetKey = createLocalJWKSet({ keys: [jwk] });

  async function sign(
    claims: { sub?: string; email?: string; aud?: string; iss?: string; expiresIn?: string } = {},
  ): Promise<string> {
    const jwt = new SignJWT(claims.email ? { email: claims.email } : {})
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
