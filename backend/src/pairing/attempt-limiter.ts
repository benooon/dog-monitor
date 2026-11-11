/**
 * In-memory limiter for failed invite redemptions, to stop brute-forcing 6-digit codes.
 * Per-process only; good enough for a single Railway instance.
 */
export class AttemptLimiter {
  private readonly failures = new Map<string, number[]>();
  private lastSweep = 0;

  constructor(
    private readonly maxFailures: number,
    private readonly windowMs: number,
    private readonly now: () => number = Date.now,
  ) {}

  isBlocked(key: string): boolean {
    return this.recent(key).length >= this.maxFailures;
  }

  /**
   * Counts an attempt before it is evaluated and says whether it may go ahead. Check and record
   * happen together, so concurrent requests can't all slip under the limit (audit 2026-11).
   */
  tryAcquire(key: string): boolean {
    const list = this.recent(key);
    if (list.length >= this.maxFailures) return false;
    list.push(this.now());
    this.failures.set(key, list);
    return true;
  }

  /** Gives back an attempt taken with `tryAcquire` that turned out not to be a failure. */
  release(key: string): void {
    const list = this.recent(key);
    list.pop();
    if (list.length === 0) this.failures.delete(key);
    else this.failures.set(key, list);
  }

  recordFailure(key: string): void {
    const list = this.recent(key);
    list.push(this.now());
    this.failures.set(key, list);
  }

  /** Number of keys held (for tests). */
  get size(): number {
    return this.failures.size;
  }

  /**
   * Drops keys whose attempts have all expired. Without it, one-off keys (spoofed or rotating
   * IPs) would stay in memory forever (audit 2026-11, run 2). Runs at most once per window.
   */
  private sweep(): void {
    const at = this.now();
    if (at - this.lastSweep < this.windowMs) return;
    this.lastSweep = at;
    const cutoff = at - this.windowMs;
    for (const [key, list] of this.failures) {
      if (!list.some((t) => t > cutoff)) this.failures.delete(key);
    }
  }

  private recent(key: string): number[] {
    this.sweep();
    const cutoff = this.now() - this.windowMs;
    const list = (this.failures.get(key) ?? []).filter((t) => t > cutoff);
    if (list.length === 0) this.failures.delete(key);
    else this.failures.set(key, list);
    return list;
  }
}
