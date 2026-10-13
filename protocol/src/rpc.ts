import { z } from "zod";
import {
  JSONRPCClient,
  JSONRPCServer,
  JSONRPCErrorException,
  type SendRequest,
  type TypedJSONRPCClient,
  type TypedJSONRPCServer,
} from "json-rpc-2.0";
import {
  decode,
  callSchema,
  replySchema,
  failure,
  negotiateSchema,
  registrationSchema,
  machineListResultSchema,
  localMethods,
  workMutationMethods,
  piMutationMethods,
  stateMutationMethods,
  type LocalMethod,
  results,
  type Reply,
} from "./contracts.js";

export type Negotiated = {
  protocolVersion: 1;
  methods: string[];
  deliveryCredits: { frames: number; bytes: number };
};
export type Registered = { leaseId: string; hostGeneration: string; leaseExpiresAt?: number };
export type Heartbeat = { leaseId: string; leaseExpiresAt?: number };
export type DaemonMethods = {
  [Method in LocalMethod]: (
    params: z.input<(typeof localMethods)[Method]>,
  ) => z.output<(typeof results)[Method]>;
};
export type ServiceMethods = {
  "axo.protocol.negotiate": (
    params: z.input<typeof negotiateSchema>,
  ) => Negotiated;
  "axo.machine.register": (
    params: z.input<typeof registrationSchema>,
  ) => Registered;
  "axo.machine.heartbeat": (params: Heartbeat) => Heartbeat;
  "axo.machine.list": (
    params: Record<string, never>,
  ) => z.output<typeof machineListResultSchema>;
};
export type AxoMethods = ServiceMethods & DaemonMethods;
export type AxoClient<Context = void> = TypedJSONRPCClient<AxoMethods, Context>;
export type AxoServer<Context = void> = TypedJSONRPCServer<AxoMethods, Context>;

export function createAxoClient<Context = void>(
  send: SendRequest<Context>,
): AxoClient<Context> {
  return new JSONRPCClient<Context>(send, () => crypto.randomUUID());
}
export function createProfileServer<Context = void>(): JSONRPCServer<Context> {
  const server = new JSONRPCServer<Context>({ errorListener: () => {} });
  // The library defaults to console.warn(error): unsafe for credential/prompt-bearing exceptions.
  server.mapErrorToJSONRPCErrorResponse = (id, error: unknown) =>
    error instanceof JSONRPCErrorException && Number.isSafeInteger(error.code)
      ? failure(id, error.code, "Operation rejected")
      : failure(id, -32603, "Internal error");
  server.applyMiddleware((next, request, context) => {
    if (
      request.id === undefined &&
      [...workMutationMethods, ...piMutationMethods, ...stateMutationMethods, "axo.runtime.startApproved", "axo.machine.register"].includes(
        request.method,
      )
    )
      return Promise.resolve(null);
    return next(request, context);
  });
  return server;
}

/** Bounded framing/domain guards around the library, including its single-reply batch quirk. */
export async function serveProfileMessage<Context>(
  server: JSONRPCServer<Context>,
  raw: string,
  context: Context,
): Promise<Reply | Reply[] | null> {
  const decoded = decode(raw);
  if ("error" in decoded) return decoded.error;
  const responses: Reply[] = [];
  for (const entry of decoded.entries) {
    const call = callSchema.safeParse(entry);
    if (!call.success) {
      responses.push(failure(null, -32600, "Invalid Request"));
      continue;
    }
    const response = await server.receive(call.data, context);
    if (response) {
      const validated = replySchema.safeParse(response);
      responses.push(
        validated.success
          ? validated.data
          : failure(
              call.data.id ?? null,
              -32004,
              "Outcome unknown; invalid response",
            ),
      );
    }
  }
  if (!responses.length) return null;
  // json-rpc-2.0 1.8.1 collapses a one-response batch; JSON-RPC requires an array.
  const response = decoded.batch ? responses : responses[0];
  try {
    const wire = decode(JSON.stringify(response));
    if (!("error" in wire) && wire.entries.every(entry => replySchema.safeParse(entry).success))
      return response;
  } catch {
    // A handler may already have mutated state; serialization failure is not rejection.
  }
  // Preserve each request ID and the batch shape; a null-ID error cannot reconcile its command.
  const unknown = responses.map(reply => failure(reply.id, -32004, "Outcome unknown; reconcile commandId"));
  return decoded.batch ? unknown : unknown[0];
}
