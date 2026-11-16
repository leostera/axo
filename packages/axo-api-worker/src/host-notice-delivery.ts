import type { HostNotice } from "./host-do";

interface NoticeTargets {
  direct(notices: HostNotice[]): Promise<void>;
  legacy(notices: HostNotice[]): Promise<void>;
  urgentFailure(): void;
}
function urgent(notice: HostNotice): boolean {
  return notice.kind === "elicitationRequested" || notice.kind === "elicitationResolved";
}

/** Human requests bypass legacy latency; transcript heads/epochs retain the legacy-first order. */
export async function deliverHostNoticeBatch(notices: HostNotice[], targets: NoticeTargets): Promise<void> {
  const requests = notices.filter(urgent);
  const direct = requests.length
    ? targets.direct(requests).catch(() => targets.urgentFailure())
    : null;
  await targets.legacy(notices);
  if (direct) await direct;
  const ordered = notices.filter(notice => !urgent(notice));
  if (ordered.length) await targets.direct(ordered);
}
