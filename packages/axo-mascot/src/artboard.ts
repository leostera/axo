// Builds one artboard's object stream, resolving the index-based ids described in riv.ts.
import { Property, type Props, type RivObject, TypeKey } from "./riv.ts";

export interface Point {
  readonly x: number;
  readonly y: number;
}

export type ComponentId = number & { readonly __component: unique symbol };

export const Loop = { oneShot: 0, loop: 1, pingPong: 2 } as const;
export const Interpolation = { hold: 0, linear: 1 } as const;
export const StrokeCap = { butt: 0, round: 1, square: 2 } as const;
export const StrokeJoin = { miter: 0, round: 1, bevel: 2 } as const;
export const FillRule = { nonZero: 0, evenOdd: 1 } as const;

/** `StateTransitionFlags` in rive-runtime. */
const TransitionFlag = { enableExitTime: 1 << 2, exitTimeIsPercentage: 1 << 3 } as const;
/** `LayerStateFlags` in rive-runtime. */
const LayerStateFlag = { random: 1 << 0 } as const;

export interface KeyFrame {
  readonly frame: number;
  readonly value: number;
  readonly interpolation?: number;
}

export interface Track {
  readonly object: ComponentId;
  readonly property: "x" | "y" | "rotation" | "scaleX" | "scaleY" | "opacity";
  readonly frames: readonly KeyFrame[];
}

export interface AnimationSpec {
  readonly name: string;
  readonly fps?: number;
  /** In frames. */
  readonly duration: number;
  readonly loop?: number;
  readonly tracks: readonly Track[];
}

export type AnimationId = number & { readonly __animation: unique symbol };

export type InputSpec =
  | { readonly kind: "trigger"; readonly name: string }
  | { readonly kind: "bool"; readonly name: string; readonly initial?: boolean }
  | { readonly kind: "number"; readonly name: string; readonly initial?: number };

/** A transition's condition: a trigger fired, or a bool input set to `is`. */
export type ConditionSpec = { readonly trigger: string } | { readonly bool: string; readonly is: boolean };

export interface TransitionSpec {
  readonly to: string;
  /** Percent of the source animation after which the transition may run. */
  readonly exitAtPercent?: number;
  readonly weight?: number;
  /** How long the two states mix, in milliseconds. */
  readonly mixMs?: number;
  readonly when?: ConditionSpec;
}

export type StateSpec = {
  readonly name: string;
  /** Pick one allowed transition at random, by weight, instead of the first allowed. */
  readonly random?: boolean;
  readonly transitions: readonly TransitionSpec[];
} & (
  | { readonly animation: AnimationId }
  /** Mixes animations by where a number input sits between their values. */
  | { readonly blend: { readonly input: string; readonly animations: readonly { animation: AnimationId; value: number }[] } }
);

export interface LayerSpec {
  readonly name: string;
  readonly entry: string;
  readonly any: readonly TransitionSpec[];
  readonly states: readonly StateSpec[];
}

/** Layers apply in order, so a later layer wins a property both key. */
export interface StateMachineSpec {
  readonly name: string;
  readonly inputs: readonly InputSpec[];
  readonly layers: readonly LayerSpec[];
}

export class ArtboardBuilder {
  private readonly components: RivObject[];
  private readonly animations: AnimationSpec[] = [];
  private readonly stateMachines: StateMachineSpec[] = [];

  constructor(name: string, size: { width: number; height: number }) {
    this.components = [
      {
        type: TypeKey.Artboard,
        props: { name, layoutWidth: size.width, layoutHeight: size.height, clip: true, defaultStateMachineId: 0 },
      },
    ];
  }

  get root(): ComponentId {
    return 0 as ComponentId;
  }

  add(type: number, parent: ComponentId, props: Props = {}): ComponentId {
    this.components.push({ type, props: { ...props, parentId: parent } });
    return (this.components.length - 1) as ComponentId;
  }

  node(parent: ComponentId, props: Props): ComponentId {
    return this.add(TypeKey.Node, parent, props);
  }

  shape(parent: ComponentId, props: Props): ComponentId {
    return this.add(TypeKey.Shape, parent, props);
  }

  fill(shape: ComponentId, color: number, fillRule: number = FillRule.nonZero): ComponentId {
    const fill = this.add(TypeKey.Fill, shape, { name: "Fill", fillRule });
    this.add(TypeKey.SolidColor, fill, { colorValue: color });
    return fill;
  }

  stroke(shape: ComponentId, color: number, thickness: number): ComponentId {
    const stroke = this.add(TypeKey.Stroke, shape, {
      name: "Stroke",
      thickness,
      cap: StrokeCap.round,
      join: StrokeJoin.round,
    });
    this.add(TypeKey.SolidColor, stroke, { colorValue: color });
    return stroke;
  }

  ellipse(shape: ComponentId, props: { name: string; x?: number; y?: number; width: number; height: number }): ComponentId {
    return this.add(TypeKey.Ellipse, shape, {
      name: props.name,
      x: props.x ?? 0,
      y: props.y ?? 0,
      parametricWidth: props.width,
      parametricHeight: props.height,
    });
  }

  /** A path through cubic vertices; control points are absolute, in the shape's space. */
  cubicPath(
    shape: ComponentId,
    name: string,
    vertices: readonly { at: Point; in: Point; out: Point }[],
    isClosed: boolean,
  ): ComponentId {
    const path = this.add(TypeKey.PointsPath, shape, { name, isClosed });
    for (const vertex of vertices) {
      this.add(TypeKey.CubicDetachedVertex, path, {
        vertexX: vertex.at.x,
        vertexY: vertex.at.y,
        ...polar("in", vertex.at, vertex.in),
        ...polar("out", vertex.at, vertex.out),
      });
    }
    return path;
  }

  /** A closed path through straight vertices, in the shape's space. */
  polygon(shape: ComponentId, name: string, points: readonly Point[]): ComponentId {
    const path = this.add(TypeKey.PointsPath, shape, { name, isClosed: true });
    for (const point of points) this.add(TypeKey.StraightVertex, path, { vertexX: point.x, vertexY: point.y });
    return path;
  }

  animation(spec: AnimationSpec): AnimationId {
    this.animations.push(spec);
    return (this.animations.length - 1) as AnimationId;
  }

  stateMachine(spec: StateMachineSpec): void {
    this.stateMachines.push(spec);
  }

  objects(): RivObject[] {
    const objects = [...this.components];
    for (const animation of this.animations) objects.push(...encodeAnimation(animation));
    for (const machine of this.stateMachines) objects.push(...encodeStateMachine(machine, this.animations.length));
    return objects;
  }
}

function polar(prefix: "in" | "out", origin: Point, control: Point): Props {
  const dx = control.x - origin.x;
  const dy = control.y - origin.y;
  return prefix === "in"
    ? { inRotation: Math.atan2(dy, dx), inDistance: Math.hypot(dx, dy) }
    : { outRotation: Math.atan2(dy, dx), outDistance: Math.hypot(dx, dy) };
}

function encodeAnimation(spec: AnimationSpec): RivObject[] {
  const objects: RivObject[] = [
    {
      type: TypeKey.LinearAnimation,
      props: { animationName: spec.name, fps: spec.fps ?? 60, duration: spec.duration, loop: spec.loop ?? Loop.oneShot },
    },
  ];
  // Keyed properties are grouped under one keyed object per target.
  const byObject = new Map<number, Track[]>();
  for (const track of spec.tracks) byObject.set(track.object, [...(byObject.get(track.object) ?? []), track]);
  for (const [objectId, tracks] of byObject) {
    objects.push({ type: TypeKey.KeyedObject, props: { objectId } });
    for (const track of tracks) {
      objects.push({ type: TypeKey.KeyedProperty, props: { propertyKey: Property[track.property][0] } });
      for (const keyFrame of track.frames) {
        if (keyFrame.frame > spec.duration) throw new RangeError(`${spec.name}: key frame past the end`);
        objects.push({
          type: TypeKey.KeyFrameDouble,
          props: {
            frame: keyFrame.frame,
            keyFrameValue: keyFrame.value,
            interpolationType: keyFrame.interpolation ?? Interpolation.linear,
          },
        });
      }
    }
  }
  return objects;
}

function encodeStateMachine(spec: StateMachineSpec, animationCount: number): RivObject[] {
  const inputIndex = (name: string, kind: InputSpec["kind"]): number => {
    const index = spec.inputs.findIndex((input) => input.name === name);
    if (index < 0 || spec.inputs[index]!.kind !== kind) throw new Error(`${spec.name}: no ${kind} input ${name}`);
    return index;
  };
  const animation = (id: AnimationId): number => {
    if (id >= animationCount) throw new Error(`${spec.name}: unknown animation ${id}`);
    return id;
  };

  const objects: RivObject[] = [{ type: TypeKey.StateMachine, props: { animationName: spec.name } }];
  for (const input of spec.inputs) {
    const props = { stateMachineComponentName: input.name };
    switch (input.kind) {
      case "trigger":
        objects.push({ type: TypeKey.StateMachineTrigger, props });
        break;
      case "bool":
        objects.push({ type: TypeKey.StateMachineBool, props: { ...props, boolInputValue: input.initial ?? false } });
        break;
      case "number":
        objects.push({ type: TypeKey.StateMachineNumber, props: { ...props, numberInputValue: input.initial ?? 0 } });
        break;
    }
  }

  for (const layer of spec.layers) {
    // Layer state order: entry, any, exit, then the layer's own states.
    const stateNames = ["<entry>", "<any>", "<exit>", ...layer.states.map((state) => state.name)];
    const stateIndex = (name: string): number => {
      const index = stateNames.indexOf(name);
      if (index < 0) throw new Error(`${spec.name}/${layer.name}: unknown state ${name}`);
      return index;
    };
    const transition = (t: TransitionSpec): RivObject[] => {
      const exit = t.exitAtPercent !== undefined;
      const objects: RivObject[] = [
        {
          type: TypeKey.StateTransition,
          props: {
            stateToId: stateIndex(t.to),
            transitionFlags: exit ? TransitionFlag.enableExitTime | TransitionFlag.exitTimeIsPercentage : 0,
            exitTime: t.exitAtPercent ?? 0,
            transitionDuration: t.mixMs ?? 0,
            randomWeight: t.weight ?? 1,
          },
        },
      ];
      if (t.when !== undefined) {
        if ("trigger" in t.when) {
          objects.push({ type: TypeKey.TransitionTriggerCondition, props: { inputId: inputIndex(t.when.trigger, "trigger") } });
        } else {
          objects.push({
            type: TypeKey.TransitionBoolCondition,
            // TransitionConditionOp: equal (0) passes when the bool is true, notEqual (1) when false.
            props: { inputId: inputIndex(t.when.bool, "bool"), conditionOp: t.when.is ? 0 : 1 },
          });
        }
      }
      return objects;
    };

    objects.push({ type: TypeKey.StateMachineLayer, props: { stateMachineComponentName: layer.name } });
    objects.push({ type: TypeKey.EntryState, props: {} }, ...transition({ to: layer.entry }));
    objects.push({ type: TypeKey.AnyState, props: {} }, ...layer.any.flatMap(transition));
    objects.push({ type: TypeKey.ExitState, props: {} });
    for (const state of layer.states) {
      const layerStateFlags = state.random ? LayerStateFlag.random : 0;
      if ("animation" in state) {
        objects.push({ type: TypeKey.AnimationState, props: { animationId: animation(state.animation), layerStateFlags } });
      } else {
        objects.push({
          type: TypeKey.BlendState1DInput,
          props: { blendInputId: inputIndex(state.blend.input, "number"), layerStateFlags },
        });
        for (const entry of state.blend.animations) {
          objects.push({
            type: TypeKey.BlendAnimation1D,
            props: { blendAnimationId: animation(entry.animation), blendAnimationValue: entry.value },
          });
        }
      }
      objects.push(...state.transitions.flatMap(transition));
    }
  }
  return objects;
}
