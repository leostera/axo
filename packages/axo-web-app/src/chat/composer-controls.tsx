import { useEffect, useRef, useState } from "react";
import type { PiCommand } from "@axo/protocol";
import { Icon } from "./icons.tsx";
import { levelName, levelsOf, modelsByProvider, runtimeLabel } from "./pi-controls.ts";
import type { Delivery } from "./transcript.ts";
import type { ChatWorkbench, Loadable, Session } from "./workbench.ts";

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

/**
 * "Opus 4.1 · High" in the box: what the chat's Pi runs, as Pi last said. It opens a menu of the
 * models Pi has credentials for, by provider, and the thinking levels of the one it runs. Nothing
 * shows until Pi has said what it runs.
 */
export function ModelPicker({ workbench, session, disabled }: { workbench: ChatWorkbench; session: Session; disabled: boolean }) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  useDismiss(open, root, () => setOpen(false));
  const label = runtimeLabel(session.pi);
  if (!label) return null;
  const chat = workbench.chat(session.sessionId);
  const models = chat.models;
  const pick = (change: Parameters<ChatWorkbench["setModel"]>[1]) => {
    setOpen(false);
    void workbench.setModel(session.sessionId, change);
  };
  const current = session.pi?.model;
  return (
    <div className="model-picker" ref={root}>
      <button type="button" className="model-picker-button" disabled={disabled} aria-haspopup="menu" aria-expanded={open}
        aria-label={`Model: ${label}`} title="Choose the model and how hard it thinks" onClick={() => {
          if (!open) void workbench.loadModels(session.sessionId);
          setOpen(!open);
        }}>
        <span className="model-picker-label">{label}</span>
        <Icon name="chevronDown" size={11} />
      </button>
      {open ? (
        <div className="host-menu model-menu" role="menu" aria-label="Model">
          <LoadableNote state={models} what="models" />
          {models?.kind === "loaded" ? (
            <>
              {modelsByProvider(models.items).map(group => (
                <div key={group.provider} role="group" aria-label={group.provider}>
                  <p className="menu-section">{group.provider}</p>
                  {group.models.map(model => {
                    const chosen = current?.provider === model.provider && current.id === model.id;
                    return (
                      <button key={model.id} type="button" role="menuitemradio" aria-checked={chosen} className="host-menu-item"
                        onClick={() => chosen ? setOpen(false) : pick({ model: { provider: model.provider, id: model.id } })}>
                        <span className="menu-check">{chosen ? <Icon name="check" size={14} /> : null}</span>
                        <span className="host-picker-label">{model.name}</span>
                      </button>
                    );
                  })}
                </div>
              ))}
              {levelsOf(models.items, session.pi).length > 1 ? (
                <div role="group" aria-label="Thinking">
                  <p className="menu-section">Thinking</p>
                  {levelsOf(models.items, session.pi).map(level => {
                    const chosen = session.pi?.thinkingLevel === level;
                    return (
                      <button key={level} type="button" role="menuitemradio" aria-checked={chosen} className="host-menu-item"
                        onClick={() => chosen ? setOpen(false) : pick({ thinkingLevel: level })}>
                        <span className="menu-check">{chosen ? <Icon name="check" size={14} /> : null}</span>
                        {levelName(level)}
                      </button>
                    );
                  })}
                </div>
              ) : null}
            </>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function LoadableNote({ state, what }: { state: Loadable<unknown> | null; what: string }) {
  if (!state || state.kind === "loading") return <p className="menu-note"><span className="spinner" aria-hidden="true" /> Asking Pi for its {what}…</p>;
  if (state.kind === "failed") return <p className="menu-note warning">Could not read the {what}: {state.message}</p>;
  return state.items.length ? null : <p className="menu-note">Pi has no {what} to offer.</p>;
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
  return (
    <div className="slash-menu" role="listbox" aria-label="Commands" id="slash-menu">
      {!loaded ? <LoadableNote state={state} what="commands" /> : !matches.length ? <p className="menu-note">No command by that name.</p> : null}
      {matches.map((command, index) => (
        <button key={command.name} type="button" role="option" id={`slash-${index}`} aria-selected={index === highlighted}
          className={index === highlighted ? "slash-row highlighted" : "slash-row"}
          // The box keeps focus, so typing carries on.
          onPointerDown={event => event.preventDefault()}
          onPointerEnter={() => onHighlight(index)}
          onClick={() => onPick(command)}>
          <span className="slash-name">/{command.name}</span>
          <span className="slash-description">{command.description}</span>
          <small className="slash-source">{sourceNames[command.source]}</small>
        </button>
      ))}
    </div>
  );
}

const sourceNames: Record<PiCommand["source"], string> = { extension: "Command", prompt: "Prompt", skill: "Skill" };

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
