import { DatabaseSync } from "node:sqlite";

/**
 * A Durable Object's `SqlStorage` on node:sqlite, for testing what is built on it (such as
 * AppConnections) without a Worker: `exec` with bindings, `toArray`, `one` and `rowsWritten`.
 */
export function sqlStorage(): SqlStorage {
  const db = new DatabaseSync(":memory:");
  return {
    exec(query: string, ...bindings: unknown[]) {
      const statement = db.prepare(query);
      const reader = /^\s*(SELECT|WITH|PRAGMA)\b/i.test(query) || /\bRETURNING\b/i.test(query);
      if (reader) {
        const rows = statement.all(...(bindings as never[])) as Record<string, unknown>[];
        return cursor(rows, 0);
      }
      const { changes } = statement.run(...(bindings as never[]));
      return cursor([], Number(changes));
    },
  } as unknown as SqlStorage;
}

function cursor(rows: Record<string, unknown>[], rowsWritten: number) {
  return {
    toArray: () => rows,
    one: () => {
      if (rows.length !== 1) throw new Error(`expected one row, got ${rows.length}`);
      return rows[0];
    },
    rowsWritten,
    rowsRead: rows.length,
    [Symbol.iterator]: () => rows[Symbol.iterator](),
  };
}
