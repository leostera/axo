import { open, constants } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { localEndpointSchema } from "@axo/protocol";

/** Boot-fenced private discovery. IDs are routing metadata, not credentials. */
export async function readLocalEndpoint(path: string) {
  if (!isAbsolute(path)) throw new Error("Absolute discovery path required");
  const file = await open(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const stat = await file.stat();
    if (
      !stat.isFile() ||
      stat.uid !== process.getuid?.() ||
      stat.nlink !== 1 ||
      (stat.mode & 0o777) !== 0o600 ||
      stat.size > 4096
    )
      throw new Error("Private bounded discovery file required");
    const buffer = Buffer.alloc(4097);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
    if (bytesRead > 4096) throw new Error("Discovery size limit");
    try {
      return localEndpointSchema.parse(
        JSON.parse(buffer.subarray(0, bytesRead).toString("utf8")),
      );
    } catch {
      throw new Error("Invalid local discovery");
    }
  } finally {
    await file.close();
  }
}
