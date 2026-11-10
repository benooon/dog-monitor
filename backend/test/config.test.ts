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
      retentionDays: 7,
      appLinkIds: [],
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

  it("reads S3 storage settings", () => {
    expect(loadConfig({}).s3).toBeUndefined();
    expect(
      loadConfig({ S3_BUCKET: "clips", S3_ACCESS_KEY_ID: "id", S3_SECRET_ACCESS_KEY: "secret", S3_ENDPOINT: "https://x.r2.cloudflarestorage.com" }).s3,
    ).toEqual({ endpoint: "https://x.r2.cloudflarestorage.com", region: "auto", bucket: "clips", accessKeyId: "id", secretAccessKey: "secret" });
    expect(() => loadConfig({ S3_BUCKET: "clips" })).toThrow(/S3_ACCESS_KEY_ID/);
    expect(loadConfig({ CLIP_RETENTION_DAYS: "3" }).retentionDays).toBe(3);
    expect(() => loadConfig({ CLIP_RETENTION_DAYS: "0" })).toThrow(/CLIP_RETENTION_DAYS/);
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

  it("builds the Universal Link app id from the team id", () => {
    expect(loadConfig({ APPLE_TEAM_ID: "ABCDE12345" }).appLinkIds).toEqual(["ABCDE12345.com.benooon.dogmonitor"]);
    expect(loadConfig({ APNS_KEY_ID: "K", APNS_TEAM_ID: "T1", APNS_KEY_P8: "p8" }).appLinkIds).toEqual(["T1.com.benooon.dogmonitor"]);
    expect(loadConfig({ APPLE_TEAM_ID: "T2", APPLE_BUNDLE_ID: "x.y" }).appLinkIds).toEqual(["T2.x.y"]);
  });

  it("parses APPLE_AUDIENCES", () => {
    expect(loadConfig({ APPLE_AUDIENCES: "a.b, c.d" }).appleAudiences).toEqual(["a.b", "c.d"]);
  });
});
