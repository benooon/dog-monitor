/**
 * Open realtime sockets by principal, so removing a member, revoking a device or deleting a
 * household ends their live connections right away (security audit 2026-11). In-memory, like the hub.
 */
export class RealtimeSessions {
  private readonly sessions = new Map<string, Set<(reason: string) => void>>();

  static user(userId: string): string {
    return `user:${userId}`;
  }

  static device(deviceId: string): string {
    return `device:${deviceId}`;
  }

  static household(householdId: string): string {
    return `household:${householdId}`;
  }

  /** Number of tracked keys (for tests: zero once every socket has closed). */
  get size(): number {
    return this.sessions.size;
  }

  /** Registers a socket's close function under each key; returns the function that unregisters it. */
  track(keys: string[], close: (reason: string) => void): () => void {
    for (const key of keys) {
      const set = this.sessions.get(key) ?? new Set();
      set.add(close);
      this.sessions.set(key, set);
    }
    return () => {
      for (const key of keys) {
        const set = this.sessions.get(key);
        set?.delete(close);
        if (set?.size === 0) this.sessions.delete(key);
      }
    };
  }

  /** Closes every socket registered under the key. */
  closeAll(key: string, reason: string): number {
    const closers = [...(this.sessions.get(key) ?? [])];
    for (const close of closers) close(reason);
    return closers.length;
  }
}
