import assert from "node:assert/strict";
import { test } from "node:test";
import { buildMascot } from "../src/mascot.ts";
import { encodeRiv, TypeKey } from "../src/riv.ts";

test("files start with the RIVE header, version 7.0 and an empty property table", () => {
  const bytes = encodeRiv([{ type: TypeKey.Backboard, props: {} }]);
  assert.deepEqual([...bytes], [..."RIVE"].map((c) => c.charCodeAt(0)).concat([7, 0, 0, 0, TypeKey.Backboard, 0]));
});

test("values use the runtime's encodings", () => {
  const bytes = encodeRiv([{ type: TypeKey.Node, props: { name: "é", parentId: 300, x: 1.5, colorValue: 0xff000001 } }]);
  const body = [...bytes.slice(8)];
  // Node, name (4) "é", parentId (5) varuint 300, x (13) float32 1.5, colorValue (37) uint32 LE.
  assert.deepEqual(body, [2, 4, 2, 0xc3, 0xa9, 5, 0xac, 0x02, 13, 0, 0, 0xc0, 0x3f, 37, 1, 0, 0, 0xff, 0]);
});

test("the mascot builds deterministically", () => {
  assert.deepEqual(buildMascot(), buildMascot());
});

test("the Face size matches what the apps lay out", async () => {
  const { MascotBounds } = await import("../src/mascot.ts");
  // AboutMascotView.swift, AxoPhone's AxoMascotView.swift, axo-web-app's axo-mascot.tsx and the
  // Mac menu bar size use 1064 x 604: change them together.
  assert.deepEqual([MascotBounds.face.width, MascotBounds.face.height], [1064, 604]);
  assert.deepEqual([MascotBounds.mark.width, MascotBounds.mark.height], [1064, 604]);
});
