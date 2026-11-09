import { z } from "zod";
import { hostMutationMethods } from "./v1.ts";
import { JSONRPCServer, JSONRPCErrorException } from "json-rpc-2.0";
import {
  failure,
  negotiateSchema,
} from "./contracts.ts";

export type Negotiated = {
  protocolVersion: 2;
  methods: string[];
};
export type ServiceMethods = {
  "axo.protocol.negotiate": (
    params: z.input<typeof negotiateSchema>,
  ) => Negotiated;
};

/**
 * The error a peer on another protocol version gets from `axo.protocol.negotiate`. Its message is
 * fixed and safe to show, so it is not replaced by "Operation rejected".
 */
export const unsupportedProtocolVersionCode = -32010;

export function createProfileServer<Context = void>(): JSONRPCServer<Context> {
  const server = new JSONRPCServer<Context>({ errorListener: () => {} });
  // The library defaults to console.warn(error): unsafe for credential/prompt-bearing exceptions.
  server.mapErrorToJSONRPCErrorResponse = (id, error: unknown) =>
    error instanceof JSONRPCErrorException && Number.isSafeInteger(error.code)
      ? failure(id, error.code, error.code === unsupportedProtocolVersionCode ? error.message : "Operation rejected")
      : failure(id, -32603, "Internal error");
  server.applyMiddleware((next, request, context) => {
    if (
      request.id === undefined &&
      hostMutationMethods.some(
        (method) => method === request.method,
      )
    )
      return Promise.resolve(null);
    return next(request, context);
  });
  return server;
}
