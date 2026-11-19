import assert from "node:assert/strict";
import test from "node:test";
import { nativeCommandCatalog, nativeCommandText } from "../src/native-commands.js";

test("Pi's remote native catalog hides the transport alias and respects actual extension commands", () => {
  const commands = [
    { name: "axo-native", description: "internal", source: "extension" },
    { name: "reload", description: "Custom reload", source: "extension" },
    { name: "review", description: "Review code", source: "prompt" },
  ];
  const catalog = nativeCommandCatalog(commands);
  assert.equal(catalog.some(command => command.name === "axo-native"), false);
  assert.equal(catalog.filter(command => command.name === "reload").length, 1);
  assert.equal(catalog.find(command => command.name === "reload")?.description, "Custom reload");
  assert.equal(nativeCommandText("/reload", commands), "/reload", "a real agent-defined command owns its name");
  assert.equal(nativeCommandText("/compact focus on tests", commands), "/axo-native compact focus on tests");
});

test("only reviewed native commands route to SDK actions, with arguments intact", () => {
  for (const name of ["reload", "compact", "name", "model", "thinking"]) {
    assert.equal(nativeCommandText("/" + name, []), "/axo-native " + name);
  }
  assert.equal(nativeCommandText("/name A new name", []), "/axo-native name A new name");
  for (const text of ["hello /reload", "/reloader", "/quit", "/new", "/settings"]) {
    assert.equal(nativeCommandText(text, []), text, "terminal-only actions are not falsely advertised as remotely executable");
  }
});
