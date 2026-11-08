/**
 * A Durable Object's SQLite schema, applied once per object instead of on every wake (RFD0032,
 * Release P). Each step runs once, in order, and the number applied is stored. Steps must be
 * idempotent and additive: an object created before this existed already has some of their
 * tables, and runs them all once; a release rolled back to reads the tables a newer one made.
 */
export type SchemaStep = (sql: SqlStorage) => void;

/**
 * Applies the steps this object has not applied yet, and returns how many were applied. A stored
 * version past `steps` was written by a newer release, and applies nothing: its steps were
 * additive, so this release's tables are all there.
 */
export function migrate(storage: DurableObjectStorage, steps: readonly SchemaStep[]): number {
  const sql = storage.sql;
  sql.exec("CREATE TABLE IF NOT EXISTS schema_version (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), version INTEGER NOT NULL)");
  const stored = sql.exec<{ version: number }>("SELECT version FROM schema_version WHERE singleton = 1").toArray()[0]?.version ?? 0;
  if (stored >= steps.length) return 0;
  storage.transactionSync(() => {
    for (const step of steps.slice(stored)) step(sql);
    sql.exec(`INSERT INTO schema_version (singleton, version) VALUES (1, ?)
      ON CONFLICT(singleton) DO UPDATE SET version = excluded.version`, steps.length);
  });
  return steps.length - stored;
}

/** Adds the columns a table lacks; an existing column is left as it is. */
export function addColumns(sql: SqlStorage, table: string, columns: Record<string, string>): void {
  const have = new Set(sql.exec<{ name: string }>(`PRAGMA table_info(${table})`).toArray().map((row) => row.name));
  for (const [name, type] of Object.entries(columns)) if (!have.has(name)) sql.exec(`ALTER TABLE ${table} ADD COLUMN ${name} ${type}`);
}
