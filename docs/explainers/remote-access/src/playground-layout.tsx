// Layout wrapper for playground with timeline
import { type ReactNode } from "react";
import { Text } from "@cloudflare/kumo/components/text";
import { motion } from "motion/react";
import { formatTime, formatDuration } from "./simulator";
import type { Sim, LogEntry } from "./sim";

export function PlaygroundLayout({ children, sim, history, onJumpTo, showLog, logElement }: {
  children: ReactNode;
  sim: Sim;
  history: Sim[];
  onJumpTo: (index: number) => void;
  showLog: boolean;
  logElement: ReactNode;
}) {
  return (
    <div className="flex h-full flex-col gap-3">
      <div className="flex flex-1 gap-3 overflow-hidden">
        <div className="relative flex-1 overflow-hidden">
          {children}
        </div>
        
        <div className="w-80 flex-shrink-0 overflow-hidden rounded-xl bg-kumo-elevated p-4 shadow-lg ring-1 ring-kumo-line">
          <Timeline sim={sim} history={history} onJumpTo={onJumpTo} />
        </div>
      </div>

      {showLog && (
        <div className="flex-shrink-0">
          {logElement}
        </div>
      )}
    </div>
  );
}

function Timeline({ sim, history, onJumpTo }: { sim: Sim; history: Sim[]; onJumpTo: (index: number) => void }) {
  const events = [...sim.log].reverse().slice(0, 50);
  const currentTime = sim.now;
  
  return (
    <div className="flex h-full flex-col gap-3">
      <div className="flex items-center justify-between">
        <Text size="sm" bold>Timeline</Text>
        <Text size="xs" variant="secondary">{events.length} events</Text>
      </div>
      <div className="flex-1 space-y-1 overflow-y-auto">
        {events.map((event) => {
          const isPast = event.at <= currentTime;
          const canJumpTo = isPast && history.length > 0;
          return (
            <motion.button
              key={event.id}
              initial={{ opacity: 0, x: 10 }}
              animate={{ opacity: 1, x: 0 }}
              onClick={() => {
                if (canJumpTo) {
                  // Find the history entry closest to this event time
                  const targetIndex = history.findIndex((h) => h.now >= event.at);
                  if (targetIndex >= 0) onJumpTo(targetIndex);
                }
              }}
              disabled={!canJumpTo}
              className={`w-full rounded-lg px-3 py-2 text-left transition-colors ${
                isPast && canJumpTo
                  ? "bg-kumo-base hover:bg-kumo-tint"
                  : "bg-kumo-recessed opacity-50"
              }`}
            >
              <div className="flex items-start gap-2">
                <span className="font-mono text-[10px] font-semibold text-kumo-subtle">
                  {formatTime(event.at)}
                </span>
                <div className="flex-1 space-y-0.5">
                  <div className="text-xs font-medium">{event.title}</div>
                </div>
              </div>
            </motion.button>
          );
        })}
      </div>
    </div>
  );
}
