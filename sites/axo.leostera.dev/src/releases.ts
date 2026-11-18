/** The exact bytes served for one artifact (RFD0075). */
export type ArtifactIntegrity = Readonly<{ sha256: string; size: number }>;

/** The one mutable pointer; filenames are immutable basenames relative to /cdn/. */
export type Release = Readonly<{
  version: string;
  build: number;
  axodBuild: number;
  commit: string;
  artifacts: Readonly<Record<string, string>>;
  /** Absent only in pointers published before RFD0075; otherwise one entry per artifact. */
  integrity?: Readonly<Record<string, ArtifactIntegrity>>;
}>;
export const LATEST_RELEASE_KEY = "latest.json";
export const ARTIFACT_PREFIX = "releases/";
export const TARGET = /^[a-z0-9_]+(?:-[a-z0-9]+){2,4}$/;
export const ARTIFACT = /^axo-(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})-[a-f0-9]{12}-[a-z0-9_]+(?:-[a-z0-9]+){2,4}\.(?:zip|tar\.gz)$/;

export function parseRelease(value: unknown): Release {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid release manifest");
  const record = value as Record<string, unknown>;
  if (Object.keys(record).some(key => !["version", "build", "axodBuild", "commit", "artifacts", "integrity"].includes(key))
    || typeof record.version !== "string" || !/^(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})$/.test(record.version)
    || !Number.isSafeInteger(record.build) || Number(record.build) <= 0
    || !Number.isSafeInteger(record.axodBuild) || Number(record.axodBuild) <= 0
    || typeof record.commit !== "string" || !/^[a-f0-9]{40}$/.test(record.commit)
    || !record.artifacts || typeof record.artifacts !== "object" || Array.isArray(record.artifacts)) throw new Error("invalid release fields");
  const entries = Object.entries(record.artifacts);
  if (entries.length < 1 || entries.length > 32) throw new Error("invalid release artifact count");
  const prefix = `axo-${record.version}-${record.commit.slice(0, 12)}-`;
  const artifacts: Record<string, string> = Object.create(null);
  for (const [target, file] of entries) {
    if (!TARGET.test(target) || typeof file !== "string" || !ARTIFACT.test(file)
      || !(file === `${prefix}${target}.zip` || (!target.endsWith("apple-darwin") && file === `${prefix}${target}.tar.gz`)))
      throw new Error("artifact does not match release identity/target");
    artifacts[target] = file;
  }
  const parsed = { version: record.version, build: Number(record.build), axodBuild: Number(record.axodBuild), commit: record.commit, artifacts: Object.freeze(artifacts) };
  if (record.integrity === undefined) return Object.freeze(parsed);
  return Object.freeze({ ...parsed, integrity: parseIntegrity(record.integrity, Object.keys(artifacts)) });
}

/** Exactly the artifacts' targets, each with a lowercase SHA-256 and a positive byte size. */
function parseIntegrity(value: unknown, targets: readonly string[]): Readonly<Record<string, ArtifactIntegrity>> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid release integrity");
  const entries = Object.entries(value);
  if (entries.length !== targets.length || entries.some(([target]) => !targets.includes(target)))
    throw new Error("release integrity does not match its artifacts");
  const integrity: Record<string, ArtifactIntegrity> = Object.create(null);
  for (const [target, entry] of entries) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) throw new Error("invalid artifact integrity");
    const { sha256, size, ...rest } = entry as Record<string, unknown>;
    if (Object.keys(rest).length > 0 || typeof sha256 !== "string" || !/^[a-f0-9]{64}$/.test(sha256)
      || !Number.isSafeInteger(size) || Number(size) <= 0) throw new Error("invalid artifact integrity");
    integrity[target] = Object.freeze({ sha256, size: Number(size) });
  }
  return Object.freeze(integrity);
}
export function macArtifact(release: Release, target = "aarch64-apple-darwin"): string | undefined {
  return release.artifacts[target] ?? release.artifacts["universal-apple-darwin"];
}
