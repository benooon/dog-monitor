import { describe, expect, it } from "vitest";
import { loadConfig, requireServerConfig } from "../src/config.js";
import { APPLE_ROOT_CA_G3_SHA256 } from "../src/billing/app-store.js";

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
      appStore: {
        bundleId: "com.benooon.dogmonitor",
        productIds: ["com.benooon.dogmonitor.premium.monthly", "com.benooon.dogmonitor.premium.yearly"],
        rootFingerprints: [APPLE_ROOT_CA_G3_SHA256],
      },
      enforcePlanLimits: false,
      warnings: [],
    });
  });

  it("reads App Store and plan settings", () => {
    const config = loadConfig({ APP_STORE_PRODUCT_IDS: "a, b", APPLE_ROOT_CA_SHA256: "AA:BB", ENFORCE_PLAN_LIMITS: "true" });
    expect(config.appStore.productIds).toEqual(["a", "b"]);
    expect(config.appStore.rootFingerprints).toEqual(["AA:BB"]);
    expect(config.enforcePlanLimits).toBe(true);
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
    const partial = loadConfig({ APNS_KEY_ID: "K" });
    expect(partial.apns).toBeUndefined();
    expect(partial.warnings).toEqual([expect.stringMatching(/Push notifications is off: set APNS_TEAM_ID, APNS_KEY_P8/)]);
    const staging = loadConfig({ APNS_ENV: "staging", APNS_KEY_ID: "K", APNS_TEAM_ID: "T", APNS_KEY_P8: "P" });
    expect(staging.apns?.environment).toBe("sandbox");
    expect(staging.warnings).toEqual([expect.stringMatching(/APNS_ENV/)]);
  });

  it("reads S3 storage settings", () => {
    expect(loadConfig({}).s3).toBeUndefined();
    expect(
      loadConfig({ S3_BUCKET: "clips", S3_ACCESS_KEY_ID: "id", S3_SECRET_ACCESS_KEY: "secret", S3_ENDPOINT: "https://x.r2.cloudflarestorage.com" }).s3,
    ).toEqual({
      endpoint: "https://x.r2.cloudflarestorage.com",
      region: "auto",
      bucket: "clips",
      accessKeyId: "id",
      secretAccessKey: "secret",
      forcePathStyle: true,
    });
    const railway = { S3_BUCKET: "clips-abc", S3_ACCESS_KEY_ID: "id", S3_SECRET_ACCESS_KEY: "secret", S3_ENDPOINT: "https://t3.storageapi.dev" };
    expect(loadConfig(railway).s3?.forcePathStyle).toBe(false);
    expect(loadConfig({ ...railway, S3_FORCE_PATH_STYLE: "true" }).s3?.forcePathStyle).toBe(true);
    const partial = loadConfig({ S3_BUCKET: "clips" });
    expect(partial.s3).toBeUndefined();
    expect(partial.warnings).toEqual([expect.stringMatching(/Clip storage is off: set S3_ACCESS_KEY_ID/)]);
    expect(loadConfig({ CLIP_RETENTION_DAYS: "3" }).retentionDays).toBe(3);
    expect(() => loadConfig({ CLIP_RETENTION_DAYS: "0" })).toThrow(/CLIP_RETENTION_DAYS/);
  });

  it("reads LiveKit credentials only when all three are set", () => {
    expect(loadConfig({}).liveKit).toBeUndefined();
    expect(
      loadConfig({ LIVEKIT_URL: "wss://x.livekit.cloud", LIVEKIT_API_KEY: "key", LIVEKIT_API_SECRET: "secret" }).liveKit,
    ).toEqual({ url: "wss://x.livekit.cloud", apiKey: "key", apiSecret: "secret" });
    const partial = loadConfig({ LIVEKIT_URL: "wss://x.livekit.cloud" });
    expect(partial.liveKit).toBeUndefined();
    expect(partial.warnings).toEqual([expect.stringMatching(/Live view is off: set LIVEKIT_API_KEY, LIVEKIT_API_SECRET/)]);
    expect(
      loadConfig({ LIVEKIT_URL: " https://x.livekit.cloud ", LIVEKIT_API_KEY: "k", LIVEKIT_API_SECRET: "s" }).liveKit?.url,
    ).toBe("wss://x.livekit.cloud");
    const invalid = loadConfig({ LIVEKIT_URL: "x.livekit.cloud", LIVEKIT_API_KEY: "k", LIVEKIT_API_SECRET: "s" });
    expect(invalid.liveKit).toBeUndefined();
    expect(invalid.warnings).toEqual([expect.stringMatching(/LIVEKIT_URL must start with wss:\/\//)]);
  });

  it("treats blank values as unset instead of stopping the server", () => {
    const config = loadConfig({ LIVEKIT_URL: "", LIVEKIT_API_KEY: "  ", LIVEKIT_API_SECRET: "", S3_BUCKET: " ", JWT_SECRET: "  " });
    expect(config.liveKit).toBeUndefined();
    expect(config.s3).toBeUndefined();
    expect(config.jwtSecret).toBeUndefined();
    expect(config.warnings).toEqual([]);
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
