import { useEffect, useRef, useState } from "react";

/** The parts of the Web Speech API dictation uses; Safari and Chrome name it differently. */
interface SpeechRecognitionLike {
  lang: string;
  continuous: boolean;
  interimResults: boolean;
  onresult: ((event: { resultIndex: number; results: ArrayLike<ArrayLike<{ transcript: string }> & { isFinal: boolean }> }) => void) | null;
  onerror: ((event: { error: string }) => void) | null;
  onend: (() => void) | null;
  start(): void;
  stop(): void;
  abort(): void;
}
type SpeechRecognitionConstructor = new () => SpeechRecognitionLike;

function recognizer(): SpeechRecognitionConstructor | null {
  const scope = window as unknown as { SpeechRecognition?: SpeechRecognitionConstructor; webkitSpeechRecognition?: SpeechRecognitionConstructor };
  return scope.SpeechRecognition ?? scope.webkitSpeechRecognition ?? null;
}

export type Dictation = {
  /** Whether this browser can listen at all. */
  readonly supported: boolean;
  readonly listening: boolean;
  /** Why listening stopped early, in words for the person; null when it did not. */
  readonly failure: string | null;
  /** Starts listening, adding what is said after `before`; or stops. */
  toggle(before: string): void;
  stop(): void;
};

const failures: Record<string, string> = {
  "not-allowed": "Allow the microphone for this site to dictate.",
  "service-not-allowed": "This browser does not allow dictation here.",
  "audio-capture": "No microphone found.",
  network: "Dictation needs a network connection.",
};

/** Joins dictated words onto what was typed, with one space between. */
export function withDictated(before: string, said: string): string {
  const words = said.trim();
  if (!words) return before;
  return before && !/\s$/.test(before) ? `${before} ${words}` : `${before}${words}`;
}

/**
 * Dictation into the message box, with the browser's speech recognition: what is said goes in as
 * it is heard and is corrected as the browser settles on it. Nothing is sent on its own.
 */
export function useDictation(onText: (text: string) => void): Dictation {
  const Recognition = recognizer();
  const [listening, setListening] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const active = useRef<SpeechRecognitionLike | null>(null);
  const write = useRef(onText);
  write.current = onText;

  useEffect(() => () => active.current?.abort(), []);

  const stop = () => active.current?.stop();

  const toggle = (before: string) => {
    if (active.current) {
      stop();
      return;
    }
    if (!Recognition) return;
    const recognition = new Recognition();
    recognition.lang = navigator.language || "en-US";
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.onresult = event => {
      let said = "";
      for (let index = 0; index < event.results.length; index += 1) said += event.results[index]![0]!.transcript;
      write.current(withDictated(before, said));
    };
    recognition.onerror = event => {
      if (event.error !== "aborted" && event.error !== "no-speech") setFailure(failures[event.error] ?? `Dictation stopped (${event.error}).`);
    };
    recognition.onend = () => {
      if (active.current === recognition) active.current = null;
      setListening(false);
    };
    active.current = recognition;
    setFailure(null);
    setListening(true);
    try {
      recognition.start();
    } catch (error) {
      active.current = null;
      setListening(false);
      setFailure(error instanceof Error ? error.message : "Could not start dictation.");
    }
  };

  return { supported: Recognition !== null, listening, failure, toggle, stop };
}
