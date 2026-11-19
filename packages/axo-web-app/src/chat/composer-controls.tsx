import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { PiCommand } from "@axo/protocol";
import { Icon } from "./icons.tsx";
import type { Delivery } from "./transcript.ts";
import type { Loadable } from "./workbench.ts";

/** Closes a popover on a press outside `root`, or on Escape. */
function useDismiss(open: boolean, root: React.RefObject<HTMLElement | null>, close: () => void): void {
  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => { if (!root.current?.contains(event.target as Node)) close(); };
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      close();
    };
    window.addEventListener("pointerdown", outside);
    window.addEventListener("keydown", escape);
    return () => { window.removeEventListener("pointerdown", outside); window.removeEventListener("keydown", escape); };
  }, [open]);
}

function LoadableNote({ state, what }: { state: Loadable<unknown> | null; what: string }) {
  if (!state || state.kind === "loading") return <p className="menu-note"><span className="spinner" aria-hidden="true" /> Reading available {what}…</p>;
  if (state.kind === "failed") return <p className="menu-note warning">Could not read the {what}: {state.message}</p>;
  return state.items.length ? null : <p className="menu-note">No {what} available for this agent.</p>;
}

/**
 * The `/` list above the box: the commands the chat's Pi runs when sent, as Pi lists them, narrowed
 * by what follows the `/`. Arrow keys move, Enter or Tab picks, Escape closes; the box keeps focus.
 */
export function SlashMenu({ state, matches, highlighted, onPick, onHighlight }: {
  state: Loadable<PiCommand> | null;
  matches: readonly PiCommand[];
  highlighted: number;
  onPick: (command: PiCommand) => void;
  onHighlight: (index: number) => void;
}) {
  const loaded = state?.kind === "loaded";
  const list = useRef<HTMLDivElement>(null);
  const matchNames = JSON.stringify(matches.map(command => command.name));
  useLayoutEffect(() => {
    const menu = list.current;
    if (!menu) return;
    const place = () => {
      const viewportTop = window.visualViewport?.offsetTop ?? 0;
      menu.style.maxHeight = `${Math.max(0, Math.min(320, menu.getBoundingClientRect().bottom - viewportTop - 12))}px`;
    };
    place();
    const observer = new ResizeObserver(place);
    if (menu.parentElement) observer.observe(menu.parentElement);
    window.addEventListener("resize", place);
    window.visualViewport?.addEventListener("resize", place);
    window.visualViewport?.addEventListener("scroll", place);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", place);
      window.visualViewport?.removeEventListener("resize", place);
      window.visualViewport?.removeEventListener("scroll", place);
    };
  }, []);
  useLayoutEffect(() => {
    list.current?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [highlighted, matchNames]);
  return (
    <div ref={list} className="slash-menu" role="listbox" aria-label="Commands" id="slash-menu">
      {!loaded ? <LoadableNote state={state} what="commands" /> : !matches.length ? <p className="menu-note">No matching commands for this agent.</p> : null}
      {matches.map((command, index) => (
        <button key={command.name} type="button" role="option" id={`slash-${index}`} aria-selected={index === highlighted}
          className={index === highlighted ? "slash-row highlighted" : "slash-row"}
          // The box keeps focus, so typing carries on.
          onPointerDown={event => event.preventDefault()}
          onPointerMove={event => { if (event.pointerType === "mouse") onHighlight(index); }}
          onClick={() => onPick(command)}>
          <span className="slash-name" title={`/${command.name}`}>/{command.name}</span>
          <span className="slash-description" title={command.description}>{command.description}</span>
        </button>
      ))}
    </div>
  );
}

const HOLD_MS = 400;

/**
 * Send. A tap sends now: a working agent stops its reply and answers this. Holding it (or a
 * right-click) offers the gentler ways: Steer, read at the agent's next step, and Follow up, after
 * its reply. ⌘↵ and ⌥↵ do the same from the keyboard.
 *
 * The press keeps the focus in the box, so a phone's keyboard stays up and the button does not move
 * from under the finger while it is held; the pointer is captured for the same reason.
 */
export function SendButton({ ready, onSend }: { ready: boolean; onSend: (delivery: Delivery) => void }) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  /** The press opened the menu, so letting go sends nothing. */
  const held = useRef(false);
  useDismiss(open, root, () => setOpen(false));
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);
  const release = () => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
  };
  const choose = (delivery: Delivery) => {
    setOpen(false);
    onSend(delivery);
  };
  const openMenu = () => {
    release();
    held.current = true;
    setOpen(true);
  };
  return (
    <div className="send-anchor" ref={root}>
      <button type="button" className={ready ? "round-button send-button ready" : "round-button send-button"} disabled={!ready}
        aria-label="Send" aria-haspopup="menu" aria-expanded={open} title="Send now · hold to steer or follow up"
        onPointerDown={event => {
          if (event.button !== 0) return;
          // The box keeps the focus: no keyboard closing, nothing moving under the finger.
          event.preventDefault();
          event.currentTarget.setPointerCapture?.(event.pointerId);
          held.current = false;
          release();
          timer.current = setTimeout(openMenu, HOLD_MS);
        }}
        onPointerUp={release} onPointerCancel={release}
        onContextMenu={event => {
          event.preventDefault();
          openMenu();
        }}
        onClick={() => {
          if (held.current) {
            held.current = false;
            return;
          }
          onSend("interrupt");
        }}>
        <Icon name="arrowUp" size={20} />
      </button>
      {open ? (
        <div className="add-menu send-menu" role="menu" aria-label="Send as">
          <button type="button" role="menuitem" className="add-menu-item" autoFocus onClick={() => choose("steer")}>
            <span className="add-menu-well"><Icon name="sparkles" size={18} /></span>
            <span className="send-menu-text">Steer<small>At the agent's next step</small></span>
            <kbd>⌘↵</kbd>
          </button>
          <button type="button" role="menuitem" className="add-menu-item" onClick={() => choose("followUp")}>
            <span className="add-menu-well"><Icon name="arrowDown" size={18} /></span>
            <span className="send-menu-text">Follow up<small>After the current reply</small></span>
            <kbd>⌥↵</kbd>
          </button>
        </div>
      ) : null}
    </div>
  );
}
