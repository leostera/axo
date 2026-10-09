import { catalogSchema, type WorkbenchCatalog } from "../../shared/protocol";

export const CATALOG_PAGE_SIZE = 50;

/** The Mac owns the catalog; this row is a durable replica used for phone paging and recovery. */
export class CatalogStore {
  constructor(private readonly storage: DurableObjectStorage) {
    storage.sql.exec(`CREATE TABLE IF NOT EXISTS workbench_catalog (
      singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
      revision INTEGER NOT NULL,
      payload TEXT NOT NULL
    )`);
  }

  read(): WorkbenchCatalog {
    const row = this.storage.sql.exec<{ payload: string }>(
      "SELECT payload FROM workbench_catalog WHERE singleton = 1",
    ).toArray()[0];
    if (!row) return { revision: 0, storeRevision: 0, workspaces: [], sessions: [] };
    return catalogSchema.parse(JSON.parse(row.payload));
  }

  replace(raw: WorkbenchCatalog): WorkbenchCatalog {
    const next = catalogSchema.parse(raw);
    const current = this.read();
    if (next.revision < current.revision) throw new Error("stale_catalog");
    if (next.revision === current.revision) {
      if (JSON.stringify(next) !== JSON.stringify(current)) throw new Error("catalog_revision_conflict");
      return current;
    }

    this.storage.sql.exec(
      `INSERT INTO workbench_catalog (singleton, revision, payload) VALUES (1, ?, ?)
       ON CONFLICT(singleton) DO UPDATE SET revision = excluded.revision, payload = excluded.payload`,
      next.revision,
      JSON.stringify(next),
    );
    return next;
  }

  page(requestedRevision: number | null, cursor: string | null, hostOnline: boolean) {
    const catalog = this.read();
    const records = [
      ...catalog.workspaces.map(workspace => ({ kind: "workspace" as const, workspace })),
      ...catalog.sessions.map(session => ({ kind: "session" as const, session })),
    ];
    const offset = this.decodeCursor(requestedRevision, cursor, catalog.revision);
    const items = records.slice(offset, offset + CATALOG_PAGE_SIZE);
    const nextOffset = offset + items.length;
    const nextCursor = nextOffset < records.length ? `${catalog.revision}:${nextOffset}` : null;
    return { type: "catalog_page" as const, revision: catalog.revision, items, nextCursor, hostOnline };
  }

  private decodeCursor(requestedRevision: number | null, cursor: string | null, currentRevision: number): number {
    if (requestedRevision === null || requestedRevision !== currentRevision || cursor === null) return 0;
    const match = /^(\d+):(\d+)$/.exec(cursor);
    if (!match || Number(match[1]) !== currentRevision) return 0;
    const offset = Number(match[2]);
    return Number.isSafeInteger(offset) && offset >= 0 ? offset : 0;
  }
}
