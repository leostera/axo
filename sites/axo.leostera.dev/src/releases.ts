/** The one mutable pointer; filenames are immutable basenames relative to /cdn/. */
export type Release = Readonly<{
  version: string;
  build: number;
  axodBuild: number;
  commit: string;
  artifacts: Readonly<Record<string, string>>;
}>;
export const LATEST_RELEASE_KEY = "latest.json";
export const ARTIFACT_PREFIX = "releases/";
export const TARGET = /^[a-z0-9_]+(?:-[a-z0-9]+){2,4}$/;
export const ARTIFACT = /^axo-(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})-[a-f0-9]{12}-[a-z0-9_]+(?:-[a-z0-9]+){2,4}\.(?:zip|tar\.gz)$/;

export function parseRelease(value: unknown): Release {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid release manifest");
  const record = value as Record<string, unknown>;
  if (Object.keys(record).some(key => !["version", "build", "axodBuild", "commit", "artifacts"].includes(key))
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
  return Object.freeze({ version: record.version, build: Number(record.build), axodBuild: Number(record.axodBuild), commit: record.commit, artifacts: Object.freeze(artifacts) });
}
export function macArtifact(release: Release, target = "aarch64-apple-darwin"): string | undefined {
  return release.artifacts[target] ?? release.artifacts["universal-apple-darwin"];
}
