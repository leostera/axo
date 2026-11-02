// Checks the built site (.cloudflare/output): every schema is served at the URL its $id names,
// every example is there, every page the documents imply exists, and every internal link resolves.

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const ASSETS = ".cloudflare/output/v0/workers/default/assets";
const AXP = "../../axp";
const SITE = "https://axp.leostera.dev";

function files(dir, base = dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? files(path, base) : [path.slice(base.length)];
  });
}
function schemaFiles(dir) {
  return files(dir).filter((file) => file.endsWith(".schema.json")).map((file) => join(dir, file));
}

test("every schema is served at its $id", () => {
  const schemas = schemaFiles(join(AXP, "schema"));
  assert.ok(schemas.length > 1);
  for (const file of schemas) {
    const { $id } = JSON.parse(readFileSync(file, "utf8"));
    assert.ok($id.startsWith(`${SITE}/`), `${file}: $id ${$id}`);
    const served = join(ASSETS, $id.slice(SITE.length));
    assert.ok(existsSync(served), `${$id} is not served`);
    assert.equal(readFileSync(served, "utf8"), readFileSync(file, "utf8"), `${$id} differs from ${file}`);
  }
  assert.match(readFileSync(join(ASSETS, "_headers"), "utf8"), /\/schema\/\*\n\s+Content-Type: application\/schema\+json/);
});

test("every example is served", () => {
  for (const file of readdirSync(join(AXP, "examples"))) assert.ok(existsSync(join(ASSETS, "examples", file)), file);
});

test("the core, the registry and every extension have a page", () => {
  assert.ok(existsSync(join(ASSETS, "index.html")));
  assert.ok(existsSync(join(ASSETS, "extensions/index.html")));
  for (const file of readdirSync(join(AXP, "extensions")).filter((f) => f !== "README.md")) {
    assert.ok(existsSync(join(ASSETS, "extensions", file.replace(/\.md$/, ""), "index.html")), file);
  }
});

test("every internal link resolves", () => {
  const pages = files(ASSETS).filter((file) => file.endsWith(".html"));
  for (const page of pages) {
    const html = readFileSync(join(ASSETS, page), "utf8");
    const ids = new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((match) => match[1]));
    for (const [, href] of html.matchAll(/<a[^>]*\shref="([^"]+)"/g)) {
      if (/^[a-z]+:/i.test(href) || href.startsWith("//")) continue;
      const [path, hash] = href.split("#");
      if (path === "") {
        assert.ok(!hash || ids.has(hash), `${page}: #${hash} is not on the page`);
        continue;
      }
      const target = path.endsWith("/") ? join(ASSETS, path, "index.html") : join(ASSETS, path);
      assert.ok(existsSync(target), `${page}: ${href} does not exist`);
      if (hash && target.endsWith(".html")) {
        assert.match(readFileSync(target, "utf8"), new RegExp(`\\sid="${hash}"`), `${page}: ${href} has no #${hash}`);
      }
    }
  }
});
