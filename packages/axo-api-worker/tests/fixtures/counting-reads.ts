/**
 * The Worker as it is, but every SessionDO counts the reads it serves in a `test_reads` table, so
 * a test can tell which deliveries read the SessionDO and which came from the HostDO (RFD0032).
 */
import { AxoSessionDO as ReleaseSessionDO } from "../../src/session-store";

export * from "../../src/index";
export { default } from "../../src/index";

export class AxoSessionDO extends ReleaseSessionDO {
  override async read(...args: Parameters<ReleaseSessionDO["read"]>): ReturnType<ReleaseSessionDO["read"]> {
    this.ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS test_reads (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), reads INTEGER NOT NULL)");
    this.ctx.storage.sql.exec("INSERT INTO test_reads (singleton, reads) VALUES (1, 1) ON CONFLICT(singleton) DO UPDATE SET reads = reads + 1");
    return super.read(...args);
  }
}
