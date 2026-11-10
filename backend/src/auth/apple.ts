import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";

export const APPLE_ISSUER = "https://appleid.apple.com";
export const APPLE_JWKS_URL = new URL("https://appleid.apple.com/auth/keys");

export interface AppleIdentity {
  /** Stable user identifier for this app team. */
  sub: string;
  email?: string;
}

export interface AppleTokenVerifier {
  verify(identityToken: string): Promise<AppleIdentity>;
}

export class InvalidAppleTokenError extends Error {}

/**
 * Verifies Sign in with Apple identity tokens against Apple's JWKS.
 * Tests pass a local key set instead of the remote one.
 */
export function createAppleTokenVerifier(options: {
  audiences: string[];
  keySet?: JWTVerifyGetKey;
}): AppleTokenVerifier {
  const keySet = options.keySet ?? createRemoteJWKSet(APPLE_JWKS_URL);
  return {
    async verify(identityToken) {
      try {
        const { payload } = await jwtVerify(identityToken, keySet, {
          issuer: APPLE_ISSUER,
          audience: options.audiences,
          algorithms: ["RS256"],
        });
        if (typeof payload.sub !== "string" || payload.sub.length === 0) {
          throw new InvalidAppleTokenError("token has no subject");
        }
        const email = typeof payload.email === "string" ? payload.email : undefined;
        return { sub: payload.sub, email };
      } catch (err) {
        if (err instanceof InvalidAppleTokenError) throw err;
        throw new InvalidAppleTokenError(err instanceof Error ? err.message : "invalid token");
      }
    },
  };
}
