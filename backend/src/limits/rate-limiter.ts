/**
 * In-memory token bucket per key (e.g. a camera's device id). Each key holds up to `capacity`
 * tokens and regains `capacity` every `periodMs`. Per-process, like the other limiters.
 */
export class RateLimiter {
  private readonly buckets = new Map<string, { tokens: number; at: number }>();
  private lastSweep = 0;

  constructor(
    private readonly capacity: number,
    private readonly periodMs: number,
    private readonly now: () => number = Date.now,
  ) {}

  /** Takes one token for `key`; false when the bucket is empty. */
  tryTake(key: string): boolean {
    const at = this.now();
    this.sweep(at);
    const bucket = this.buckets.get(key) ?? { tokens: this.capacity, at };
    const tokens = Math.min(this.capacity, bucket.tokens + ((at - bucket.at) / this.periodMs) * this.capacity);
    if (tokens < 1) {
      this.buckets.set(key, { tokens, at });
      return false;
    }
    this.buckets.set(key, { tokens: tokens - 1, at });
    return true;
  }

  /** Seconds until `key` has a token again (for Retry-After). */
  retryAfterSeconds(key: string): number {
    const bucket = this.buckets.get(key);
    if (!bucket) return 0;
    const missing = Math.max(0, 1 - bucket.tokens);
    return Math.ceil((missing * this.periodMs) / this.capacity / 1000);
  }

  /** Number of keys held (for tests). */
  get size(): number {
    return this.buckets.size;
  }

  /** Forgets keys that are full again, at most once per period, so the map cannot grow forever. */
  private sweep(at: number): void {
    if (at - this.lastSweep < this.periodMs) return;
    this.lastSweep = at;
    for (const [key, bucket] of this.buckets) {
      if (at - bucket.at >= this.periodMs) this.buckets.delete(key);
    }
  }
}
