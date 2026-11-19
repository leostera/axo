import type { Elicitation, InputRequest } from "@axo/protocol";
import { questionDigest } from "./content";

/** Only a complete, short, single non-secret text field may leave the app UI. */
export function notificationTextInput(question: Elicitation): { input: InputRequest; body: string; binding: string } | null {
  const input = question.input;
  if (question.kind !== "input" || !input || input.fields.length !== 1 || input.fields[0]!.kind !== "text") return null;
  const field = input.fields[0]!;
  const body = [question.message, `${input.app} · ${input.window}`, input.origin,
    field.label, input.submit ? `Then: ${input.submit}` : undefined].filter(value => value !== undefined && value !== "").join("\n");
  if (Array.from(body).length > 140) return null;
  // UTF-8 byte-length prefixes avoid JSON escaping/ordering differences with Swift.
  // Bind every target attribute, including the encryption key and optional submit action.
  const parts = ["axo.notification.text-input/v1", question.message, input.app, input.window,
    input.origin === undefined ? "0" : "1" + input.origin, field.id, field.label, field.kind,
    input.submit === undefined ? "0" : "1" + input.submit, input.key];
  const binding = parts.map(value => `${new TextEncoder().encode(value).length}:${value}`).join("");
  return { input, body, binding };
}

export const textInputDigest = (input: NonNullable<ReturnType<typeof notificationTextInput>>) => questionDigest(input.binding);
