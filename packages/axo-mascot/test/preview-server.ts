// Serves the preview page, the Rive web runtime and assets/mascot/axo.riv.
import { readFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { extname, resolve } from "node:path";

const packageRoot = resolve(import.meta.dirname, "..");
const rivPath = resolve(packageRoot, "../../assets/mascot/axo.riv");
const types: Record<string, string> = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".wasm": "application/wasm",
  ".riv": "application/octet-stream",
};

/** `riv` replaces the committed file, e.g. with a measuring build. */
export function startPreviewServer(port = 0, riv?: Uint8Array): Promise<{ server: Server; url: string }> {
  const server = createServer(async (request, response) => {
    const path = new URL(request.url ?? "/", "http://localhost").pathname;
    const file =
      path === "/" ? resolve(packageRoot, "preview/index.html")
      : path === "/axo.riv" ? rivPath
      : path.startsWith("/node_modules/@rive-app/canvas/") ? resolve(packageRoot, `.${path}`)
      : undefined;
    if (file === undefined) {
      response.writeHead(404).end();
      return;
    }
    try {
      const body = file === rivPath && riv !== undefined ? Buffer.from(riv) : await readFile(file);
      response.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream", "cache-control": "no-store" });
      response.end(body);
    } catch {
      response.writeHead(404).end();
    }
  });
  return new Promise((done) => {
    server.listen(port, "127.0.0.1", () => {
      const address = server.address();
      if (address === null || typeof address === "string") throw new Error("no address");
      done({ server, url: `http://127.0.0.1:${address.port}/` });
    });
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { url } = await startPreviewServer(Number(process.env.PORT ?? 4177));
  console.log(`Axo mascot preview: ${url}`);
}
