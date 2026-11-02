import { ClipboardText } from "@cloudflare/kumo";

export function CopyText({ text }: { text: string }) {
  return <ClipboardText text={text} size="sm" className="max-w-full" />;
}
