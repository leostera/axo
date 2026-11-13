import { z } from "zod";
import {
  ASSET_LIMITS,
  ASSETS_NAMESPACE,
  assetsGetInputSchema,
  assetsListInputSchema,
  assetsReadInputSchema,
  assetsSaveInputSchema,
  type AssetsReadResult,
  type ToolDefinition,
} from "@axo/protocol";
import { AssetRefused, savedFile, type AccountAssets } from "../assets/store";

/**
 * `codemode.assets` (RFD0030, Assets from scripts): a script lists the account's assets, reads one
 * in ranges, and saves what it made. Files an app tool fetched (a Gmail attachment) are saved by
 * that tool, never through the script; a script hands any of them on by returning the file.
 */

const TOOLS = {
  list: {
    title: "List the account's assets",
    description:
      "The account's files, newest first: { assets: [{ asset, name, mimeType, size, createdAt, version }], next, usage }. " +
      "Pass next as before for the next page.",
    input: assetsListInputSchema,
  },
  get: {
    title: "Get an asset as a file",
    description:
      "One asset as { type: \"file\", attachment: { asset, name, mimeType, size }, url }. Returned from a script, the Mac that " +
      "ran it saves the file under ~/.axo/assets and says where; url opens it in a browser signed in to Axo.",
    input: assetsGetInputSchema,
  },
  read: {
    title: "Read part of an asset",
    description:
      `Reads up to ${ASSET_LIMITS.readBytes} bytes of an asset from offset: { asset, offset, length, size, eof, as, data }, data ` +
      "as UTF-8 text or base64. Read a larger file in ranges, offset += length until eof.",
    input: assetsReadInputSchema,
  },
  save: {
    title: "Save a file as an asset",
    description:
      `Stores up to ${ASSET_LIMITS.scriptSaveBytes} bytes a script made, given as text or base64, as an asset named name; the same ` +
      "bytes saved twice are one asset. Answers the file, as get does.",
    input: assetsSaveInputSchema,
  },
} as const;

type AssetTool = keyof typeof TOOLS;

export function assetToolDefinitions(): ToolDefinition[] {
  return (Object.entries(TOOLS) as Array<[AssetTool, (typeof TOOLS)[AssetTool]]>).map(([name, tool]) => ({
    service: ASSETS_NAMESPACE,
    name,
    title: tool.title,
    description: tool.description,
    inputSchema: z.toJSONSchema(tool.input, { io: "input" }) as Record<string, unknown>,
    call: `codemode.${ASSETS_NAMESPACE}.${name}`,
  }));
}

export function isAssetTool(tool: string): tool is AssetTool {
  return Object.hasOwn(TOOLS, tool);
}

/** Runs one `codemode.assets` call against the account's assets, as `by` (the calling Mac). */
export async function callAssetTool(assets: AccountAssets, tool: AssetTool, input: unknown, by: string): Promise<unknown> {
  const parsed = TOOLS[tool].input.safeParse(input ?? {});
  if (!parsed.success) throw new Error(`assets.${tool}: ${z.prettifyError(parsed.error)}`);
  switch (tool) {
    case "list": {
      const { before, limit } = parsed.data as z.infer<typeof assetsListInputSchema>;
      return assets.list(before === undefined ? null : Number(before), limit);
    }
    case "get": {
      const { asset } = parsed.data as z.infer<typeof assetsGetInputSchema>;
      const found = await assets.head(asset.slice("sha256:".length));
      if (!found) throw new Error(`no asset ${asset} in this account`);
      return savedFile(found);
    }
    case "read": {
      const { asset, offset = 0, length = ASSET_LIMITS.readBytes, as = "base64" } = parsed.data as z.infer<typeof assetsReadInputSchema>;
      const read = await assets.read(asset.slice("sha256:".length), offset, length);
      if (!read) throw new Error(`no asset ${asset} in this account`);
      const result: AssetsReadResult = {
        asset,
        offset,
        length: read.bytes.byteLength,
        size: read.asset.size,
        eof: offset + read.bytes.byteLength >= read.asset.size,
        as,
        // A range may cut a UTF-8 character in two; the decoder shows that as U+FFFD, not an error.
        data: as === "text" ? new TextDecoder().decode(read.bytes) : base64(read.bytes),
      };
      return result;
    }
    case "save": {
      const { name, mimeType, text, base64: encoded } = parsed.data as z.infer<typeof assetsSaveInputSchema>;
      const bytes = text !== undefined ? new TextEncoder().encode(text) : fromBase64(encoded!);
      if (!bytes) throw new Error("assets.save: base64 is not valid base64");
      if (bytes.byteLength > ASSET_LIMITS.scriptSaveBytes)
        throw new Error(`assets.save: a script saves at most ${ASSET_LIMITS.scriptSaveBytes} bytes at once; this is ${bytes.byteLength}`);
      try {
        return savedFile(await assets.save({ name, mimeType: mimeType ?? (text !== undefined ? "text/plain" : "application/octet-stream"), bytes }, by));
      } catch (error) {
        if (error instanceof AssetRefused) throw new Error(`assets.save: ${error.message}`);
        throw error;
      }
    }
  }
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

function fromBase64(text: string): Uint8Array<ArrayBuffer> | null {
  try {
    const binary = atob(text.replace(/\s+/g, ""));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}
