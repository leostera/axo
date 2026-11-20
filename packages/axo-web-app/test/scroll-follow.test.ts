import assert from "node:assert/strict";
import test from "node:test";
import { followsAfterScroll } from "../src/chat/scroll-follow.ts";

test("a delayed scroll event after content growth does not invent reader movement", () => {
  assert.equal(followsAfterScroll({ wasFollowing: true, previousTop: 1000, top: 1000, fromEnd: 200 }), true);
});

test("real upward movement leaves the end even within the following slack", () => {
  assert.equal(followsAfterScroll({ wasFollowing: true, previousTop: 1000, top: 950, fromEnd: 50 }), false);
});

test("a reader in history is not pulled back by growing content", () => {
  assert.equal(followsAfterScroll({ wasFollowing: false, previousTop: 500, top: 500, fromEnd: 700 }), false);
});

test("scrolling down close to the end and a clamped shrink resume following", () => {
  assert.equal(followsAfterScroll({ wasFollowing: false, previousTop: 500, top: 1100, fromEnd: 30 }), true);
  assert.equal(followsAfterScroll({ wasFollowing: true, previousTop: 1000, top: 900, fromEnd: 0 }), true);
});
