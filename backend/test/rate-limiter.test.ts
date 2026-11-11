import { describe, expect, it } from "vitest";
import { RateLimiter } from "../src/limits/rate-limiter.js";

describe("RateLimiter", () => {
  it("allows a burst up to capacity, then refills over the period", () => {
    let t = 0;
    const limiter = new RateLimiter(3, 60_000, () => t);
    expect([1, 2, 3].map(() => limiter.tryTake("cam"))).toEqual([true, true, true]);
    expect(limiter.tryTake("cam")).toBe(false);
    expect(limiter.retryAfterSeconds("cam")).toBe(20);
    expect(limiter.tryTake("other")).toBe(true);
    t = 20_000;
    expect(limiter.tryTake("cam")).toBe(true);
    expect(limiter.tryTake("cam")).toBe(false);
  });

  it("forgets keys that have refilled", () => {
    let t = 0;
    const limiter = new RateLimiter(3, 1000, () => t);
    for (let i = 0; i < 50; i++) limiter.tryTake(`cam${i}`);
    expect(limiter.size).toBe(50);
    t = 5000;
    limiter.tryTake("fresh");
    expect(limiter.size).toBe(1);
  });
});
