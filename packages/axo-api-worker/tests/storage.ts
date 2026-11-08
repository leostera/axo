import { readdirSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { Harness } from "./harness";

/**
 * Runs `query` on the SQLite file of every stored Durable Object of `className` that has the
 * table, and returns the rows. With `write`, runs it as a statement: do that only inside
 * `h.restart`, while the runtime is stopped.
 */
export function objectRows<T>(h: Harness, className: string, query: string, write = false): T[] {
  const directory = join(h.storagePath, "do", `api-test-${className}`);
  const rows: T[] = [];
  for (const name of readdirSync(directory)) {
    if (!name.endsWith(".sqlite") || name === "metadata.sqlite") continue;
    const db = new DatabaseSync(join(directory, name), { readOnly: !write });
    try {
      if (write) db.exec(query);
      else rows.push(...(db.prepare(query).all() as T[]));
    } catch (error) {
      if (!/no such (table|column)/.test(String(error))) throw error;
    } finally {
      db.close();
    }
  }
  return rows;
}
