import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  createAxoClient,
  createProfileServer,
  serveProfileMessage,
  JSONRPCErrorException,
  callSchema,
  decode,
  listSchema,
  replySchema,
  type DaemonMethods,
  type TypedJSONRPCServer,
  type AxoClient,
} from "@axo/protocol";

test("post-dispatch response failures stay bounded and outcome-unknown", async () => {
  const server = createProfileServer();
  let executions = 0;
  server.addMethod("large", () => {
    executions++;
    return "x".repeat(70000);
  });
  server.addMethod("unserializable", () => {
    executions++;
    return 1n;
  });
  for (const method of ["large", "unserializable"]) {
    const reply = await serveProfileMessage(
      server,
      JSON.stringify({ jsonrpc: "2.0", id: method, method }),
      undefined,
    );
    assert.ok(reply && !Array.isArray(reply) && "error" in reply);
    assert.equal(reply.error.code, -32004);
    assert.match(reply.error.message, /Outcome unknown/);
    assert.ok(JSON.stringify(reply).length < 200);
  }
  assert.equal(executions, 2); // A response error must never imply the operation did not run.
});

const target = {
  machineId: "11111111-1111-4111-8111-111111111111",
  hostGeneration: "22222222-2222-4222-8222-222222222222",
};

test("compiled package connects typed library client/server with explicit context", async () => {
  const server = createProfileServer<{ generation: string }>();
  const typed: TypedJSONRPCServer<DaemonMethods, { generation: string }> =
    server;
  typed.addMethod("axo.runtime.list", (params, context) => {
    const parsed = listSchema.safeParse(params);
    if (!parsed.success)
      throw new JSONRPCErrorException("Invalid params", -32602);
    assert.equal(parsed.data.target.hostGeneration, context.generation);
    return { hostGeneration: context.generation, terminals: [], next: null };
  });
  const client = createAxoClient(async (request: unknown) => {
    const response = await server.receive(callSchema.parse(request), {
      generation: target.hostGeneration,
    });
    if (response) client.receive(response);
  });
  const result = await client.request("axo.runtime.list", { target });
  assert.deepEqual(result, {
    hostGeneration: target.hostGeneration,
    terminals: [],
    next: null,
  });
});

test("profile shim preserves singleton batch arrays and explicit null request IDs", async () => {
  const server = createProfileServer<void>();
  server.addMethod("echo", (params) => params);
  const response = await serveProfileMessage(
    server,
    JSON.stringify([
      { jsonrpc: "2.0", id: null, method: "echo", params: {} },
      { jsonrpc: "2.0", method: "echo", params: {} },
    ]),
    undefined,
  );
  assert.ok(Array.isArray(response));
  assert.equal(response.length, 1);
  assert.equal(response[0].id, null);
  assert.ok("result" in response[0]);
});

test("execution notification middleware never invokes a mutating handler", async () => {
  let launches = 0;
  const server = createProfileServer<void>();
  server.addMethod("axo.runtime.startApproved", () => {
    launches++;
    return {};
  });
  const response = await serveProfileMessage(
    server,
    JSON.stringify({
      jsonrpc: "2.0",
      method: "axo.runtime.startApproved",
      params: {},
    }),
    undefined,
  );
  assert.equal(response, null);
  assert.equal(launches, 0);
});

test("handler exceptions do not leak bodies or use the library default logger", async (t) => {
  const warning = t.mock.method(console, "warn", () => {});
  const server = createProfileServer<void>();
  server.addMethod("fail", () => {
    throw new Error("fixture-sensitive-body");
  });
  const response = await serveProfileMessage(
    server,
    JSON.stringify({ jsonrpc: "2.0", id: 1, method: "fail" }),
    undefined,
  );
  assert.ok(response && !Array.isArray(response) && "error" in response);
  assert.equal(response.error.code, -32603);
  assert.equal(response.error.message, "Internal error");
  assert.equal(warning.mock.callCount(), 0);
});

test("shared codec fixtures retain the Rust/TypeScript boundary contract", async () => {
  const fixtures = JSON.parse(
    await readFile(
      new URL("../fixtures/envelopes.json", import.meta.url),
      "utf8",
    ),
  ) as Array<{ name: string; raw: string; errors: number[] }>;
  for (const fixture of fixtures) {
    const decoded = decode(fixture.raw);
    const errors =
      "error" in decoded
        ? [replySchema.parse(decoded.error)]
        : decoded.entries
            .filter((entry) => !callSchema.safeParse(entry).success)
            .map(() => ({ error: { code: -32600 } }));
    assert.deepEqual(
      errors.map((reply) => ("error" in reply ? reply.error.code : 0)),
      fixture.errors,
      fixture.name,
    );
  }
});

// This function is compile-only: misspelled methods/fields and wrong result assumptions fail.
function contractTypes(client: AxoClient) {
  // @ts-expect-error unknown method is not part of the contract
  client.request("axo.runtime.lsit", { target });
  // @ts-expect-error ambient selection cannot substitute for a captured target
  client.request("axo.runtime.list", { selected: true });
  // @ts-expect-error this method returns structured metadata, not a string
  const result: PromiseLike<string> = client.request("axo.runtime.list", {
    target,
  });
  return result;
}
void contractTypes;
