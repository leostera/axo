/** Notification effects only; never asks permission or answers a request. */
export interface DesktopNotice { close(): void }
type Request = { readonly id: string; readonly expiresAt: number };
export class ElicitationNotifications {
  /** Remember delivery through transient reconnects, only until the request's own expiry. */
  private readonly active = new Map<string, { expiresAt: number; notice: DesktopNotice | null }>();

  update(requests: readonly Request[], permitted: boolean, show: (id: string) => DesktopNotice, now = Date.now()): void {
    const pending = new Set(requests.map(request => request.id));
    for (const [id, entry] of this.active) {
      if (!permitted || !pending.has(id) || entry.expiresAt <= now) { entry.notice?.close(); entry.notice = null; }
      if (entry.expiresAt <= now) this.active.delete(id);
    }
    if (!permitted) return;
    for (const request of requests) {
      if (request.expiresAt <= now || this.active.has(request.id)) continue;
      const entry = { expiresAt: request.expiresAt, notice: null as DesktopNotice | null };
      this.active.set(request.id, entry);
      try { entry.notice = show(request.id); } catch { /* Unsupported browsers keep the inbox. */ }
    }
  }

  dispose(): void {
    for (const entry of this.active.values()) entry.notice?.close();
    this.active.clear();
  }
}
