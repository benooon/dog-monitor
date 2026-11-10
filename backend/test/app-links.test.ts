import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";

describe("Universal Links", () => {
  let configured: FastifyInstance;
  let unconfigured: FastifyInstance;

  beforeAll(async () => {
    configured = await buildApp({ logLevel: "silent", appLinkIds: ["TEAM.com.benooon.dogmonitor"] });
    unconfigured = await buildApp({ logLevel: "silent" });
  });
  afterAll(async () => {
    await configured.close();
    await unconfigured.close();
  });

  it("serves the apple-app-site-association for invite links", async () => {
    const res = await configured.inject({ method: "GET", url: "/.well-known/apple-app-site-association" });
    expect(res.statusCode).toBe(200);
    expect(res.headers["content-type"]).toContain("application/json");
    expect(res.json()).toEqual({
      applinks: {
        details: [{ appIDs: ["TEAM.com.benooon.dogmonitor"], components: [{ "/": "/invite/*", comment: "Household invites" }] }],
      },
    });
  });

  it("answers 404 until the team id is set", async () => {
    const res = await unconfigured.inject({ method: "GET", url: "/.well-known/apple-app-site-association" });
    expect(res.statusCode).toBe(404);
  });

  it("shows a short page when an invite link opens in a browser", async () => {
    const res = await configured.inject({ method: "GET", url: "/invite/abc123" });
    expect(res.statusCode).toBe(200);
    expect(res.headers["content-type"]).toContain("text/html");
    expect(res.body).toContain("6-digit code");
  });
});
