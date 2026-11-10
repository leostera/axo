// The tools the agent uses, in Chrome against a fake cloud: each is a row saying what it works on,
// those used one after another are one block headed by what they did, a running one shows what it
// runs and what it prints, and any opens to all it was given and all it printed so far.
//
// AXO_WEB_SHOTS=<dir> also saves screenshots there.
import assert from "node:assert/strict";
import { existsSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { test } from "node:test";
import { chromePath, hostId, listed, record, sid, sleep, startApp, startCloud } from "./fake-cloud.mjs";

const chat = sid(1);
const script = "const files = await tools.bash({ command: \"ls\" });\nconst text = files.output;\nreturn text.split(\"\\n\").length;\n// and more";

function transcript() {
  return [
    record(1, { role: "user", content: [{ type: "text", text: "Build the login." }] }),
    record(2, {
      role: "assistant", timestamp: 1_700_000_000_001, content: [
        { type: "text", text: "I’ll look first." },
        { type: "toolCall", id: "t-read", name: "read", arguments: { path: "src/login.ts", offset: 10, limit: 50 } },
        { type: "toolCall", id: "t-code", name: "codemode", arguments: { code: script } },
      ],
    }),
    record(3, { role: "toolResult", toolCallId: "t-read", toolName: "read", content: [{ type: "text", text: "export function login() {}" }] }),
    record(4, { role: "toolResult", toolCallId: "t-code", toolName: "codemode", content: [{ type: "text", text: "12" }] }),
    record(5, {
      role: "assistant", timestamp: 1_700_000_000_002, content: [
        { type: "toolCall", id: "t-edit", name: "edit", arguments: { path: "src/login.ts", edits: [{ oldText: "export function login() {}", newText: "export function login(user) {\n  return user;\n}" }] } },
        { type: "toolCall", id: "t-test", name: "bash", arguments: { command: "npm test -- --grep login" } },
      ],
    }),
    record(6, { role: "toolResult", toolCallId: "t-edit", toolName: "edit", content: [{ type: "text", text: "Edited src/login.ts" }] }),
  ];
}

test("tools are rows in a block: a running one shows what it runs, and any opens to all of it", {
  skip: !existsSync(chromePath) && "Set CHROME_PATH to a Chrome/Chromium executable to run this browser test",
  timeout: 120_000,
}, async () => {
  const cloud = await startCloud(new Map([[chat, transcript()]]), [{ ...listed(chat, "Login", 6), status: "working" }]);
  const shots = process.env.AXO_WEB_SHOTS;
  if (shots) mkdirSync(shots, { recursive: true });
  let app;
  try {
    app = await startApp(cloud);
    const page = await app.browser.newPage({ viewport: { width: 1100, height: 900 } });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const shot = async (name) => { if (shots) await page.screenshot({ path: resolve(shots, `${name}.png`) }); };
    await page.goto(`${app.appUrl}/__tests__/chat/${hostId}/${chat}`, { waitUntil: "networkidle" });
    await page.getByText("I’ll look first.").waitFor();

    // The four tools used one after another are one block, headed by what they did together.
    const cards = page.getByTestId("tool-card");
    assert.equal(await cards.count(), 4);
    assert.equal(await page.getByTestId("tool-group-title").innerText(), "Read a file, ran a script, edited a file, ran a command");
    const row = (name) => page.getByRole("button", { name: new RegExp(`^${name}\\b`) });
    // Each row says what it works on.
    await row("read").getByText("src/login.ts · lines 10–59").waitFor();
    await row("codemode").getByText("const files = await tools.bash", { exact: false }).waitFor();

    // The running command shows what it runs, and the newest line it printed, before it is opened.
    const running = cards.nth(3);
    await running.getByText("npm test -- --grep login", { exact: true }).first().waitFor();
    for (let line = 1; line <= 30; line++) {
      cloud.toolProgress(chat, "t-test", { partialResult: { content: [{ type: "text", text: Array.from({ length: line }, (_, n) => `ok ${n + 1} login`).join("\n") }] } });
      await sleep(20);
    }
    await running.getByTestId("tool-last-line").getByText("ok 30 login").waitFor();
    await shot("running");

    // A finished tool's output stays folded; opened, it shows all it was given and what it printed.
    assert.equal(await page.getByText("export function login() {}", { exact: true }).count(), 0);
    await row("codemode").click();
    await cards.nth(1).getByLabel("Input").getByText("// and more", { exact: false }).waitFor();
    await cards.nth(1).getByLabel("Output").getByText("12").waitFor();
    await row("edit").click();
    await cards.nth(2).getByLabel("Input").getByText("+  return user;", { exact: false }).waitFor();

    // The running one opens too, its output still coming in.
    await row("bash").click();
    await running.getByLabel("Input").getByText("$ npm test -- --grep login").waitFor();
    await running.getByLabel("Output").getByText("ok 30 login", { exact: false }).waitFor();
    await shot("open");
    cloud.toolProgress(chat, "t-test", { partialResult: { content: [{ type: "text", text: Array.from({ length: 31 }, (_, n) => `ok ${n + 1} login`).join("\n") }] } });
    await running.getByLabel("Output").getByText("ok 31 login", { exact: false }).waitFor();

    // "See full output": all of it, as big as the window, still coming in.
    await running.getByRole("button", { name: /^See full output/ }).click();
    const viewer = page.getByRole("dialog", { name: "bash output" });
    await viewer.getByText("31 lines, still running").waitFor();
    cloud.toolProgress(chat, "t-test", { partialResult: { content: [{ type: "text", text: Array.from({ length: 200 }, (_, n) => `ok ${n + 1} login`).join("\n") }] } });
    await viewer.getByText("200 lines, still running").waitFor();
    await viewer.getByText("ok 200 login", { exact: false }).waitFor();
    // The end stays in view as it comes in.
    const fromEnd = await viewer.locator("pre").evaluate((pre) => pre.scrollHeight - pre.scrollTop - pre.clientHeight);
    assert.ok(fromEnd < 8, `the viewer follows the output's end: ${fromEnd}px from it`);
    await sleep(400);
    await shot("viewer");
    await page.keyboard.press("Escape");
    await viewer.waitFor({ state: "detached" });

    // Done: the tool says so, and what it printed is its result.
    cloud.write(chat, { role: "toolResult", toolCallId: "t-test", toolName: "bash", content: [{ type: "text", text: "ok 1 login\n# pass 1" }] });
    cloud.toolProgress(chat, "t-test", null);
    cloud.status(chat, "ready");
    await running.getByLabel("Completed").waitFor();
    await running.getByLabel("Output").getByText("# pass 1", { exact: false }).waitFor();
    await shot("done");
    assert.deepEqual(errors, []);
  } finally {
    await app?.close();
  }
});
