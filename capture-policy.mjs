import { randomUUID } from 'node:crypto';

export const defaultCapturePreferences = { windowReturnSeconds: 60 };
export function capturePreferences(value) {
  const seconds = value?.windowReturnSeconds ?? 60;
  if (!Number.isInteger(seconds) || seconds < 0 || seconds > 3600) throw new Error('窗口返回间隔需为 0 至 3600 秒');
  return { windowReturnSeconds: seconds };
}

// Window identity comes from the OS, not its mutable title or application name.
export class WindowSessions {
  constructor() { this.reset(); }
  reset() { this.windows = new Map(); this.current = null; this.lastObserved = null; }
  observe(key, now, returnSeconds) {
    // A suspended helper / sleeping Mac must not bridge an unobserved absence.
    if (this.lastObserved !== null && now - this.lastObserved > Math.max(5000, returnSeconds * 1000)) {
      if (this.current && this.windows.has(this.current)) this.windows.get(this.current).leftAt = this.lastObserved;
      this.current = null;
    }
    this.lastObserved = now;
    if (key !== this.current) {
      if (this.current && this.windows.has(this.current)) this.windows.get(this.current).leftAt = now;
      this.current = key;
      if (key) {
        const previous = this.windows.get(key);
        if (!previous || returnSeconds === 0 || previous.leftAt === null || now - previous.leftAt > returnSeconds * 1000) {
          this.windows.set(key, { id: randomUUID(), leftAt: null });
        } else previous.leftAt = null;
      }
    }
    for (const [window, session] of this.windows) {
      if (window !== this.current && session.leftAt !== null && now - session.leftAt > returnSeconds * 1000) this.windows.delete(window);
    }
    return key ? this.windows.get(key)?.id ?? null : null;
  }
}

export const retentionAgeMs = 60 * 60 * 1000;
export const retentionSweepMs = 5 * 60 * 1000;
export function expiredPendingCaptures(db, { recording, now = Date.now(), limit = 500 }) {
  if (!recording) return [];
  // Keep in-flight jobs, manual imports, completed/unmatched records and prior
  // classifications queued for another pass. Retention concerns the new backlog.
  return db.prepare(`SELECT id, frames FROM records WHERE kind='capture' AND status='pending'
    AND model IS NULL AND scores='{}' AND manual='{}' AND created < ? ORDER BY created LIMIT ?`)
    .all(new Date(now - retentionAgeMs).toISOString(), limit);
}
