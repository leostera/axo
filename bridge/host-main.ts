import { createInterface } from "node:readline";
import { z } from "zod";
import { hostFrameSchema } from "../shared/protocol";
import { loadConfig } from "./config";
import { HostBroker } from "./host-broker";

function argument(name: string): string {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  if (!value || value.startsWith("--")) throw new Error(`Missing ${name}`);
  return value;
}

const inputSchema = z.object({ type: z.literal("mac_reply"), frame: hostFrameSchema });
const broker = new HostBroker(loadConfig(argument("--config")), {
  socketPath: argument("--socket"),
  registryPath: argument("--registry"),
  bindingDirectory: argument("--bindings"),
  onMacCommand: frame => write({ type: "mac_command", frame }),
  onStatus: message => write({ type: "status", message }),
});
function write(value: unknown): void { process.stdout.write(JSON.stringify(value) + "\n"); }

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on("line", line => {
  try {
    if (Buffer.byteLength(line) > 256 * 1024) throw new Error("Mac control message too large");
    const message = inputSchema.parse(JSON.parse(line));
    broker.replyFromMac(message.frame);
  } catch {
    write({ type: "status", message: "Ignored malformed Mac broker-control message." });
  }
});

void broker.start().catch(error => {
  write({ type: "fatal", message: error instanceof Error ? error.message : "Host broker failed to start." });
  process.exitCode = 1;
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => { broker.stop(); process.exit(0); });
}
