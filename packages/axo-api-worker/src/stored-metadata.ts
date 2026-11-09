// What the HostDO stores of a Session's metadata, read back from before a change to its shape.

/** Stored metadata from before RFD0038, as a Mac sends it now. */
export function withoutWorkspace(stored: Record<string, unknown>): Record<string, unknown> {
  const { workspaceId: _id, workspaceName: _name, ...metadata } = stored;
  if ("folderName" in metadata) return metadata;
  const path = (metadata.workspaceState as { path?: unknown } | undefined)?.path;
  const folderName = typeof path === "string" ? path.split("/").filter(Boolean).pop() ?? null : null;
  return { ...metadata, folderName };
}
