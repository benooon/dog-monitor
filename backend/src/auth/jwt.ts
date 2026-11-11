import { SignJWT, jwtVerify } from "jose";

const ISSUER = "dog-monitor";
/** Audiences keep token kinds apart: a training export key is not a session (security audit 2026-11). */
export const TOKEN_AUDIENCES = { session: "dog-monitor-app", trainingExport: "dog-monitor-training-export" } as const;
export type TokenKind = keyof typeof TOKEN_AUDIENCES;

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

  /** `ttlSeconds` overrides the default lifetime; `kind` picks the audience (only sessions pass `app.authenticate`). */
  async issue(claims: UserClaims, ttlSeconds: number = this.ttlSeconds, kind: TokenKind = "session"): Promise<string> {
    return new SignJWT({})
      .setProtectedHeader({ alg: "HS256" })
      .setSubject(claims.userId)
      .setIssuer(ISSUER)
      .setAudience(TOKEN_AUDIENCES[kind])
      .setIssuedAt()
      .setExpirationTime(`${ttlSeconds}s`)
      .sign(this.key);
  }

  /** Returns the claims, or null if the token is invalid, expired or of another kind. */
  async verify(token: string, kind: TokenKind = "session"): Promise<UserClaims | null> {
    try {
      const { payload } = await jwtVerify(token, this.key, {
        issuer: ISSUER,
        audience: TOKEN_AUDIENCES[kind],
        algorithms: ["HS256"],
      });
      return typeof payload.sub === "string" ? { userId: payload.sub } : null;
    } catch {
      return null;
    }
  }
}
