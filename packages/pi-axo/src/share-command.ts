import { chmod, mkdir, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { AxodCallError, callAxod } from "./axod-client.js";
import {
  buildSharedMessages,
  parseFindings,
  redactSnapshot,
  REDACTOR_SYSTEM_PROMPT,
  slugify,
  SNAPSHOT_VERSION,
  TRIAGE_INSTRUCTIONS,
  type RedactionModels,
  type RedactionReport,
  type SharedSnapshot,
} from "./share.js";

export const SHARE_ENTRY = "axo_session_share";
const SHARE_METHOD = "axo.session.share";
/** Axod waits up to 60 seconds for the cloud; leave it room to answer. */
const PUBLISH_TIMEOUT_MS = 75_000;
const SHARE_ID = /^[A-Za-z0-9_-]{22}$/;
/** The relay carries messages up to 2 MiB; leave room for the envelope. */
const MAX_SNAPSHOT_BYTES = 1_900_000;

type Registry = ExtensionCommandContext["modelRegistry"];
type ChatModel = NonNullable<ExtensionCommandContext["model"]>;
type ClassifierModel = Parameters<Registry["classify"]>[0];

/** "provider/model-id"; model IDs may themselves contain slashes. */
function splitModelRef(value: string | undefined): { provider: string; id: string } | null {
  if (!value) return null;
  const slash = value.indexOf("/");
  return slash > 0 && slash < value.length - 1 ? { provider: value.slice(0, slash), id: value.slice(slash + 1) } : null;
}

/** The cheapest Clef with working credentials: Clef Flash before Clef, never Omni. */
export async function pickClassifier(registry: Registry): Promise<ClassifierModel | null> {
  const override = splitModelRef(process.env.AXO_SHARE_CLASSIFIER);
  if (override) return registry.getModelOfType("classifier", override.provider, override.id) ?? null;
  const available = await registry.getAvailableOfType("classifier");
  return available.find(model => /clef-flash/i.test(model.id))
    ?? available.find(model => /clef(?!-omni)/i.test(model.id))
    ?? null;
}

/** A Haiku with working credentials, preferring the current model's provider and the newest version. */
export async function pickRedactor(registry: Registry, current: ChatModel | undefined): Promise<ChatModel | null> {
  const override = splitModelRef(process.env.AXO_SHARE_REDACTOR);
  if (override) return registry.find(override.provider, override.id) ?? null;
  const haikus = [...await registry.getAvailableOfType("chat")]
    .filter(model => /haiku/i.test(model.id) && !/batch/i.test(model.id))
    .sort((a, b) => {
      const sameProvider = Number(b.provider === current?.provider) - Number(a.provider === current?.provider);
      return sameProvider || b.id.localeCompare(a.id, undefined, { numeric: true });
    });
  return haikus[0] ?? null;
}

export function redactionModels(registry: Registry, classifier: ClassifierModel | null, redactor: ChatModel, signal: AbortSignal): RedactionModels {
  return {
    async triage(text) {
      if (!classifier) return null;
      const result = await registry.classify(classifier, {
        state: { text },
        questions: {
          sensitive: {
            type: "bool",
            instructions: TRIAGE_INSTRUCTIONS,
            criteria: { true: "Publishing it would expose sensitive information", false: "Safe to publish as is" },
          },
        },
      }, { signal });
      const answer = result.answers.sensitive;
      if (result.stopReason !== "stop" || answer?.type !== "bool") {
        throw new Error(`The classifier failed: ${result.errorMessage ?? result.stopReason}`);
      }
      return answer.probability;
    },
    async findSensitive(text) {
      const response = await registry.complete(redactor, {
        systemPrompt: REDACTOR_SYSTEM_PROMPT,
        messages: [{ role: "user", content: [{ type: "text", text }], timestamp: Date.now() }],
      }, { signal, cacheRetention: "none" });
      if (response.stopReason !== "stop") {
        throw new Error(`The redaction model failed: ${response.errorMessage ?? response.stopReason}`);
      }
      const answer = response.content.flatMap(block => block.type === "text" ? [block.text] : []).join("");
      return parseFindings(answer);
    },
  };
}

function describeReport(report: RedactionReport): string {
  const categories = Object.entries(report.categories).sort(([, a], [, b]) => b - a);
  const removed = categories.length === 0
    ? "nothing was redacted"
    : `${categories.reduce((sum, [, times]) => sum + times, 0)} redactions (${categories.map(([name, times]) => `${name} ×${times}`).join(", ")})`;
  const review = report.classifierUsed
    ? `Clef flagged ${report.fieldsSentToRedactor} of ${report.fieldsChecked} fields for the redaction model`
    : `the redaction model read all ${report.fieldsChecked} fields (no Clef classifier available)`;
  return `${removed}; ${review}`;
}

const SHARES_DIRECTORY = join(homedir(), ".axo", "shares");

async function writePrivately(path: string, contents: string): Promise<void> {
  await mkdir(SHARES_DIRECTORY, { recursive: true, mode: 0o700 });
  await writeFile(path, contents, { mode: 0o600 });
  await chmod(path, 0o600);
}

interface Published {
  shareId: string;
  url: string;
}

/**
 * Publishes through Axod, which forwards the snapshot over this Mac's relay link: the cloud
 * stores it under the Mac's Axo account and picks its ID. No Cloudflare credentials are needed.
 */
export async function publishThroughAxod(socket: string, snapshot: SharedSnapshot): Promise<Published> {
  const result = await callAxod(socket, SHARE_METHOD, { snapshot }, PUBLISH_TIMEOUT_MS) as Partial<Published> | null;
  if (typeof result?.shareId !== "string" || !SHARE_ID.test(result.shareId) || typeof result.url !== "string" || !result.url.startsWith("https://")) {
    throw new AxodCallError("Axo answered with an unexpected share", null);
  }
  return { shareId: result.shareId, url: result.url };
}

/**
 * `/axo-share [--dry-run]`: publish a redacted, read-only snapshot of this conversation.
 *
 * The snapshot is built and redacted on this Mac and saved under ~/.axo/shares for review. Only
 * after an explicit confirmation is it handed to Axod, which publishes it through this Mac's Axo
 * account. Stored session history is never involved.
 */
export function registerShareCommand(pi: ExtensionAPI): void {
  pi.registerCommand("axo-share", {
    description: "Publish a redacted, read-only copy of this conversation to axo.leostera.dev",
    handler: async (args, context) => {
      const dryRun = args.trim() === "--dry-run";
      if (args.trim() && !dryRun) {
        context.ui.notify("Usage: /axo-share [--dry-run]", "warning");
        return;
      }
      const socket = process.env.AXO_SOCKET;
      if (!socket) {
        context.ui.notify("Sharing works in Pi sessions that Axo runs.", "warning");
        return;
      }
      if (!context.hasUI) {
        console.error("/axo-share needs a UI to confirm publishing");
        return;
      }
      await context.waitForIdle();

      const messages = buildSharedMessages(context.sessionManager.getBranch());
      if (messages.length === 0) {
        context.ui.notify("There is nothing to share yet.", "warning");
        return;
      }
      const redactor = await pickRedactor(context.modelRegistry, context.model);
      if (!redactor) {
        context.ui.notify("Sharing needs a Haiku model with working credentials to redact the conversation.", "error");
        return;
      }
      const classifier = await pickClassifier(context.modelRegistry);

      const snapshot: SharedSnapshot = {
        version: SNAPSHOT_VERSION,
        title: pi.getSessionName() ?? "Shared Axo session",
        publishedAt: new Date().toISOString(),
        messages,
      };
      context.ui.notify(`Redacting ${messages.length} messages with ${classifier ? `${classifier.id} and ` : ""}${redactor.id}…`, "info");
      const abort = new AbortController();
      let report: RedactionReport;
      try {
        report = await redactSnapshot(snapshot, redactionModels(context.modelRegistry, classifier, redactor, abort.signal));
      } catch (error) {
        abort.abort();
        context.ui.notify(`Nothing was shared: redaction failed (${error instanceof Error ? error.message : String(error)}).`, "error");
        return;
      }

      const path = join(SHARES_DIRECTORY, `${snapshot.publishedAt.replace(/[:.]/g, "-")}-${slugify(snapshot.title)}.json`);
      await writePrivately(path, `${JSON.stringify(snapshot, null, 2)}\n`);

      const bytes = Buffer.byteLength(JSON.stringify(snapshot), "utf8");
      if (bytes > MAX_SNAPSHOT_BYTES) {
        context.ui.notify(`This conversation is too large to share (${Math.ceil(bytes / 1_048_576)} MB; the limit is under 2 MB). The redacted snapshot is at ${path}.`, "error");
        return;
      }
      if (dryRun) {
        context.ui.notify(`Dry run: ${describeReport(report)}. Review the redacted snapshot at ${path}.`, "info");
        return;
      }
      const confirmed = await context.ui.confirm(
        "Publish this conversation publicly?",
        `${messages.length} messages, ${describeReport(report)}.\n\nReview the redacted snapshot first: ${path}\n\nAnyone with the link will be able to read it.`,
      );
      if (!confirmed) {
        context.ui.notify(`Not published. The redacted snapshot stays at ${path}.`, "info");
        return;
      }

      let published: Published;
      try {
        published = await publishThroughAxod(socket, snapshot);
      } catch (error) {
        const reason = error instanceof Error ? error.message : String(error);
        context.ui.notify(`Not published: ${reason}. The redacted snapshot stays at ${path}.`, "error");
        return;
      }
      const { shareId, url } = published;
      await rename(path, join(SHARES_DIRECTORY, `${shareId}.json`)).catch(() => undefined);
      pi.appendEntry(SHARE_ENTRY, { shareId, url, publishedAt: snapshot.publishedAt });
      context.ui.notify(`Published: ${url}`, "info");
    },
  });
}
