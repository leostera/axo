import { z } from "zod";

export const protocolVersion = 1 as const;
export const hostIdSchema = z.uuid();
export const hostGenerationSchema = z.uuid();
export const hostCapabilitySchema = z.object({
  id: z.enum(["agent.pi", "terminal.pty", "workspace.filesystem"]),
  version: z.number().int().positive().max(255),
}).strict();
export const hostCapabilitiesSchema = z.array(hostCapabilitySchema).max(32).superRefine((capabilities, context) => {
  const ids = new Set<string>();
  capabilities.forEach((capability, index) => {
    if (ids.has(capability.id)) context.addIssue({ code: "custom", path: [index, "id"], message: "host capability IDs must be unique" });
    ids.add(capability.id);
  });
});
export const sessionIdSchema = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
export const shellIdSchema = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
export const hostRefSchema = z.object({
  hostId: hostIdSchema,
  hostGeneration: hostGenerationSchema,
}).strict();

const paneLayoutSchema = z.object({
  kind: z.literal("pane"),
  shellId: shellIdSchema,
}).strict();
export type PaneLayout = z.infer<typeof paneLayoutSchema>;
export type SplitLayout = {
  kind: "split";
  id: string;
  direction: "right" | "down";
  ratio: number;
  first: Layout;
  second: Layout;
};
export type Layout = PaneLayout | SplitLayout;
const layoutSchema: z.ZodType<Layout> = z.lazy(() => z.discriminatedUnion("kind", [
  paneLayoutSchema,
  z.object({
    kind: z.literal("split"),
    id: z.uuid(),
    direction: z.enum(["right", "down"]),
    ratio: z.number().min(0.01).max(0.99),
    first: layoutSchema,
    second: layoutSchema,
  }).strict(),
]));
export { layoutSchema };

export const sessionSnapshotSchema = z.object({
  hostId: hostIdSchema,
  sessionId: sessionIdSchema,
  sessionUuid: z.uuid().optional(),
  workspaceId: z.uuid().nullable().optional(),
  workspaceName: z.string().max(80).nullable().optional(),
  name: z.string().min(1).max(80).optional(),
  emoji: z.string().min(1).max(16).refine(value => value.trim() === value && !/[\p{Cc}\p{White_Space}]/u.test(value)).nullable().optional(),
  status: z.enum(["starting", "ready", "working", "needsAttention", "unavailable"]).optional(),
  hasAgent: z.boolean().optional(),
  shells: z.array(z.object({ shellId: shellIdSchema }).strict()).max(256),
  layout: layoutSchema.nullable(),
  updatedAt: z.string().datetime({ offset: true }),
}).strict();
export type SessionSnapshot = z.infer<typeof sessionSnapshotSchema>;

function checkSessionOwnership(
  hostId: string,
  sessions: SessionSnapshot[],
  context: z.RefinementCtx,
): void {
  const sessionIds = new Set<number>();
  sessions.forEach((session, index) => {
    if (session.hostId !== hostId) {
      context.addIssue({
        code: "custom",
        path: ["sessions", index, "hostId"],
        message: "session must reference its owning host",
      });
    }
    if (sessionIds.has(session.sessionId)) {
      context.addIssue({
        code: "custom",
        path: ["sessions", index, "sessionId"],
        message: "session identifiers must be unique within a host",
      });
    }
    sessionIds.add(session.sessionId);

    const shellIds = session.shells.map(({ shellId }) => shellId);
    if (new Set(shellIds).size !== shellIds.length) {
      context.addIssue({
        code: "custom",
        path: ["sessions", index, "shells"],
        message: "shell identifiers must be unique within a session",
      });
    }
    if (session.layout) {
      const layoutShellIds: number[] = [];
      const visit = (layout: Layout) => {
        if (layout.kind === "pane") layoutShellIds.push(layout.shellId);
        else {
          visit(layout.first);
          visit(layout.second);
        }
      };
      visit(session.layout);
      if (
        layoutShellIds.length !== shellIds.length ||
        layoutShellIds.some((shellId) => !shellIds.includes(shellId)) ||
        new Set(layoutShellIds).size !== layoutShellIds.length
      ) {
        context.addIssue({
          code: "custom",
          path: ["sessions", index, "layout"],
          message: "layout must contain each session shell exactly once",
        });
      }
    }
  });
}

export const hostSnapshotSchema = z.object({
  hostId: hostIdSchema,
  hostGeneration: hostGenerationSchema,
  label: z.string().min(1).max(128),
  hostKind: z.string().regex(/^[a-z][a-z0-9-]{0,63}$/),
  capabilities: hostCapabilitiesSchema.optional(),
  status: z.enum(["online", "offline"]),
  stale: z.boolean(),
  lastSeenAt: z.string().datetime({ offset: true }),
  sessions: z.array(sessionSnapshotSchema).max(256),
}).strict().superRefine((host, context) => {
  checkSessionOwnership(host.hostId, host.sessions, context);
  if (host.stale !== (host.status === "offline")) {
    context.addIssue({ code: "custom", path: ["stale"], message: "offline hosts must be explicitly stale" });
  }
});
export type HostSnapshot = z.infer<typeof hostSnapshotSchema>;

export const hostRegisterSchema = z.object({
  protocolVersion: z.literal(protocolVersion),
  hostId: hostIdSchema,
  hostGeneration: hostGenerationSchema,
  label: z.string().min(1).max(128),
  hostKind: z.string().regex(/^[a-z][a-z0-9-]{0,63}$/),
  capabilities: hostCapabilitiesSchema.optional(),
  sessions: z.array(sessionSnapshotSchema).max(256),
}).strict().superRefine((registration, context) => {
  checkSessionOwnership(registration.hostId, registration.sessions, context);
});
export const hostHeartbeatSchema = hostRefSchema;
export const hostSessionsPublishSchema = z.object({
  hostId: hostIdSchema,
  hostGeneration: hostGenerationSchema,
  sessions: z.array(sessionSnapshotSchema).max(256),
}).strict().superRefine((publication, context) => {
  checkSessionOwnership(publication.hostId, publication.sessions, context);
});
const emptyParamsSchema = z.object({}).strict();
const subscriptionIdSchema = z.object({ subscriptionId: z.uuid() }).strict();
const targetSchema = z.object({ target: hostRefSchema }).strict();
const sessionTargetSchema = targetSchema.extend({ sessionId: sessionIdSchema }).strict();
const workspaceSessionTargetSchema = targetSchema.extend({ workspaceId: z.uuid() }).strict();
const shellTargetSchema = sessionTargetSchema.extend({ shellId: shellIdSchema }).strict();

export const hostV1Methods = {
  "axo.host.register": hostRegisterSchema,
  "axo.host.heartbeat": hostHeartbeatSchema,
  "axo.host.sessions.publish": hostSessionsPublishSchema,
  "axo.host.list": emptyParamsSchema,
  "axo.host.sessions.list": hostRefSchema,
  "axo.host.subscribe": hostRefSchema,
  "axo.host.unsubscribe": subscriptionIdSchema,
  "axo.remote.workspace.list": targetSchema,
  "axo.remote.session.create": targetSchema,
  "axo.remote.workspace.session.create": workspaceSessionTargetSchema,
  "axo.remote.session.close": sessionTargetSchema,
  "axo.remote.shell.create": sessionTargetSchema,
  "axo.remote.shell.close": shellTargetSchema,
  "axo.remote.session.rename": sessionTargetSchema.extend({ name: z.string().min(1).max(80) }).strict(),
  "axo.remote.session.layout.set": sessionTargetSchema.extend({ layout: layoutSchema }).strict(),
  "axo.remote.terminal.input": shellTargetSchema.extend({
    sequence: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
    data: z.base64().min(4).max(65_536),
  }).strict(),
  "axo.remote.session.prompt": sessionTargetSchema.extend({ text: z.string().min(1).max(16_000) }).strict(),
  "axo.remote.session.key": sessionTargetSchema.extend({ key: z.enum(["escape", "enter"]) }).strict(),
  "axo.remote.terminal.resize": shellTargetSchema.extend({
    rows: z.number().int().min(1).max(65_535),
    columns: z.number().int().min(1).max(65_535),
  }).strict(),
} as const;
export type HostMethod = keyof typeof hostV1Methods;
export type HostMethodParams<Method extends HostMethod> = z.infer<(typeof hostV1Methods)[Method]>;
export const hostMutationMethods = [
  "axo.host.register",
  "axo.host.heartbeat",
  "axo.host.sessions.publish",
  "axo.host.subscribe",
  "axo.host.unsubscribe",
  "axo.remote.session.create",
  "axo.remote.workspace.session.create",
  "axo.remote.session.close",
  "axo.remote.session.rename",
  "axo.remote.shell.create",
  "axo.remote.shell.close",
  "axo.remote.session.layout.set",
  "axo.remote.terminal.input",
  "axo.remote.session.prompt",
  "axo.remote.session.key",
  "axo.remote.terminal.resize",
] as const;

export const hostRegisterResultSchema = z.object({ host: hostSnapshotSchema }).strict();
export const heartbeatResultSchema = z.object({
  acknowledged: z.literal(true),
  lastSeenAt: z.string().datetime({ offset: true }),
}).strict();
export const sessionsPublishResultSchema = z.object({
  storedAt: z.string().datetime({ offset: true }),
}).strict();
export const hostListResultSchema = z.object({ hosts: z.array(hostSnapshotSchema).max(256) }).strict();
export const hostSessionsListResultSchema = z.object({
  host: hostSnapshotSchema,
  sessions: z.array(sessionSnapshotSchema).max(256),
}).strict();
export const hostSubscribeResultSchema = z.object({ subscriptionId: z.uuid() }).strict();
export const hostUnsubscribeResultSchema = z.object({ unsubscribed: z.literal(true) }).strict();
export const remoteWorkspaceListResultSchema = z.object({
  workspaces: z.array(z.object({ workspaceId: z.uuid(), name: z.string().min(1).max(256), home: z.literal(true).optional() }).strict()).max(256),
}).strict();
export const remoteSessionCreateResultSchema = z.object({ session: sessionSnapshotSchema }).strict();
export const remoteSessionCloseResultSchema = z.object({
  closed: z.literal(true),
  sessionId: sessionIdSchema,
  replacement: sessionSnapshotSchema.nullable(),
}).strict();
export const remoteShellCreateResultSchema = z.object({
  hostId: hostIdSchema,
  sessionId: sessionIdSchema,
  shellId: shellIdSchema,
}).strict();
export const remoteShellCloseResultSchema = z.object({
  closed: z.literal(true),
  hostId: hostIdSchema,
  sessionId: sessionIdSchema,
  shellId: shellIdSchema,
}).strict();
export const remoteLayoutSetResultSchema = z.object({ saved: z.literal(true) }).strict();
export const remoteTerminalInputResultSchema = z.object({
  accepted: z.literal(true),
  sequence: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
}).strict();
export const remotePromptResultSchema = z.object({ accepted: z.literal(true) }).strict();
export const remoteTerminalResizeResultSchema = z.object({
  accepted: z.literal(true),
  rows: z.number().int().min(1).max(65_535),
  columns: z.number().int().min(1).max(65_535),
}).strict();

export const hostV1Results = {
  "axo.host.register": hostRegisterResultSchema,
  "axo.host.heartbeat": heartbeatResultSchema,
  "axo.host.sessions.publish": sessionsPublishResultSchema,
  "axo.host.list": hostListResultSchema,
  "axo.host.sessions.list": hostSessionsListResultSchema,
  "axo.host.subscribe": hostSubscribeResultSchema,
  "axo.host.unsubscribe": hostUnsubscribeResultSchema,
  "axo.remote.workspace.list": remoteWorkspaceListResultSchema,
  "axo.remote.session.create": remoteSessionCreateResultSchema,
  "axo.remote.workspace.session.create": remoteSessionCreateResultSchema,
  "axo.remote.session.close": remoteSessionCloseResultSchema,
  "axo.remote.shell.create": remoteShellCreateResultSchema,
  "axo.remote.shell.close": remoteShellCloseResultSchema,
  "axo.remote.session.rename": remoteLayoutSetResultSchema,
  "axo.remote.session.layout.set": remoteLayoutSetResultSchema,
  "axo.remote.terminal.input": remoteTerminalInputResultSchema,
  "axo.remote.session.prompt": remotePromptResultSchema,
  "axo.remote.session.key": remotePromptResultSchema,
  "axo.remote.terminal.resize": remoteTerminalResizeResultSchema,
} as const;

export const hostPresenceEventSchema = z.object({
  type: z.literal("host.presence"),
  hostId: hostIdSchema,
  hostGeneration: hostGenerationSchema,
  status: z.enum(["online", "offline"]),
  observedAt: z.string().datetime({ offset: true }),
}).strict();
const piEventDataSchema = z.unknown().refine(value => {
  try {
    const encoded = JSON.stringify(value);
    return encoded !== undefined && new TextEncoder().encode(encoded).byteLength <= 60_000;
  } catch {
    return false;
  }
}, "Pi event data must be JSON and no larger than 60000 bytes");

export const hostDataEventSchema = z.object({
  type: z.literal("host.data"),
  hostId: hostIdSchema,
  hostGeneration: hostGenerationSchema,
  event: z.discriminatedUnion("type", [
    z.object({ type: z.literal("session.snapshot"), snapshot: sessionSnapshotSchema }).strict(),
    z.object({ type: z.literal("session.removed"), sessionId: sessionIdSchema }).strict(),
    z.object({
      type: z.literal("shell.activity"),
      sessionId: sessionIdSchema,
      shellId: shellIdSchema,
      activity: z.enum(["started", "exited", "attached", "detached"]),
    }).strict(),
    z.object({
      type: z.literal("terminal.output"),
      sessionId: sessionIdSchema,
      shellId: shellIdSchema,
      sequence: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
      data: z.base64().min(4).max(131_072),
    }).strict(),
    z.object({
      type: z.literal("pi.event"),
      sessionId: sessionIdSchema,
      piSessionId: z.string().min(1).max(128).refine(value => !/[\u0000-\u001f\u007f]/u.test(value)),
      streamId: z.uuid(),
      sequence: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
      name: z.string().min(1).max(128).refine(value => !/[\u0000-\u001f\u007f]/u.test(value)),
      data: piEventDataSchema,
    }).strict(),
  ]),
}).strict().superRefine((hostEvent, context) => {
  if (hostEvent.event.type === "session.snapshot" && hostEvent.event.snapshot.hostId !== hostEvent.hostId) {
    context.addIssue({
      code: "custom",
      path: ["event", "snapshot", "hostId"],
      message: "session snapshot must reference its owning host",
    });
  }
});
export const hostEventSchema = z.discriminatedUnion("type", [hostPresenceEventSchema, hostDataEventSchema]);
export const hostRelayNotificationSchema = z.object({
  jsonrpc: z.literal("2.0"),
  method: z.literal("axo.host.event"),
  params: hostDataEventSchema,
}).strict();
export const hostNotificationSchema = z.object({
  jsonrpc: z.literal("2.0"),
  method: z.literal("axo.host.event"),
  params: z.object({ subscriptionId: z.uuid(), event: hostEventSchema }).strict(),
}).strict();
export type HostEvent = z.infer<typeof hostEventSchema>;
export type HostDataEvent = z.infer<typeof hostDataEventSchema>;

export * from "./pairing.js";
