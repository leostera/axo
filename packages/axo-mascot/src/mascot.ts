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
  type LayerSpec,
  Loop,
  type Point,
  type Track,
} from "./artboard.ts";
import { encodeRiv, type RivObject, TypeKey } from "./riv.ts";

/** Artboard, state machine and input names the apps rely on. */
export const MascotContract = {
  artboards: {
    icon: "Icon",
    face: "Face",
    mark: "Mark",
    /** Square, with room to spin: for loading. */
    loader: "Loader",
  },
  stateMachine: "Mascot",
  /** Fire to play once. */
  triggers: {
    blink: "blink",
    /** A poke on the face: "oh!", then a ^_^ giggle. */
    poke: "poke",
    /** Too many pokes: a shake, squeezed shut: >_< */
    annoyed: "annoyed",
    /** Something went well: a little bounce, eyes smiling: ^_^ */
    happy: "happy",
  },
  bools: {
    /** Follow `lookX`/`lookY` instead of looking around on its own. */
    tracking: "tracking",
    /** Hands over the eyes (the `Face` artboard has hands). */
    covering: "covering",
    /** Waiting on something: gills flutter and Axo bobs; on `Loader` it also spins. */
    loading: "loading",
    /** Eyes squeezed shut >_< and held, with no shake: braced for something (a pull-to-refresh). */
    squeezed: "squeezed",
  },
  /** Where to look, from -100 (left, up) to 100 (right, down). */
  numbers: { lookX: "lookX", lookY: "lookY" },
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
  /** Fill for the head, gills and hands; none draws outlines only. */
  readonly face?: number;
  readonly ink: number;
  /** Hands that can come up over the eyes. */
  readonly hands?: boolean;
}

/** The face's centre: the body turns and bounces around it. */
const PIVOT: Point = { x: 626, y: 690 };

/**
 * Where each cropped artboard sits in the logo's coordinates. Each holds every pose its
 * animations reach (test/bounds.test.ts measures them), so nothing is clipped mid-animation;
 * the arms are the exception and reach down out of the picture on purpose.
 */
export const MascotBounds = {
  // Measured reach, in logo units: at rest y 368…914; a poke, ^_^ and loading's bob lift the
  // gills to about y 340; the annoyed shake spans x 114…1142. Each edge keeps ~14 units of room.
  /** Every behaviour: looking, pokes, the annoyed shake, loading's bob and the hands. The apps
   * size their views to this: 1064 x 604. */
  face: { x: 96, y: 326, width: 1064, height: 604 },
  /** The menu bar's template; same crop as `face`. */
  mark: { x: 96, y: 326, width: 1064, height: 604 },
  /** A square wide enough for the axolotl to spin in, raised for the hop (it reaches y ≈ 100). */
  loader: { x: PIVOT.x - 540, y: 76, width: 1080, height: 1080 },
} as const satisfies Record<string, Bounds>;

/** Where each hand sits over an eye; lowered, it is below the crop and transparent. */
const HAND_DROP = 380;
const leftHand = { at: { x: 468, y: 708 }, rotation: 0.35 };

/** The nodes the animations move. */
interface Rig {
  readonly body: ComponentId;
  readonly features: ComponentId;
  /** The round eyes; the shaped ones below take their place in some reactions. */
  readonly eyes: readonly ComponentId[];
  /** ^ ^, left first. */
  readonly happyEyes: readonly ComponentId[];
  /** > <, left first. */
  readonly squeezedEyes: readonly ComponentId[];
  readonly mouth: ComponentId;
  readonly mouthO: ComponentId;
  readonly hands: readonly ComponentId[];
  /** Gill nodes pivoting where each gill meets the head; left ones first. */
  readonly gills: { readonly left: readonly ComponentId[]; readonly right: readonly ComponentId[] };
}

/** Draws the axolotl under `parent`. Earlier objects draw on top. */
function drawAxolotl(board: ArtboardBuilder, parent: ComponentId, style: Style): Rig {
  const body = board.node(parent, { name: "Body", x: PIVOT.x, y: PIVOT.y });
  const art = board.node(body, { name: "Art", x: -PIVOT.x, y: -PIVOT.y });

  const hands: ComponentId[] = [];
  if (style.hands) {
    for (const [name, at, rotation] of [
      ["Left Hand", leftHand.at, leftHand.rotation],
      ["Right Hand", mirror(leftHand.at), -leftHand.rotation],
    ] as const) {
      // A node per hand, so the paw, fingers and arm rise and fade together.
      const hand = board.node(art, { name, x: at.x, y: at.y + HAND_DROP, rotation, opacity: 0 });
      const paw = board.shape(hand, { name: `${name} Paw`, x: 0, y: 0 });
      board.ellipse(paw, { name: `${name} Paw Path`, width: 190, height: 170 });
      board.stroke(paw, style.ink, OUTLINE);
      if (style.face !== undefined) board.fill(paw, style.face);
      // Three finger bumps peek over the top of the paw.
      const fingers = board.shape(hand, { name: `${name} Fingers`, x: 0, y: 0 });
      for (const [x, y] of [[-52, -70], [0, -86], [52, -70]] as const) {
        board.ellipse(fingers, { name: `${name} Finger`, x, y, width: 66, height: 74 });
      }
      board.stroke(fingers, style.ink, OUTLINE);
      if (style.face !== undefined) board.fill(fingers, style.face);
      // The arm reaches down out of the picture.
      const arm = board.shape(hand, { name: `${name} Arm`, x: 0, y: 0 });
      board.cubicPath(
        arm,
        `${name} Arm Path`,
        [
          { at: { x: -56, y: 40 }, in: { x: -56, y: 40 }, out: { x: -56, y: 40 } },
          { at: { x: -64, y: 420 }, in: { x: -64, y: 420 }, out: { x: -64, y: 420 } },
          { at: { x: 64, y: 420 }, in: { x: 64, y: 420 }, out: { x: 64, y: 420 } },
          { at: { x: 56, y: 40 }, in: { x: 56, y: 40 }, out: { x: 56, y: 40 } },
        ],
        false,
      );
      board.stroke(arm, style.ink, OUTLINE);
      if (style.face !== undefined) board.fill(arm, style.face);
      hands.push(hand);
    }
  }

  // Eyes and mouth move together when Axo looks somewhere.
  const features = board.node(art, { name: "Features", x: 0, y: 0 });
  const eyes: ComponentId[] = [];
  for (const [name, x] of [
    ["Left Eye", 455],
    ["Right Eye", 797],
  ] as const) {
    const eye = board.shape(features, { name, x, y: 695 });
    board.ellipse(eye, { name: `${name} Path`, width: 97, height: 97 });
    board.fill(eye, style.ink);
    eyes.push(eye);
  }

  // Eyes drawn as strokes, hidden until a reaction swaps them in for the round ones.
  const strokedEyes = (kind: string, points: (x: number, side: 1 | -1) => Point[]) =>
    ([["Left", 455, 1], ["Right", 797, -1]] as const).map(([side, x, sign]) => {
      const eye = board.shape(features, { name: `${side} ${kind} Eye`, x: 0, y: 0, opacity: 0 });
      board.cubicPath(eye, `${side} ${kind} Eye Path`, points(x, sign).map((at) => ({ at, in: at, out: at })), false);
      board.stroke(eye, style.ink, 36);
      return eye;
    });
  // ^ ^: a peak over each eye.
  const happyEyes = strokedEyes("Happy", (x) => [{ x: x - 46, y: 718 }, { x, y: 670 }, { x: x + 46, y: 718 }]);
  // > <: each points in towards the nose.
  const squeezedEyes = strokedEyes("Squeezed", (x, sign) => [
    { x: x - sign * 38, y: 652 },
    { x: x + sign * 38, y: 695 },
    { x: x - sign * 38, y: 738 },
  ]);

  const mouthO = board.shape(features, { name: "Mouth O", x: 626, y: 750, opacity: 0 });
  board.ellipse(mouthO, { name: "Mouth O Path", width: 54, height: 64 });
  board.stroke(mouthO, style.ink, 30);

  const mouth = board.shape(features, { name: "Mouth", x: 0, y: 0 });
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

  const headShape = board.shape(art, { name: "Head", x: 0, y: 0 });
  board.cubicPath(headShape, "Head Path", head, true);
  board.stroke(headShape, style.ink, OUTLINE);
  if (style.face !== undefined) board.fill(headShape, style.face);

  const gills = { left: [] as ComponentId[], right: [] as ComponentId[] };
  for (const [side, toSide, toPoint, nodes] of [
    ["Left", (v: ReturnType<typeof gillVertices>) => v, (p: Point) => p, gills.left],
    ["Right", mirrorVertices, mirror, gills.right],
  ] as const) {
    leftGills.forEach((gill, index) => {
      // A node at the gill's root, so the gill swings from where it meets the head.
      const root = toPoint(scale(add(gill.a, gill.b), 0.5));
      const node = board.node(art, { name: `${side} Gill ${index + 1} Root`, x: root.x, y: root.y });
      const shape = board.shape(node, { name: `${side} Gill ${index + 1}`, x: -root.x, y: -root.y });
      board.cubicPath(shape, `${side} Gill ${index + 1} Path`, toSide(gillVertices(gill)), false);
      board.stroke(shape, style.ink, OUTLINE);
      if (style.face !== undefined) board.fill(shape, style.face, FillRule.nonZero);
      nodes.push(node);
    });
  }
  return { body, features, eyes, happyEyes, squeezedEyes, mouth, mouthO, hands, gills };
}

type Key = readonly [frame: number, value: number];
const track = (object: ComponentId, property: Track["property"], keys: readonly Key[], interpolation?: number): Track => ({
  object,
  property,
  frames: keys.map(([frame, value]) => ({ frame, value, interpolation })),
});
const each = (objects: readonly ComponentId[], property: Track["property"], keys: readonly Key[], interpolation?: number) =>
  objects.map((object) => track(object, property, keys, interpolation));
/** Keys for a node that rests at `origin`, given as offsets from it. */
const offset = (origin: number, keys: readonly Key[]): Key[] => keys.map(([frame, value]) => [frame, origin + value]);
/** One value for the whole animation. */
const hold = (objects: readonly ComponentId[], property: Track["property"], value: number) =>
  each(objects, property, [[0, value]], Interpolation.hold);

/** Eyes squash to a line: close fast, hold briefly, open a little slower. */
function blinkKeys(start: number): { keys: Key[]; end: number } {
  const closed = 0.24;
  return { keys: [[start, 1], [start + 4, closed], [start + 7, closed], [start + 14, 1]], end: start + 14 };
}

/** Eyes dart from one spot to the next and rest there, the way eyes do. */
function saccades(features: ComponentId, stops: readonly { at: number; x: number; y: number }[], duration: number): Track[] {
  const dart = 5;
  const keys = { x: [] as Key[], y: [] as Key[] };
  let previous = { x: 0, y: 0 };
  for (const stop of stops) {
    const start = Math.round(stop.at * 60);
    keys.x.push([start, previous.x], [start + dart, stop.x]);
    keys.y.push([start, previous.y], [start + dart, stop.y]);
    previous = stop;
  }
  keys.x.push([duration, previous.x]);
  keys.y.push([duration, previous.y]);
  return [track(features, "x", keys.x), track(features, "y", keys.y)];
}

/** The state machine every artboard runs; see `MascotContract`. */
function addMascotMachine(board: ArtboardBuilder, rig: Rig, options: { spins?: boolean } = {}): void {
  const { triggers, bools, numbers } = MascotContract;
  const rest = board.animation({ name: "rest", duration: 60, loop: Loop.loop, tracks: [] });

  // Looking: on its own, or where the app says.
  const wander = board.animation({
    name: "look-around",
    duration: 600,
    loop: Loop.loop,
    tracks: saccades(
      rig.features,
      [
        { at: 2.2, x: -38, y: -8 },
        { at: 3.6, x: 0, y: 0 },
        { at: 5.4, x: 36, y: 10 },
        { at: 6.6, x: 18, y: -20 },
        { at: 7.6, x: 0, y: 0 },
      ],
      600,
    ),
  });
  const look = (name: string, property: "x" | "y", value: number) =>
    board.animation({ name, duration: 60, loop: Loop.loop, tracks: hold([rig.features], property, value) });
  const lookX = [look("look-left", "x", -46), look("look-centre-x", "x", 0), look("look-right", "x", 46)];
  const lookY = [look("look-up", "y", -30), look("look-centre-y", "y", 0), look("look-down", "y", 26)];

  // Blinking: random waits, then a blink or, one time in five, a double blink.
  const wait = (name: string, seconds: number) =>
    board.animation({ name, duration: seconds * 60, tracks: hold(rig.eyes, "scaleY", 1) });
  const waits = { short: wait("wait-2s", 2), medium: wait("wait-4s", 4), long: wait("wait-7s", 7) };
  const single = blinkKeys(0);
  const blink = board.animation({ name: "blink", duration: single.end, tracks: each(rig.eyes, "scaleY", single.keys) });
  const second = blinkKeys(single.end + 6);
  const doubleBlink = board.animation({
    name: "double-blink",
    duration: second.end,
    tracks: each(rig.eyes, "scaleY", [...single.keys, ...second.keys]),
  });

  // Reactions start from a neutral face, so one can interrupt another.
  const neutral = (frame: number) => [
    ...each([rig.mouth], "opacity", [[frame, 1]]),
    ...each([rig.mouthO], "opacity", [[frame, 0]]),
    ...each(rig.eyes, "opacity", [[frame, 1]]),
    ...each([...rig.happyEyes, ...rig.squeezedEyes], "opacity", [[frame, 0]]),
  ];
  /** Swaps the round eyes for `shaped` from `from` to `to`, with quick fades either side. */
  const swapEyes = (shaped: readonly ComponentId[], from: number, to: number) => [
    ...each(rig.eyes, "opacity", [[from, 1], [from + 3, 0], [to - 4, 0], [to, 1]]),
    ...each(shaped, "opacity", [[from, 0], [from + 3, 1], [to - 4, 1], [to, 0]]),
  ];
  const reaction = (name: string, duration: number, tracks: Track[]) => {
    // A property keyed here wins over the neutral key at frame 0 for the same object.
    const keyed = new Set(tracks.map((t) => `${t.object}.${t.property}`));
    const base = [
      ...neutral(0),
      ...each([rig.body], "x", [[0, PIVOT.x]]),
      ...each([rig.body], "y", [[0, PIVOT.y]]),
      ...each([rig.body], "rotation", [[0, 0]]),
    ].filter((t) => !keyed.has(`${t.object}.${t.property}`));
    return board.animation({ name, duration, tracks: [...base, ...tracks] });
  };
  const oh = reaction("oh", 21, [
    ...each([rig.mouth], "opacity", [[0, 0]]),
    ...each([rig.mouthO], "opacity", [[0, 1]]),
    ...each([rig.body], "y", offset(PIVOT.y, [[0, 0], [6, -18], [16, 0]])),
  ]);
  const giggle = reaction("giggle", 48, [
    ...swapEyes(rig.happyEyes, 0, 47),
    ...each([rig.body], "y", offset(PIVOT.y, [[0, 0], [6, -12], [12, 0], [18, -9], [24, 0], [30, -6], [36, 0]])),
    ...each([rig.body], "rotation", [[0, 0], [6, 0.05], [12, -0.05], [18, 0.04], [24, -0.04], [30, 0.02], [36, 0]]),
  ]);
  const annoyed = reaction("annoyed", 72, [
    ...swapEyes(rig.squeezedEyes, 0, 70),
    ...each([rig.body], "x", offset(PIVOT.x, [[0, 0], [3, 16], [6, -16], [9, 14], [12, -14], [15, 10], [18, -10], [21, 6], [24, -4], [27, 0]])),
  ]);
  const happy = reaction("happy", 66, [
    ...swapEyes(rig.happyEyes, 0, 64),
    ...each([rig.body], "y", offset(PIVOT.y, [[0, 0], [8, -14], [16, 0], [24, -7], [32, 0]])),
  ]);

  const afterWait = [
    { to: "blink", exitAtPercent: 100, weight: 4 },
    { to: "double-blink", exitAtPercent: 100, weight: 1 },
  ];
  const afterBlink = [
    { to: "wait-2s", exitAtPercent: 100, weight: 1 },
    { to: "wait-4s", exitAtPercent: 100, weight: 2 },
    { to: "wait-7s", exitAtPercent: 100, weight: 2 },
  ];
  const tracking = { bool: bools.tracking, is: true } as const;
  const notTracking = { bool: bools.tracking, is: false } as const;
  const blend = (input: string, animations: readonly AnimationId[]) => ({
    input,
    animations: animations.map((animation, index) => ({ animation, value: (index - 1) * 100 })),
  });

  const layers: LayerSpec[] = [
    {
      name: "Look",
      entry: "look-around",
      any: [],
      states: [
        { name: "look-around", animation: wander, transitions: [{ to: "follow-x", when: tracking, mixMs: 120 }] },
        { name: "follow-x", blend: blend(numbers.lookX, lookX), transitions: [{ to: "look-around", when: notTracking, mixMs: 300 }] },
      ],
    },
    {
      name: "Look Y",
      entry: "rest",
      any: [],
      states: [
        { name: "rest", animation: rest, transitions: [{ to: "follow-y", when: tracking, mixMs: 120 }] },
        { name: "follow-y", blend: blend(numbers.lookY, lookY), transitions: [{ to: "rest", when: notTracking, mixMs: 300 }] },
      ],
    },
    {
      name: "Eyes",
      entry: "wait-2s",
      any: [{ to: "blink", when: { trigger: triggers.blink } }],
      states: [
        { name: "wait-2s", animation: waits.short, random: true, transitions: afterWait },
        { name: "wait-4s", animation: waits.medium, random: true, transitions: afterWait },
        { name: "wait-7s", animation: waits.long, random: true, transitions: afterWait },
        { name: "blink", animation: blink, random: true, transitions: afterBlink },
        { name: "double-blink", animation: doubleBlink, random: true, transitions: afterBlink },
      ],
    },
  ];
  if (rig.hands.length > 0) {
    const handKeys = (lowered: boolean) => [
      ...rig.hands.map((hand) => track(hand, "y", [[0, leftHand.at.y + (lowered ? HAND_DROP : 0)]], Interpolation.hold)),
      ...hold(rig.hands, "opacity", lowered ? 0 : 1),
    ];
    const down = board.animation({ name: "hands-down", duration: 60, loop: Loop.loop, tracks: handKeys(true) });
    const up = board.animation({ name: "hands-up", duration: 60, loop: Loop.loop, tracks: handKeys(false) });
    layers.push({
      name: "Hands",
      entry: "hands-down",
      any: [],
      states: [
        { name: "hands-down", animation: down, transitions: [{ to: "hands-up", when: { bool: bools.covering, is: true }, mixMs: 260 }] },
        { name: "hands-up", animation: up, transitions: [{ to: "hands-down", when: { bool: bools.covering, is: false }, mixMs: 320 }] },
      ],
    });
  }
  // Waiting: gills flutter in a wave and Axo bobs; with room, it spins once each cycle.
  // Each gill swings on a one-second sine, a little behind the one above it: a wave.
  const flutter = (nodes: readonly ComponentId[], sign: number) =>
    nodes.map((node, index) => {
      const keys: Key[] = [];
      for (let frame = 0; frame <= 120; frame += 10) {
        keys.push([frame, sign * 0.2 * Math.sin((frame / 60) * 2 * Math.PI - index * 0.9)]);
      }
      return track(node, "rotation", keys);
    });
  const spin: Track[] = options.spins
    ? each([rig.body], "rotation", [[0, 0], [30, 0], [44, 0.9], [58, 2 * Math.PI - 0.6], [72, 2 * Math.PI + 0.12], [80, 2 * Math.PI], [120, 2 * Math.PI]])
    : [];
  const loading = board.animation({
    name: "loading",
    duration: 120,
    loop: Loop.loop,
    tracks: [
      ...flutter(rig.gills.left, 1),
      ...flutter(rig.gills.right, -1),
      ...each([rig.body], "y", offset(PIVOT.y, options.spins
        ? [[0, 0], [30, 0], [40, -60], [58, -80], [72, 0], [78, 10], [86, 0], [120, 0]]
        : [[0, 0], [30, -14], [60, 0], [90, -14], [120, 0]])),
      ...spin,
    ],
  });
  const still = board.animation({
    name: "still",
    duration: 60,
    loop: Loop.loop,
    tracks: [
      ...hold([...rig.gills.left, ...rig.gills.right], "rotation", 0),
      ...each([rig.body], "y", [[0, PIVOT.y]], Interpolation.hold),
      ...hold([rig.body], "rotation", 0),
    ],
  });
  layers.push({
    name: "Loading",
    entry: "still",
    any: [],
    states: [
      { name: "still", animation: still, transitions: [{ to: "loading", when: { bool: bools.loading, is: true }, mixMs: 150 }] },
      { name: "loading", animation: loading, transitions: [{ to: "still", when: { bool: bools.loading, is: false }, mixMs: 250 }] },
    ],
  });
  // Squeezed: >_< held for as long as the app says. Before Reactions, so a reaction still wins.
  const eyesKeys = (squeezed: boolean) => [
    ...hold(rig.eyes, "opacity", squeezed ? 0 : 1),
    ...hold(rig.squeezedEyes, "opacity", squeezed ? 1 : 0),
  ];
  const open = board.animation({ name: "eyes-open", duration: 60, loop: Loop.loop, tracks: eyesKeys(false) });
  const shut = board.animation({ name: "eyes-squeezed", duration: 60, loop: Loop.loop, tracks: eyesKeys(true) });
  layers.push({
    name: "Squeeze",
    entry: "open",
    any: [],
    states: [
      { name: "open", animation: open, transitions: [{ to: "squeezed", when: { bool: bools.squeezed, is: true }, mixMs: 80 }] },
      { name: "squeezed", animation: shut, transitions: [{ to: "open", when: { bool: bools.squeezed, is: false }, mixMs: 120 }] },
    ],
  });
  // Last, so a reaction's face wins over blinking.
  layers.push({
    name: "Reactions",
    entry: "calm",
    any: [
      { to: "oh", when: { trigger: triggers.poke } },
      { to: "annoyed", when: { trigger: triggers.annoyed } },
      { to: "happy", when: { trigger: triggers.happy } },
    ],
    states: [
      { name: "calm", animation: rest, transitions: [] },
      { name: "oh", animation: oh, transitions: [{ to: "giggle", exitAtPercent: 100 }] },
      { name: "giggle", animation: giggle, transitions: [{ to: "calm", exitAtPercent: 100 }] },
      { name: "annoyed", animation: annoyed, transitions: [{ to: "calm", exitAtPercent: 100 }] },
      { name: "happy", animation: happy, transitions: [{ to: "calm", exitAtPercent: 100 }] },
    ],
  });

  board.stateMachine({
    name: MascotContract.stateMachine,
    inputs: [
      { kind: "trigger", name: triggers.blink },
      { kind: "trigger", name: triggers.poke },
      { kind: "trigger", name: triggers.annoyed },
      { kind: "trigger", name: triggers.happy },
      { kind: "bool", name: bools.tracking },
      { kind: "bool", name: bools.covering },
      { kind: "bool", name: bools.loading },
      { kind: "bool", name: bools.squeezed },
      { kind: "number", name: numbers.lookX },
      { kind: "number", name: numbers.lookY },
    ],
    layers,
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
  const rig = drawAxolotl(board, axolotl, { face: Color.face, ink: Color.ink });
  const background = board.shape(board.root, { name: "Background", x: 0, y: 0 });
  board.polygon(background, "Background Path", squircle({ x: size / 2, y: size / 2 }, box));
  board.fill(background, Color.background);
  addMascotMachine(board, rig);
  return board.objects();
}

interface Bounds {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** The axolotl alone, cropped to `bounds`. */
function croppedArtboard(name: string, style: Style, bounds: Bounds, spins = false): RivObject[] {
  const board = new ArtboardBuilder(name, { width: bounds.width, height: bounds.height });
  const axolotl = board.node(board.root, { name: "Axolotl", x: -bounds.x, y: -bounds.y });
  addMascotMachine(board, drawAxolotl(board, axolotl, style), { spins });
  return board.objects();
}

const grow = (bounds: Bounds, by: number): Bounds => ({
  x: bounds.x - by,
  y: bounds.y - by,
  width: bounds.width + 2 * by,
  height: bounds.height + 2 * by,
});

/**
 * Builds the file. `measuringMargin` widens every cropped artboard by that much on each side,
 * so a test can see whether any animation draws outside the real bounds.
 */
export function buildMascot(options: { measuringMargin?: number } = {}): Uint8Array {
  const margin = options.measuringMargin ?? 0;
  return encodeRiv([
    { type: TypeKey.Backboard, props: {} },
    ...iconArtboard(),
    ...croppedArtboard(MascotContract.artboards.face, { face: Color.face, ink: Color.ink, hands: true }, grow(MascotBounds.face, margin)),
    ...croppedArtboard(MascotContract.artboards.mark, { ink: Color.black }, grow(MascotBounds.mark, margin)),
    ...croppedArtboard(MascotContract.artboards.loader, { face: Color.face, ink: Color.ink }, grow(MascotBounds.loader, margin), true),
  ]);
}
