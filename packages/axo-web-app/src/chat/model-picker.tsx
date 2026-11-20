import { useEffect, useLayoutEffect, useId, useMemo, useRef, useState, type KeyboardEvent } from "react";
import type { PiModel, ThinkingLevel } from "@axo/protocol";
import { Icon } from "./icons.tsx";
import { levelName, levelsOf, matchingModels, modelsByProvider } from "./pi-controls.ts";
import type { ChatWorkbench, Session } from "./workbench.ts";

type Choice = { kind: "model"; model: PiModel } | { kind: "thinking"; level: ThinkingLevel };

/** Two independent selections. The catalog is a searchable drill-down, never above Thinking. */
export function ModelPicker({ workbench, session, disabled }: { workbench: ChatWorkbench; session: Session | null; disabled: boolean }) {
  const [open, setOpen] = useState(false);
  const [page, setPage] = useState<"settings" | "models">("settings");
  const [query, setQuery] = useState("");
  const [highlighted, setHighlighted] = useState(0);
  const [pending, setPending] = useState<Choice | null>(null);
  const [error, setError] = useState<string | null>(null);
  const root = useRef<HTMLDivElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const modelRow = useRef<HTMLButtonElement>(null);
  const search = useRef<HTMLInputElement>(null);
  const scope = session?.sessionId ?? workbench.draftCatalogScope;
  const activeScope = useRef(scope);
  activeScope.current = scope;
  const listId = useId();
  const draft = session ? undefined : workbench.draftModelChoice;
  const catalogOnly = !session && workbench.newChatAgent === "claude-code";
  const current = session?.pi?.model ?? draft?.model;
  const label = current?.name ?? (session ? "Model" : "Host default");
  const state = session ? workbench.chat(session.sessionId).models : workbench.draftModels;
  const loadModels = () => session ? workbench.loadModels(session.sessionId) : workbench.loadDraftModels();
  const models = state?.kind === "loaded" ? state.items : [];
  const groups = useMemo(() => modelsByProvider(matchingModels(models, query)), [models, query]);
  const choices = groups.flatMap(group => group.models);
  const active = Math.min(highlighted, Math.max(0, choices.length - 1));
  const levels = session ? levelsOf(models, session.pi) : draft?.model.thinkingLevels ?? [];
  const thinking = pending?.kind === "thinking" ? pending.level : session?.pi?.thinkingLevel ?? draft?.thinkingLevel;
  const optionId = (index: number) => `${listId}-model-${index}`;

  useLayoutEffect(() => {
    setOpen(false);
    setPending(null);
    setError(null);
  }, [scope]);
  useLayoutEffect(() => {
    if (!open) return;
    const place = () => {
      const menu = panel.current;
      const anchor = trigger.current;
      if (!menu || !anchor) return;
      const viewport = window.visualViewport;
      const left = viewport?.offsetLeft ?? 0;
      const top = viewport?.offsetTop ?? 0;
      const width = viewport?.width ?? window.innerWidth;
      menu.style.maxWidth = `${width - 16}px`;
      menu.style.maxHeight = `${Math.max(100, Math.min(480, anchor.getBoundingClientRect().top - top - 12))}px`;
      menu.style.transform = "none";
      const rect = menu.getBoundingClientRect();
      const clamped = Math.max(left + 8, Math.min(rect.left, left + width - rect.width - 8));
      menu.style.transform = `translateX(${clamped - rect.left}px)`;
    };
    place();
    window.addEventListener("resize", place);
    window.visualViewport?.addEventListener("resize", place);
    window.visualViewport?.addEventListener("scroll", place);
    return () => {
      window.removeEventListener("resize", place);
      window.visualViewport?.removeEventListener("resize", place);
      window.visualViewport?.removeEventListener("scroll", place);
    };
  }, [open, page]);
  useEffect(() => {
    if (!open) return;
    if (page === "models") search.current?.focus({ preventScroll: true });
    else modelRow.current?.focus({ preventScroll: true });
  }, [open, page]);
  useEffect(() => {
    if (open && page === "models" && choices.length)
      document.getElementById(optionId(active))?.scrollIntoView({ block: "nearest" });
  }, [open, page, active, query]);
  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => { if (!root.current?.contains(event.target as Node)) setOpen(false); };
    const escape = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      event.preventDefault();
      if (page === "models") setPage("settings");
      else { setOpen(false); trigger.current?.focus({ preventScroll: true }); }
    };
    window.addEventListener("pointerdown", outside);
    window.addEventListener("keydown", escape);
    return () => { window.removeEventListener("pointerdown", outside); window.removeEventListener("keydown", escape); };
  }, [open, page]);

  const choose = async (choice: Choice) => {
    if (disabled || pending || catalogOnly) return;
    if (!session) {
      const model = choice.kind === "model" ? choice.model : draft?.model;
      const level = choice.kind === "thinking" ? choice.level
        : draft?.thinkingLevel && model?.thinkingLevels.includes(draft.thinkingLevel) ? draft.thinkingLevel : undefined;
      if (workbench.chooseDraftModel(scope, model, level)) setPage("settings");
      return;
    }
    setPending(choice);
    setError(null);
    try {
      const applied = await workbench.setModel(session.sessionId, choice.kind === "model"
        ? { model: { provider: choice.model.provider, id: choice.model.id } }
        : { thinkingLevel: choice.level });
      if (activeScope.current !== scope) return;
      if (applied) setPage("settings");
      else setError(workbench.failure ?? "Could not update this agent. Try again.");
    } finally {
      if (activeScope.current === scope) setPending(null);
    }
  };
  const chooseModel = (model: PiModel) => {
    if (current?.provider === model.provider && current.id === model.id) setPage("settings");
    else void choose({ kind: "model", model });
  };
  const searchKeys = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      setHighlighted(Math.max(0, Math.min(choices.length - 1, active + (event.key === "ArrowDown" ? 1 : -1))));
    } else if (event.key === "Enter") {
      event.preventDefault(); // The search lives inside the composer form: never send its draft.
      if (choices[active]) chooseModel(choices[active]);
    }
  };
  if (session && !session.pi?.model && !session.agent) return null;

  return (
    <div className="model-picker" ref={root}>
      <button type="button" className="model-picker-button" disabled={disabled}
        aria-haspopup="dialog" aria-expanded={open && page === "models"} aria-label={`Model: ${label}`} title="Choose model"
        onClick={event => {
          trigger.current = event.currentTarget;
          setPage("models"); setQuery(""); setError(null); void loadModels();
          setOpen(!open || page !== "models");
        }}>
        <span className="model-picker-label">{label}</span><Icon name="chevronDown" size={11} />
      </button>
      <button type="button" className="model-picker-button thinking-picker-button" disabled={disabled}
        aria-haspopup="dialog" aria-expanded={open && page === "settings"}
        aria-label={`Thinking: ${thinking ? levelName(thinking) : "Default"}`} title="Choose thinking level"
        onClick={event => {
          trigger.current = event.currentTarget;
          setPage("settings"); setError(null);
          void loadModels();
          setOpen(!open || page !== "settings");
        }}>
        <span className="model-picker-label"><span className="thinking-full">{thinking ? levelName(thinking) : "Thinking"}</span><span className="thinking-short">{thinking === "medium" ? "Med" : thinking === "minimal" ? "Min" : thinking === "xhigh" ? "XHigh" : thinking ? levelName(thinking) : "Think"}</span></span><Icon name="chevronDown" size={11} />
      </button>
      {open ? (
        <div ref={panel} className="host-menu model-menu" role="dialog" aria-label="Model settings" aria-busy={Boolean(pending)}>
          {page === "settings" ? (
            <>
              <button ref={modelRow} type="button" className="model-setting-row" aria-label="Choose model" aria-describedby={`${listId}-current`} disabled={Boolean(pending)}
                onClick={() => { setQuery(""); setHighlighted(0); setPage("models"); }}>
                <span className="model-setting-name">Model</span>
                <span className="model-setting-value" id={`${listId}-current`}><strong title={current?.id}>{current?.name ?? label}</strong><small>{current?.provider}</small></span>
                <Icon name="chevronRight" size={14} />
              </button>
              <div className="thinking-setting">
                <p className="model-setting-heading">Thinking</p>
                {state?.kind === "loaded" ? levels.length > 1 ? (
                  <div className="thinking-options" role="radiogroup" aria-label="Thinking level" aria-busy={Boolean(pending)}>
                    {levels.map(level => (
                      <label key={level} className="thinking-option" title={levelName(level)}>
                        <input type="radio" name={`${listId}-thinking`} value={level} checked={thinking === level} disabled={disabled}
                          onKeyDown={event => { if (event.key === "Enter") event.preventDefault(); }}
                          onChange={() => { if (level !== thinking) void choose({ kind: "thinking", level }); }} />
                        <span>{levelName(level)}</span>
                      </label>
                    ))}
                  </div>
                ) : <p className="menu-note">{levels[0] ? levelName(levels[0]) : "Not available for this model"}</p>
                  : <CatalogStatus state={state} retry={() => void loadModels()} />}
              </div>
            </>
          ) : (
            <>
              <div className="model-search-header">
                <button type="button" className="plain-icon-button" aria-label="Back to model settings" onClick={() => setPage("settings")}><Icon name="chevronLeft" size={18} /></button>
                <input ref={search} type="search" role="combobox" aria-label="Search models" placeholder="Search model or provider"
                  aria-autocomplete="list" aria-expanded="true" aria-controls={listId} aria-activedescendant={choices.length ? optionId(active) : undefined}
                  autoComplete="off" autoCapitalize="off" spellCheck={false} maxLength={128} value={query}
                  onChange={event => { setQuery(event.target.value); setHighlighted(0); }} onKeyDown={searchKeys} />
              </div>
              {catalogOnly ? <p className="menu-note">Claude Code’s advertised models. Choose the model in Claude Code.</p> : null}
              {!session && !catalogOnly ? <button type="button" className="model-setting-row" onClick={() => {
                if (workbench.chooseDraftModel(scope)) setPage("settings");
              }}>Use host default</button> : null}
              <div className="model-results" role="listbox" aria-label="Models" id={listId}>
                {state?.kind === "loaded" ? groups.length ? groups.map(group => (
                  <div key={group.provider} role="group" aria-label={group.provider}>
                    <p className="menu-section">{group.provider}</p>
                    {group.models.map(model => {
                      const index = choices.indexOf(model);
                      const selected = current?.provider === model.provider && current.id === model.id;
                      return (
                        <button id={optionId(index)} key={model.id} type="button" role="option" tabIndex={-1} aria-selected={selected}
                          disabled={Boolean(pending) || catalogOnly} className={index === active ? "host-menu-item highlighted" : "host-menu-item"}
                          onPointerDown={event => event.preventDefault()} onPointerEnter={() => setHighlighted(index)} onClick={() => chooseModel(model)}>
                          <span className="menu-check">{selected ? <Icon name="check" size={14} /> : null}</span>
                          <span className="host-picker-label">{model.name}<small className="model-id">{model.id}</small></span>
                        </button>
                      );
                    })}
                  </div>
                )) : <p className="menu-note">No models match “{query}”.</p>
                  : <CatalogStatus state={state} retry={() => void loadModels()} />}
              </div>
              {state?.kind === "loaded" ? <p className="model-result-count" role="status">{choices.length} {choices.length === 1 ? "model" : "models"}</p> : null}
            </>
          )}
          {pending ? <p className="menu-note" role="status"><span className="spinner" />{pending.kind === "model" ? "Changing model…" : "Changing thinking level…"}</p> : null}
          {error ? <p className="menu-note warning" role="alert">{error}</p> : null}
        </div>
      ) : null}
    </div>
  );
}

function CatalogStatus({ state, retry }: { state: ReturnType<ChatWorkbench["chat"]>["models"]; retry: () => void }) {
  return state?.kind === "failed"
    ? <p className="menu-note warning"><span>Could not read models: {state.message}</span> <button type="button" className="link" onClick={retry}>Try again</button></p>
    : <p className="menu-note"><span className="spinner" />Reading models…</p>;
}
