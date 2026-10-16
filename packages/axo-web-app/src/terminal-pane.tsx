import { HostRelayConnection, type Session } from "@axo/app";
import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import { useEffect, useRef } from "react";

type Activity = "running" | "exited" | "attached" | "detached" | "unknown";
export type TerminalRegistry = Map<string, Terminal>;

function keyFor(sessionId: number, shellId: number): string {
  return `${sessionId}:${shellId}`;
}

function encodeBase64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function sequenceStorageKey(
  hostGeneration: string | null,
  sessionId: number,
  shellId: number,
): string | null {
  if (!hostGeneration) return null;
  return `axo.remote.input.v1:${hostGeneration}:${sessionId}:${shellId}`;
}

function readNextSequence(storageKey: string | null): number {
  if (!storageKey) return 0;
  try {
    const value = Number(window.localStorage.getItem(storageKey));
    return Number.isSafeInteger(value) && value >= 0 ? value : 0;
  } catch {
    return 0;
  }
}

function storeNextSequence(storageKey: string | null, sequence: number): void {
  if (!storageKey) return;
  try {
    window.localStorage.setItem(storageKey, String(sequence));
  } catch {
    // Storage is optional; the current live connection still works without it.
  }
}

export function TerminalPane({
  session,
  shellId,
  hostGeneration,
  connection,
  active,
  registry,
  activity,
  focused,
  onFocus,
  onInputError,
}: {
  session: Session;
  shellId: number;
  hostGeneration: string | null;
  connection: HostRelayConnection | null;
  active: boolean;
  registry: TerminalRegistry;
  activity: Activity;
  focused: boolean;
  onFocus: () => void;
  onInputError: (error: unknown) => void;
}) {
  const element = useRef<HTMLDivElement>(null);
  const terminalRef = useRef<Terminal | null>(null);
  const propsRef = useRef({ connection, active, onInputError, onFocus });
  propsRef.current = { connection, active, onInputError, onFocus };

  useEffect(() => {
    const node = element.current;
    if (!node) return;

    const terminal = new Terminal({
      allowProposedApi: false,
      convertEol: false,
      cursorBlink: true,
      cursorStyle: "bar",
      fontFamily: '"SFMono-Regular", Menlo, Monaco, "Cascadia Mono", monospace',
      fontSize: 13,
      lineHeight: 1.35,
      scrollback: 5000,
      theme: {
        background: "#111116",
        foreground: "#e8e7ee",
        cursor: "#d8b4fe",
        cursorAccent: "#111116",
        selectionBackground: "#6b5e8f80",
        black: "#22212b",
        red: "#f38ba8",
        green: "#a6e3a1",
        yellow: "#f9e2af",
        blue: "#89b4fa",
        magenta: "#cba6f7",
        cyan: "#94e2d5",
        white: "#bac2de",
        brightBlack: "#58566b",
        brightRed: "#f38ba8",
        brightGreen: "#a6e3a1",
        brightYellow: "#f9e2af",
        brightBlue: "#89b4fa",
        brightMagenta: "#cba6f7",
        brightCyan: "#94e2d5",
        brightWhite: "#a6adc8",
      },
    });
    const fit = new FitAddon();
    terminal.loadAddon(fit);
    terminal.open(node);
    terminalRef.current = terminal;
    registry.set(keyFor(session.sessionId, shellId), terminal);

    const storageKey = sequenceStorageKey(hostGeneration, session.sessionId, shellId);
    const nextSequence = { current: readNextSequence(storageKey) };
    let inputQueue = Promise.resolve();
    terminal.onData((data) => {
      const current = propsRef.current;
      if (!current.active || !current.connection?.active) return;
      const encoded = encodeBase64(data);
      inputQueue = inputQueue.then(async () => {
        const latest = propsRef.current;
        if (!latest.active || !latest.connection?.active) return;
        const sequence = nextSequence.current;
        await latest.connection.call("axo.remote.terminal.input", {
          target: latest.connection.reference,
          sessionId: session.sessionId,
          shellId,
          sequence,
          data: encoded,
        });
        nextSequence.current = sequence + 1;
        storeNextSequence(storageKey, nextSequence.current);
      }).catch((error: unknown) => {
        propsRef.current.onInputError(error);
      });
    });

    let resizeTimer: number | undefined;
    const sendResize = () => {
      if (resizeTimer !== undefined) window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(() => {
        const current = propsRef.current;
        if (!current.active || !current.connection?.active) return;
        void current.connection.call("axo.remote.terminal.resize", {
          target: current.connection.reference,
          sessionId: session.sessionId,
          shellId,
          rows: Math.max(1, terminal.rows),
          columns: Math.max(1, terminal.cols),
        }).catch((error: unknown) => current.onInputError(error));
      }, 120);
    };
    const resizeListener = terminal.onResize(sendResize);
    let fitFrame: number | null = null;
    const scheduleFit = () => {
      if (fitFrame !== null) return;
      fitFrame = window.requestAnimationFrame(() => {
        fitFrame = null;
        try {
          fit.fit();
        } catch {
          // The terminal container can briefly be zero-sized during session changes.
        }
      });
    };
    const observer = new ResizeObserver(scheduleFit);
    observer.observe(node);
    scheduleFit();

    const focusListener = () => propsRef.current.onFocus();
    node.addEventListener("focusin", focusListener);
    const clickListener = () => onFocus();
    node.addEventListener("pointerdown", clickListener);

    return () => {
      if (fitFrame !== null) window.cancelAnimationFrame(fitFrame);
      if (resizeTimer !== undefined) window.clearTimeout(resizeTimer);
      observer.disconnect();
      resizeListener.dispose();
      node.removeEventListener("focusin", focusListener);
      node.removeEventListener("pointerdown", clickListener);
      if (registry.get(keyFor(session.sessionId, shellId)) === terminal) {
        registry.delete(keyFor(session.sessionId, shellId));
      }
      terminal.dispose();
      terminalRef.current = null;
    };
  }, [hostGeneration, registry, session.sessionId, shellId]);

  useEffect(() => {
    if (!active || !connection?.active || !terminalRef.current) return;
    const terminal = terminalRef.current;
    void connection.call("axo.remote.terminal.resize", {
      target: connection.reference,
      sessionId: session.sessionId,
      shellId,
      rows: Math.max(1, terminal.rows),
      columns: Math.max(1, terminal.cols),
    }).catch(onInputError);
  }, [active, connection, onInputError, session.sessionId, shellId]);

  return (
    <section className={`terminal-pane ${focused ? "focused" : ""}`} aria-label={`Terminal shell ${shellId}`}>
      <div className="pane-toolbar" onPointerDown={onFocus}>
        <span className={`activity-dot activity-${activity}`} />
        <span className="pane-title">Shell {shellId}</span>
        <span className="pane-activity">{activity === "unknown" ? "terminal" : activity}</span>
      </div>
      <div className="terminal-output" ref={element} />
      {!active ? <div className="pane-readonly-overlay" aria-hidden="true" /> : null}
    </section>
  );
}
