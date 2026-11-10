import { describe, expect, it } from "vitest";
import { inQuietHours, isValidTimeZone, localMinutes, parseTimeOfDay } from "../src/notifications/quiet-hours.js";

describe("quiet hours", () => {
  it("parses Postgres times", () => {
    expect(parseTimeOfDay("22:30")).toBe(22 * 60 + 30);
    expect(parseTimeOfDay("07:00:00")).toBe(420);
    expect(parseTimeOfDay("25:00")).toBeNull();
    expect(parseTimeOfDay("7am")).toBeNull();
    expect(parseTimeOfDay(null)).toBeNull();
  });

  it("converts to local time in the phone's zone", () => {
    const now = new Date("2026-11-10T20:30:00Z");
    expect(localMinutes(now, "Asia/Jerusalem")).toBe(22 * 60 + 30); // UTC+2 in November
    expect(localMinutes(now, "UTC")).toBe(20 * 60 + 30);
    expect(localMinutes(now, "Not/AZone")).toBeNull();
    expect(isValidTimeZone("America/New_York")).toBe(true);
    expect(isValidTimeZone("Mars/Base")).toBe(false);
  });

  it("handles windows that wrap midnight", () => {
    const tz = "Asia/Jerusalem";
    expect(inQuietHours(new Date("2026-11-10T20:30:00Z"), tz, "22:00", "07:00")).toBe(true); // 22:30 local
    expect(inQuietHours(new Date("2026-11-11T04:59:00Z"), tz, "22:00", "07:00")).toBe(true); // 06:59 local
    expect(inQuietHours(new Date("2026-11-11T05:00:00Z"), tz, "22:00", "07:00")).toBe(false); // 07:00 local
    expect(inQuietHours(new Date("2026-11-10T12:00:00Z"), tz, "13:00", "15:00")).toBe(true); // 14:00 local
    expect(inQuietHours(new Date("2026-11-10T14:00:00Z"), tz, "13:00", "15:00")).toBe(false); // 16:00 local
  });

  it("is never quiet without a zone or a full window", () => {
    const now = new Date("2026-11-10T20:30:00Z");
    expect(inQuietHours(now, null, "22:00", "07:00")).toBe(false);
    expect(inQuietHours(now, "UTC", null, "07:00")).toBe(false);
    expect(inQuietHours(now, "UTC", "07:00", "07:00")).toBe(false);
  });
});
