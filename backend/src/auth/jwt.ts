import { SignJWT, jwtVerify } from "jose";

const ISSUER = "dog-monitor";
const AUDIENCE = "dog-monitor-app";

export interface UserClaims {
  userId: string;
}

/** Issues and verifies our own HS256 JWTs for signed-in users. */
export class JwtService {
  private readonly key: Uint8Array;

  constructor(
    secret: string,
    private readonly ttlSeconds: number,
  ) {
    this.key = new TextEncoder().encode(secret);
  }

  /** `ttlSeconds` overrides the default lifetime (e.g. short-lived export tokens). */
  async issue(claims: UserClaims, ttlSeconds: number = this.ttlSeconds): Promise<string> {
    return new SignJWT({})
      .setProtectedHeader({ alg: "HS256" })
      .setSubject(claims.userId)
      .setIssuer(ISSUER)
      .setAudience(AUDIENCE)
      .setIssuedAt()
      .setExpirationTime(`${ttlSeconds}s`)
      .sign(this.key);
  }

  /** Returns the claims, or null if the token is invalid or expired. */
  async verify(token: string): Promise<UserClaims | null> {
    try {
      const { payload } = await jwtVerify(token, this.key, {
        issuer: ISSUER,
        audience: AUDIENCE,
        algorithms: ["HS256"],
      });
      return typeof payload.sub === "string" ? { userId: payload.sub } : null;
    } catch {
      return null;
    }
  }
}
