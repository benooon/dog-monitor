import { describe, expect, it } from "vitest";
import { loadConfig, requireServerConfig } from "../src/config.js";

describe("loadConfig", () => {
  it("uses defaults", () => {
    expect(loadConfig({})).toEqual({
      port: 3000,
      host: "0.0.0.0",
      logLevel: "info",
      nodeEnv: "development",
      databaseUrl: undefined,
      jwtSecret: undefined,
      jwtTtlSeconds: 2592000,
      appleAudiences: ["com.benooon.dogmonitor"],
    });
  });

  it("reads PORT from env (Railway sets it)", () => {
    expect(loadConfig({ PORT: "8080" }).port).toBe(8080);
  });

  it("rejects an invalid PORT", () => {
    expect(() => loadConfig({ PORT: "abc" })).toThrow(/Invalid PORT/);
  });
});

describe("requireServerConfig", () => {
  it("lists missing values", () => {
    expect(() => requireServerConfig(loadConfig({}))).toThrow(/DATABASE_URL, JWT_SECRET/);
  });

  it("rejects a short JWT secret", () => {
    expect(() => requireServerConfig(loadConfig({ DATABASE_URL: "postgres://x", JWT_SECRET: "short" }))).toThrow(
      /at least 32/,
    );
  });

  it("parses APPLE_AUDIENCES", () => {
    expect(loadConfig({ APPLE_AUDIENCES: "a.b, c.d" }).appleAudiences).toEqual(["a.b", "c.d"]);
  });
});
