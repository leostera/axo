// A minimal writer for Rive runtime files (.riv), covering only what the Axo mascot uses.
//
// Format (rive-runtime `src/file.cpp`, `include/rive/runtime_header.hpp`):
//   "RIVE", varuint major, varuint minor, varuint fileId, property table of contents, objects.
//   Each object is varuint typeKey, then (varuint propertyKey, value)*, then a 0 terminator.
//   Values: uint/id = varuint, double = float32 LE, color = uint32 LE, bool = 1 byte, string = varuint
//   length + UTF-8.
//
// Ids are indices: a component's `parentId` and a keyed object's `objectId` index the artboard's
// object list (the artboard itself is 0), an animation state's `animationId` indexes the artboard's
// animations, a transition's `stateToId` indexes its layer's states, and a condition's `inputId`
// indexes its state machine's inputs. Children of a stream object (keyed properties, transitions,
// conditions) follow it directly.
//
// Type and property keys come from rive-runtime's generated `*_base.hpp` headers.

export const RIVE_MAJOR_VERSION = 7;
export const RIVE_MINOR_VERSION = 0;

export const TypeKey = {
  Backboard: 23,
  Artboard: 1,
  Node: 2,
  Shape: 3,
  Ellipse: 4,
  StraightVertex: 5,
  CubicDetachedVertex: 6,
  PointsPath: 16,
  SolidColor: 18,
  Fill: 20,
  Stroke: 24,
  KeyedObject: 25,
  KeyedProperty: 26,
  KeyFrameDouble: 30,
  LinearAnimation: 31,
  StateMachine: 53,
  StateMachineNumber: 56,
  StateMachineLayer: 57,
  StateMachineTrigger: 58,
  StateMachineBool: 59,
  AnimationState: 61,
  AnyState: 62,
  EntryState: 63,
  ExitState: 64,
  StateTransition: 65,
  TransitionTriggerCondition: 68,
  TransitionNumberCondition: 70,
  TransitionBoolCondition: 71,
  BlendAnimation1D: 75,
  BlendState1DInput: 76,
} as const;

type Field = "uint" | "double" | "color" | "bool" | "string";

/** Property keys with the wire type of their values. */
export const Property = {
  name: [4, "string"],
  parentId: [5, "uint"],
  layoutWidth: [7, "double"],
  layoutHeight: [8, "double"],
  x: [13, "double"],
  y: [14, "double"],
  rotation: [15, "double"],
  scaleX: [16, "double"],
  scaleY: [17, "double"],
  opacity: [18, "double"],
  parametricWidth: [20, "double"],
  parametricHeight: [21, "double"],
  vertexX: [24, "double"],
  vertexY: [25, "double"],
  isClosed: [32, "bool"],
  colorValue: [37, "color"],
  fillRule: [40, "uint"],
  thickness: [47, "double"],
  cap: [48, "uint"],
  join: [49, "uint"],
  objectId: [51, "uint"],
  propertyKey: [53, "uint"],
  animationName: [55, "string"],
  fps: [56, "uint"],
  duration: [57, "uint"],
  loop: [59, "uint"],
  frame: [67, "uint"],
  interpolationType: [68, "uint"],
  keyFrameValue: [70, "double"],
  inRotation: [84, "double"],
  inDistance: [85, "double"],
  outRotation: [86, "double"],
  outDistance: [87, "double"],
  stateMachineComponentName: [138, "string"],
  numberInputValue: [140, "double"],
  boolInputValue: [141, "bool"],
  animationId: [149, "uint"],
  stateToId: [151, "uint"],
  blendAnimationId: [165, "uint"],
  blendAnimationValue: [166, "double"],
  blendInputId: [167, "uint"],
  transitionFlags: [152, "uint"],
  inputId: [155, "uint"],
  conditionOp: [156, "uint"],
  conditionValue: [157, "double"],
  transitionDuration: [158, "uint"],
  exitTime: [160, "uint"],
  clip: [196, "bool"],
  defaultStateMachineId: [236, "uint"],
  layerStateFlags: [536, "uint"],
  randomWeight: [537, "uint"],
} as const satisfies Record<string, readonly [number, Field]>;

export type PropertyName = keyof typeof Property;
export type Props = Partial<Record<PropertyName, number | string | boolean>>;

export interface RivObject {
  readonly type: number;
  readonly props: Props;
}

class ByteWriter {
  private bytes: number[] = [];

  varuint(value: number): void {
    if (!Number.isInteger(value) || value < 0) throw new RangeError(`not a varuint: ${value}`);
    do {
      let byte = value % 128;
      value = Math.floor(value / 128);
      if (value > 0) byte |= 128;
      this.bytes.push(byte);
    } while (value > 0);
  }

  float32(value: number): void {
    const view = new DataView(new ArrayBuffer(4));
    view.setFloat32(0, value, true);
    for (let i = 0; i < 4; i++) this.bytes.push(view.getUint8(i));
  }

  uint32(value: number): void {
    const view = new DataView(new ArrayBuffer(4));
    view.setUint32(0, value >>> 0, true);
    for (let i = 0; i < 4; i++) this.bytes.push(view.getUint8(i));
  }

  ascii(text: string): void {
    for (const char of text) this.bytes.push(char.charCodeAt(0));
  }

  string(text: string): void {
    const utf8 = new TextEncoder().encode(text);
    this.varuint(utf8.length);
    this.bytes.push(...utf8);
  }

  finish(): Uint8Array {
    return Uint8Array.from(this.bytes);
  }
}

function writeValue(writer: ByteWriter, name: PropertyName, field: Field, value: number | string | boolean): void {
  switch (field) {
    case "uint":
      if (typeof value !== "number") throw new TypeError(`${name} must be a number`);
      writer.varuint(value);
      return;
    case "double":
      if (typeof value !== "number" || !Number.isFinite(value)) throw new TypeError(`${name} must be finite`);
      writer.float32(value);
      return;
    case "color":
      if (typeof value !== "number") throw new TypeError(`${name} must be an ARGB number`);
      writer.uint32(value);
      return;
    case "bool":
      if (typeof value !== "boolean") throw new TypeError(`${name} must be a boolean`);
      writer.varuint(value ? 1 : 0);
      return;
    case "string":
      if (typeof value !== "string") throw new TypeError(`${name} must be a string`);
      writer.string(value);
      return;
  }
}

/** Serializes `objects` in order. Every property used is known to the runtime, so the ToC is empty. */
export function encodeRiv(objects: readonly RivObject[]): Uint8Array {
  const writer = new ByteWriter();
  writer.ascii("RIVE");
  writer.varuint(RIVE_MAJOR_VERSION);
  writer.varuint(RIVE_MINOR_VERSION);
  writer.varuint(0); // file id
  writer.varuint(0); // end of the property table of contents
  for (const object of objects) {
    writer.varuint(object.type);
    for (const [name, value] of Object.entries(object.props) as [PropertyName, number | string | boolean][]) {
      if (value === undefined) continue;
      const [key, field] = Property[name];
      writer.varuint(key);
      writeValue(writer, name, field, value);
    }
    writer.varuint(0);
  }
  return writer.finish();
}
