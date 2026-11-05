import { defineConfig } from "@leostera/feynman/config";

// Specs are grouped into suites, one directory each: specs/<suite>/<spec>.ts.
export default defineConfig({ specs: ["specs/*/*.ts"] });
