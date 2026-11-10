import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { JwtService } from "../src/auth/jwt.js";
import type { DbHandle } from "../src/db/client.js";
import { TEST_NONCE } from "./helpers/apple.js";
import { buildTestApp } from "./helpers/app.js";
import { hasDatabase, openTestDb, truncateAll } from "./helpers/db.js";

describe("JwtService", () => {
  it("round-trips claims and rejects tampering and other secrets", async () => {
    const jwt = new JwtService("a".repeat(32), 60);
    const token = await jwt.issue({ userId: "u1" });
    expect(await jwt.verify(token)).toEqual({ userId: "u1" });
    expect(await jwt.verify(token + "x")).toBeNull();
    expect(await new JwtService("b".repeat(32), 60).verify(token)).toBeNull();
  });

  it("rejects expired tokens", async () => {
    const jwt = new JwtService("a".repeat(32), 1);
    const token = await jwt.issue({ userId: "u1" });
    await new Promise((r) => setTimeout(r, 2100));
    expect(await jwt.verify(token)).toBeNull();
  });
});

describe.skipIf(!hasDatabase)("POST /auth/apple and GET /me", () => {
  let h: DbHandle;
  let ctx: Awaited<ReturnType<typeof buildTestApp>>;
  let app: FastifyInstance;

  beforeAll(async () => {
    h = openTestDb();
    ctx = await buildTestApp(h);
    app = ctx.app;
  });
  afterAll(async () => {
    await app.close();
    await h.close();
  });
  beforeEach(async () => {
    await truncateAll(h);
  });

  const signIn = (identityToken: string, name?: string, nonce = TEST_NONCE) =>
    app.inject({
      method: "POST",
      url: "/auth/apple",
      payload: name ? { identityToken, nonce, name } : { identityToken, nonce },
    });

  it("creates a user and returns a JWT that works for /me", async () => {
    const res = await signIn(await ctx.apple.sign({ sub: "apple-123" }), "Ben");
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.user.name).toBe("Ben");
    expect(typeof body.token).toBe("string");

    const me = await app.inject({ method: "GET", url: "/me", headers: { authorization: `Bearer ${body.token}` } });
    expect(me.statusCode).toBe(200);
    expect(me.json()).toEqual({ user: { id: body.user.id, name: "Ben" }, households: [] });
  });

  it("returns the same user on later sign-ins and keeps the name", async () => {
    const first = (await signIn(await ctx.apple.sign({ sub: "apple-123" }), "Ben")).json();
    const second = (await signIn(await ctx.apple.sign({ sub: "apple-123" }))).json();
    expect(second.user).toEqual(first.user);
  });

  it("rejects tokens with the wrong audience, issuer, signature, or expiry", async () => {
    const bad = [
      await ctx.apple.sign({ aud: "com.someone.else" }),
      await ctx.apple.sign({ iss: "https://evil.example.com" }),
      await ctx.apple.sign({ expiresIn: "-1m" }),
      await ctx.apple.sign({ sub: "" }),
      "not-a-jwt",
    ];
    for (const token of bad) {
      const res = await signIn(token);
      expect(res.statusCode, token).toBe(401);
      expect(res.json()).toEqual({ error: "invalid_identity_token" });
    }

    // Signed by a different key with the same kid.
    const { createFakeApple } = await import("./helpers/apple.js");
    const other = await createFakeApple();
    expect((await signIn(await other.sign())).statusCode).toBe(401);
  });

  it("rejects a missing or mismatched nonce", async () => {
    const withoutNonce = await ctx.apple.sign({ nonce: null });
    expect((await signIn(withoutNonce)).statusCode).toBe(401);
    const token = await ctx.apple.sign({ nonce: "another-nonce-value-123" });
    expect((await signIn(token)).statusCode).toBe(401);
    expect((await signIn(token, undefined, "another-nonce-value-123")).statusCode).toBe(200);
    // The nonce field itself is required.
    const res = await app.inject({ method: "POST", url: "/auth/apple", payload: { identityToken: token } });
    expect(res.statusCode).toBe(400);
  });

  it("validates the body", async () => {
    const res = await app.inject({ method: "POST", url: "/auth/apple", payload: {} });
    expect(res.statusCode).toBe(400);
  });

  it("requires a valid bearer token on /me", async () => {
    expect((await app.inject({ method: "GET", url: "/me" })).statusCode).toBe(401);
    const forged = await new JwtService("x".repeat(40), 60).issue({ userId: "00000000-0000-0000-0000-000000000000" });
    expect(
      (await app.inject({ method: "GET", url: "/me", headers: { authorization: `Bearer ${forged}` } })).statusCode,
    ).toBe(401);
  });

  it("returns 401 on /me when the user no longer exists", async () => {
    const token = await ctx.jwt.issue({ userId: "00000000-0000-0000-0000-000000000000" });
    expect((await app.inject({ method: "GET", url: "/me", headers: { authorization: `Bearer ${token}` } })).statusCode).toBe(
      401,
    );
  });
});
