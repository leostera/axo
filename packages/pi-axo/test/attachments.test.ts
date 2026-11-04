import assert from "node:assert/strict";
import test from "node:test";
import { attachmentLine, MAX_INLINE_IMAGE_BYTES, parseAttachments, promptContent, showAttachmentLines, type PromptAttachment } from "../src/attachments.js";
import { parsePiControlCommand } from "../src/protocol.js";

const sessionId = "82cfd1e8-1cc6-4473-a16d-6f0e77476311";
const asset = `sha256:${"ab".repeat(32)}`;
const photo: PromptAttachment = { path: "/Users/leo/.axo/assets/ab/whiteboard.jpg", asset, name: "whiteboard.jpg", mimeType: "image/jpeg", size: 1234 };
const pdf: PromptAttachment = { path: "/Users/leo/.axo/assets/cd/invoice.pdf", asset, name: "invoice.pdf", mimeType: "application/pdf", size: 3 * 1024 * 1024 };

test("a send with attachments parses, and may have no text", () => {
  const parsed = parsePiControlCommand({
    type: "command",
    requestId: "request-1",
    axoSessionId: sessionId,
    action: { kind: "send", text: "", commandId: "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b", attachments: [photo] },
  }, sessionId);
  assert.ok(parsed.ok);
  assert.deepEqual(parsed.command.action, { kind: "send", text: "", commandId: "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b", attachments: [photo] });
});

test("a send with neither text nor attachments, or a malformed attachment, is refused", () => {
  const send = (action: Record<string, unknown>) => parsePiControlCommand({ type: "command", requestId: "r", axoSessionId: sessionId, action: { kind: "send", ...action } }, sessionId);
  assert.equal(send({ text: "" }).ok, false);
  assert.equal(send({ text: "", attachments: [] }).ok, false);
  assert.equal(send({ text: "x", attachments: [{ ...photo, path: "relative/whiteboard.jpg" }] }).ok, false);
  assert.equal(send({ text: "x", attachments: [{ ...photo, asset: "sha256:XYZ" }] }).ok, false);
  assert.equal(send({ text: "x", attachments: [{ ...photo, name: "../x" }] }).ok, false);
  assert.equal(send({ text: "x", attachments: [{ ...photo, extra: 1 }] }).ok, false);
  assert.equal(send({ text: "x", attachments: Array(9).fill(photo) }).ok, false);
  assert.deepEqual(parseAttachments(Array(8).fill(photo))?.length, 8);
});

test("text alone stays text, as before", () => {
  assert.equal(promptContent("hello", []), "hello");
});

test("an image the model can take becomes an image block, and the agent still learns where it is", () => {
  const content = promptContent("what does this say?", [photo], () => Buffer.from("jpeg bytes"));
  assert.deepEqual(content, [
    { type: "text", text: `what does this say?\n\n[Attached image: whiteboard.jpg at ${photo.path} axo-asset:${asset}]` },
    { type: "image", data: Buffer.from("jpeg bytes").toString("base64"), mimeType: "image/jpeg" },
  ]);
});

test("other files, and images too large to inline, become a line with their path, and are never read", () => {
  const huge = { ...photo, size: MAX_INLINE_IMAGE_BYTES + 1 };
  const content = promptContent("", [pdf, huge], () => assert.fail("only inline images are read"));
  assert.deepEqual(content, [{ type: "text", text: `${attachmentLine(pdf)}\n\n${attachmentLine(huge)}` }]);
  assert.match(attachmentLine(pdf), /^\[Attached file: invoice\.pdf \(application\/pdf, 3\.0 MB\) at \/Users\/leo\/\.axo\/assets\/cd\/invoice\.pdf axo-asset:sha256:(ab){32}\]$/u);
});

test("an image that can't be read fails the whole prompt", () => {
  assert.throws(() => promptContent("x", [photo, pdf], () => { throw new Error("ENOENT"); }));
});

test("in the terminal each attachment line is one short line; everything else is left alone", () => {
  const content = promptContent("look at these", [photo, pdf], () => Buffer.from("jpeg"));
  const text = (content as Array<{ type: string; text?: string }>)[0]!.text!;
  assert.equal(showAttachmentLines(text), "look at these\n\n🖼  whiteboard.jpg\n\n📎 invoice.pdf · 3.0 MB");
  assert.equal(showAttachmentLines("[Attached image: not ours]"), "[Attached image: not ours]");
});
