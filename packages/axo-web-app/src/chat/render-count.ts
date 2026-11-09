/**
 * How often each part of the conversation renders, for the browser tests to count: in development
 * builds only, in `window.__axoRenders`. A production build drops the call.
 */
export function noteRender(name: string): void {
  if (!import.meta.env?.DEV) return;
  const counts = ((globalThis as { __axoRenders?: Record<string, number> }).__axoRenders ??= {});
  counts[name] = (counts[name] ?? 0) + 1;
}
