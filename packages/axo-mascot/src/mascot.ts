// The Axo axolotl, traced from assets/axo-logo-original.jpeg, and its blink state machine.
//
// Geometry is in the original logo's pixel space (1254 x 1254); each artboard places it with a
// root node. Strokes are given at their centre line.
import {
  type AnimationId,
  ArtboardBuilder,
  type ComponentId,
  FillRule,
  Interpolation,
  type Point,
  type Track,
} from "./artboard.ts";
import { encodeRiv, type RivObject, TypeKey } from "./riv.ts";

/** Artboard, state machine and input names the apps rely on. */
export const MascotContract = {
  artboards: { icon: "Icon", face: "Face", mark: "Mark" },
  stateMachine: "Mascot",
  triggers: { blink: "blink" },
} as const;

const LOGO_SIZE = 1254;
const CENTER_X = 626;
const OUTLINE = 42;

const Color = {
  background: 0xffdfdfdf,
  face: 0xfffbfbfb,
  ink: 0xff1f1f1f,
  black: 0xff000000,
} as const;

const mirror = (p: Point): Point => ({ x: 2 * CENTER_X - p.x, y: p.y });
const add = (a: Point, b: Point): Point => ({ x: a.x + b.x, y: a.y + b.y });
const scale = (p: Point, k: number): Point => ({ x: p.x * k, y: p.y * k });

const head = [
  { at: { x: 626, y: 434 }, in: { x: 430, y: 434 }, out: { x: 822, y: 434 } },
  { at: { x: 951, y: 710 }, in: { x: 951, y: 540 }, out: { x: 951, y: 830 } },
  { at: { x: 626, y: 895 }, in: { x: 880, y: 895 }, out: { x: 372, y: 895 } },
  { at: { x: 299, y: 710 }, in: { x: 299, y: 830 }, out: { x: 299, y: 540 } },
];

/** A left gill: it leaves the head at `a`, rounds `tip` with half-width `radius`, and returns at `b`. */
interface Gill {
  readonly a: Point;
  readonly b: Point;
  readonly tip: Point;
  readonly radius: number;
}

const leftGills: readonly Gill[] = [
  { a: { x: 400, y: 492 }, b: { x: 330, y: 558 }, tip: { x: 222, y: 418 }, radius: 62 },
  { a: { x: 316, y: 584 }, b: { x: 296, y: 640 }, tip: { x: 147, y: 574 }, radius: 52 },
  { a: { x: 292, y: 676 }, b: { x: 296, y: 768 }, tip: { x: 160, y: 722 }, radius: 52 },
];

/** The gill as an open path, so its ends tuck under the head's outline. */
function gillVertices(gill: Gill) {
  const base = scale(add(gill.a, gill.b), 0.5);
  const length = Math.hypot(gill.tip.x - base.x, gill.tip.y - base.y);
  const axis = { x: (gill.tip.x - base.x) / length, y: (gill.tip.y - base.y) / length };
  // The normal pointing from b's side towards a's side.
  let normal = { x: -axis.y, y: axis.x };
  if ((gill.a.x - base.x) * normal.x + (gill.a.y - base.y) * normal.y < 0) normal = scale(normal, -1);
  const reach = length * 0.55;
  const swell = gill.radius * 0.9;
  return [
    { at: gill.a, in: gill.a, out: add(add(gill.a, scale(axis, reach)), scale(normal, swell)) },
    { at: gill.tip, in: add(gill.tip, scale(normal, gill.radius * 1.1)), out: add(gill.tip, scale(normal, -gill.radius * 1.1)) },
    { at: gill.b, in: add(add(gill.b, scale(axis, reach)), scale(normal, -swell)), out: gill.b },
  ];
}

const mirrorVertices = (vertices: { at: Point; in: Point; out: Point }[]) =>
  vertices
    .map((v) => ({ at: mirror(v.at), in: mirror(v.out), out: mirror(v.in) }))
    .reverse();

interface Style {
  /** Fill for the head and gills; none draws outlines only. */
  readonly face?: number;
  readonly ink: number;
}

/** Draws the axolotl under `parent` and returns the nodes the animations move. */
function drawAxolotl(board: ArtboardBuilder, parent: ComponentId, style: Style) {
  // Earlier objects draw on top, so: eyes and mouth, head, then gills.
  const eyes: ComponentId[] = [];
  for (const [name, x] of [
    ["Left Eye", 455],
    ["Right Eye", 797],
  ] as const) {
    const eye = board.shape(parent, { name, x, y: 695 });
    board.ellipse(eye, { name: `${name} Path`, width: 97, height: 97 });
    board.fill(eye, style.ink);
    eyes.push(eye);
  }

  const mouth = board.shape(parent, { name: "Mouth", x: 0, y: 0 });
  board.cubicPath(
    mouth,
    "Mouth Path",
    [
      { at: { x: 566, y: 744 }, in: { x: 566, y: 744 }, out: { x: 566, y: 744 } },
      { at: { x: 686, y: 744 }, in: { x: 686, y: 744 }, out: { x: 686, y: 744 } },
    ],
    false,
  );
  board.stroke(mouth, style.ink, 40);

  const headShape = board.shape(parent, { name: "Head", x: 0, y: 0 });
  board.cubicPath(headShape, "Head Path", head, true);
  board.stroke(headShape, style.ink, OUTLINE);
  if (style.face !== undefined) board.fill(headShape, style.face);

  for (const [side, toSide] of [
    ["Left", (v: ReturnType<typeof gillVertices>) => v],
    ["Right", mirrorVertices],
  ] as const) {
    leftGills.forEach((gill, index) => {
      const shape = board.shape(parent, { name: `${side} Gill ${index + 1}`, x: 0, y: 0 });
      board.cubicPath(shape, `${side} Gill ${index + 1} Path`, toSide(gillVertices(gill)), false);
      board.stroke(shape, style.ink, OUTLINE);
      if (style.face !== undefined) board.fill(shape, style.face, FillRule.nonZero);
    });
  }
  return { eyes };
}

/** Eyes squash to a line: close fast, hold briefly, open a little slower. */
function blinkTracks(eyes: readonly ComponentId[], start: number): { tracks: Track[]; end: number } {
  const closed = 0.24;
  const frames = [
    { frame: start, value: 1 },
    { frame: start + 4, value: closed },
    { frame: start + 7, value: closed },
    { frame: start + 14, value: 1 },
  ];
  return { tracks: eyes.map((object) => ({ object, property: "scaleY", frames })), end: start + 14 };
}

function addBlinkMachine(board: ArtboardBuilder, eyes: readonly ComponentId[]): void {
  const open = (name: string, seconds: number): AnimationId =>
    board.animation({
      name,
      duration: seconds * 60,
      tracks: eyes.map((object) => ({
        object,
        property: "scaleY",
        frames: [{ frame: 0, value: 1, interpolation: Interpolation.hold }],
      })),
    });
  const waitShort = open("wait-2s", 2);
  const waitMedium = open("wait-4s", 4);
  const waitLong = open("wait-7s", 7);

  const single = blinkTracks(eyes, 0);
  const blink = board.animation({ name: "blink", duration: single.end, tracks: single.tracks });

  const first = blinkTracks(eyes, 0);
  const second = blinkTracks(eyes, first.end + 6);
  const doubleBlink = board.animation({
    name: "double-blink",
    duration: second.end,
    tracks: first.tracks.map((track, index) => ({
      ...track,
      frames: [...track.frames, ...second.tracks[index]!.frames],
    })),
  });

  // Irregular on purpose: a fixed rhythm reads as a loading indicator, not a creature.
  const afterWait = [
    { to: "blink", exitAtPercent: 100, weight: 4 },
    { to: "double-blink", exitAtPercent: 100, weight: 1 },
  ];
  const afterBlink = [
    { to: "wait-2s", exitAtPercent: 100, weight: 1 },
    { to: "wait-4s", exitAtPercent: 100, weight: 2 },
    { to: "wait-7s", exitAtPercent: 100, weight: 2 },
  ];
  board.stateMachine({
    name: MascotContract.stateMachine,
    triggers: [MascotContract.triggers.blink],
    layer: {
      name: "Eyes",
      entry: "wait-2s",
      any: [{ to: "blink", trigger: MascotContract.triggers.blink }],
      states: [
        { name: "wait-2s", animation: waitShort, random: true, transitions: afterWait },
        { name: "wait-4s", animation: waitMedium, random: true, transitions: afterWait },
        { name: "wait-7s", animation: waitLong, random: true, transitions: afterWait },
        { name: "blink", animation: blink, random: true, transitions: afterBlink },
        { name: "double-blink", animation: doubleBlink, random: true, transitions: afterBlink },
      ],
    },
  });
}

/** A superellipse, close to Apple's continuous-corner icon shape. */
function squircle(center: Point, size: number, exponent = 5, steps = 160): Point[] {
  return Array.from({ length: steps }, (_, step) => {
    const angle = (step / steps) * 2 * Math.PI;
    const c = Math.cos(angle);
    const s = Math.sin(angle);
    return {
      x: center.x + (size / 2) * Math.sign(c) * Math.abs(c) ** (2 / exponent),
      y: center.y + (size / 2) * Math.sign(s) * Math.abs(s) ** (2 / exponent),
    };
  });
}

/** The macOS app icon: a rounded square at 80% of the canvas, as in assets/make-icons.swift. */
function iconArtboard(): RivObject[] {
  const size = 1024;
  const box = size * 0.8;
  const board = new ArtboardBuilder(MascotContract.artboards.icon, { width: size, height: size });
  const k = box / LOGO_SIZE;
  const offset = (size - box) / 2;
  const axolotl = board.node(board.root, { name: "Axolotl", x: offset, y: offset, scaleX: k, scaleY: k });
  const { eyes } = drawAxolotl(board, axolotl, { face: Color.face, ink: Color.ink });
  const background = board.shape(board.root, { name: "Background", x: 0, y: 0 });
  board.polygon(background, "Background Path", squircle({ x: size / 2, y: size / 2 }, box));
  board.fill(background, Color.background);
  addBlinkMachine(board, eyes);
  return board.objects();
}

/** The axolotl alone, cropped tight: for in-app and web use (`face`) or a template image (`mark`). */
function croppedArtboard(name: string, style: Style): RivObject[] {
  const bounds = { x: 96, y: 366, width: 1064, height: 564 };
  const board = new ArtboardBuilder(name, { width: bounds.width, height: bounds.height });
  const axolotl = board.node(board.root, { name: "Axolotl", x: -bounds.x, y: -bounds.y });
  const { eyes } = drawAxolotl(board, axolotl, style);
  addBlinkMachine(board, eyes);
  return board.objects();
}

export function buildMascot(): Uint8Array {
  return encodeRiv([
    { type: TypeKey.Backboard, props: {} },
    ...iconArtboard(),
    ...croppedArtboard(MascotContract.artboards.face, { face: Color.face, ink: Color.ink }),
    ...croppedArtboard(MascotContract.artboards.mark, { ink: Color.black }),
  ]);
}
