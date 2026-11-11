/**
 * In-memory limiter for failed invite redemptions, to stop brute-forcing 6-digit codes.
 * Per-process only; good enough for a single Railway instance.
 */
export class AttemptLimiter {
  private readonly failures = new Map<string, number[]>();

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

  private recent(key: string): number[] {
    const cutoff = this.now() - this.windowMs;
    const list = (this.failures.get(key) ?? []).filter((t) => t > cutoff);
    if (list.length === 0) this.failures.delete(key);
    else this.failures.set(key, list);
    return list;
  }
}
