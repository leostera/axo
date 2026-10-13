import { z } from "zod";
import { readFile, writeFile } from "node:fs/promises";
import {
  callSchema,
  replySchema,
  negotiateSchema,
  registrationSchema,
  localEndpointSchema,
  machineListResultSchema,
  remoteMethods,
  results,
  workMethods,
  workResults,
  localWorkMethods,
  localWorkResults,
  piMethods,
  piResults,
  stateRemoteMethods,
  stateLocalMethods,
  stateResults,
} from "./src/index.js";

const definitions: Record<string, unknown> = {};
for (const [name, schema] of Object.entries({
  call: callSchema,
  reply: replySchema,
  negotiate: negotiateSchema,
  registration: registrationSchema,
  localEndpoint: localEndpointSchema,
  machineListResult: machineListResultSchema,
  runtimeListParams: remoteMethods["axo.runtime.list"],
  runtimeStartApprovedParams: remoteMethods["axo.runtime.startApproved"],
  runtimeListResult: results["axo.runtime.list"],
  runtimeStartApprovedResult: results["axo.runtime.startApproved"],
  ...Object.fromEntries(Object.entries(workMethods).map(([method, schema]) => [`${method}Params`, schema])),
  ...Object.fromEntries(Object.entries(workResults).map(([method, schema]) => [`${method}Result`, schema])),
  ...Object.fromEntries(Object.entries(localWorkMethods).map(([method, schema]) => [`${method}Params`, schema])),
  ...Object.fromEntries(Object.entries(localWorkResults).map(([method, schema]) => [`${method}Result`, schema])),
  ...Object.fromEntries(Object.entries(piMethods).map(([method, schema]) => [`${method}Params`, schema])),
  ...Object.fromEntries(Object.entries(piResults).map(([method, schema]) => [`${method}Result`, schema])),
  ...Object.fromEntries(Object.entries({...stateRemoteMethods, ...stateLocalMethods}).map(([method, schema]) => [`${method}Params`, schema])),
  ...Object.fromEntries(Object.entries(stateResults).map(([method, schema]) => [`${method}Result`, schema])),
})) {
  const converted = z.toJSONSchema(schema, {
    target: "draft-2020-12",
    io: "input",
    unrepresentable: "any",
  });
  delete converted.$schema;
  definitions[name] = converted;
}
// JSON has no undefined: a success response must explicitly carry result, including null.
const reply = definitions.reply as { anyOf: Array<{ required: string[] }> };
reply.anyOf[0].required = ["jsonrpc", "id", "result"];
const encoded =
  JSON.stringify(
    {
      $schema: "https://json-schema.org/draft/2020-12/schema",
      $defs: definitions,
      anyOf: [
        { $ref: "#/$defs/call" },
        { $ref: "#/$defs/reply" },
        {
          type: "array",
          minItems: 1,
          maxItems: 8,
          items: {
            anyOf: [{ $ref: "#/$defs/call" }, { $ref: "#/$defs/reply" }],
          },
        },
      ],
    },
    null,
    2,
  ) + "\n";
const path = new URL("./schemas.json", import.meta.url);
if (process.argv.includes("--check")) {
  if ((await readFile(path, "utf8")) !== encoded)
    throw new Error("Protocol schema drift; run generate-schema.ts");
} else {
  await writeFile(path, encoded);
}
