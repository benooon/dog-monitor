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

  it("reads APNs credentials only when all three are set", () => {
    expect(loadConfig({}).apns).toBeUndefined();
    expect(loadConfig({ APNS_KEY_ID: "K", APNS_TEAM_ID: "T", APNS_KEY_P8: "-----BEGIN\\nabc" }).apns).toEqual({
      keyId: "K",
      teamId: "T",
      privateKey: "-----BEGIN\nabc",
      topic: "com.benooon.dogmonitor",
      environment: "sandbox",
    });
    expect(() => loadConfig({ APNS_KEY_ID: "K" })).toThrow(/APNS_TEAM_ID/);
    expect(() => loadConfig({ APNS_ENV: "staging" })).toThrow(/APNS_ENV/);
  });

  it("reads LiveKit credentials only when all three are set", () => {
    expect(loadConfig({}).liveKit).toBeUndefined();
    expect(
      loadConfig({ LIVEKIT_URL: "wss://x.livekit.cloud", LIVEKIT_API_KEY: "key", LIVEKIT_API_SECRET: "secret" }).liveKit,
    ).toEqual({ url: "wss://x.livekit.cloud", apiKey: "key", apiSecret: "secret" });
    expect(() => loadConfig({ LIVEKIT_URL: "wss://x.livekit.cloud" })).toThrow(/LIVEKIT_API_KEY/);
    expect(() =>
      loadConfig({ LIVEKIT_URL: "https://x.livekit.cloud", LIVEKIT_API_KEY: "k", LIVEKIT_API_SECRET: "s" }),
    ).toThrow(/Invalid LIVEKIT_URL/);
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
