import { describe, expect, it } from "vitest";
import { redactUrl, serializeRequest } from "../src/logging.js";

describe("log redaction", () => {
  it("hides invite tokens and query strings", () => {
    expect(redactUrl("/invite/abc123SECRET")).toBe("/invite/:token");
    expect(redactUrl("/invite/abc123SECRET?x=1")).toBe("/invite/:token");
    expect(redactUrl("/training/export?after=2026-01-01")).toBe("/training/export");
    expect(redactUrl("/household")).toBe("/household");
  });

  it("logs only method and redacted path, never the address", () => {
    const logged = serializeRequest({ method: "GET", url: "/invite/SECRET", ...{ ip: "1.2.3.4", remoteAddress: "1.2.3.4" } });
    expect(logged).toEqual({ method: "GET", url: "/invite/:token" });
    expect(JSON.stringify(logged)).not.toContain("SECRET");
    expect(JSON.stringify(logged)).not.toContain("1.2.3.4");
  });
});
