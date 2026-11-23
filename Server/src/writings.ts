import { DurableObject } from "cloudflare:workers";
import type { Envelope, WritingId } from "./envelope";

export type Listed = { id: WritingId; version: number; updated: number; size: number };

export type Saved = { saved: true; version: number } | { saved: false; version: number };

export type Read = { version: number; bytes: ArrayBuffer } | undefined;

/**
 * Every sealed writing of the one user, each with the version the server gave its last save.
 * The operations are the model's in `Specs/ReadMode`: `save` is a device's `Save`, and `list`
 * with `read` is what a device reads in `Sync`.
 */
export class Writings extends DurableObject<Env> {
  constructor(state: DurableObjectState, env: Env) {
    super(state, env);
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS writings (
        id TEXT PRIMARY KEY,
        version INTEGER NOT NULL,
        updated INTEGER NOT NULL,
        envelope BLOB NOT NULL
      )`);
  }

  /** Saves `envelope` only when `base` is the writing's current version, 0 for none yet. */
  save(envelope: Envelope, base: number): Saved {
    const current = this.version(envelope.id);
    if (current !== base) {
      return { saved: false, version: current };
    }
    const version = current + 1;
    this.ctx.storage.sql.exec(
      `INSERT INTO writings (id, version, updated, envelope) VALUES (?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET
         version = excluded.version, updated = excluded.updated, envelope = excluded.envelope`,
      envelope.id,
      version,
      envelope.updated,
      envelope.bytes,
    );
    return { saved: true, version };
  }

  list(): Listed[] {
    return this.ctx.storage.sql
      .exec<{ id: WritingId; version: number; updated: number; size: number }>(
        "SELECT id, version, updated, length(envelope) AS size FROM writings ORDER BY id",
      )
      .toArray();
  }

  read(id: WritingId): Read {
    const row = this.ctx.storage.sql
      .exec<{ version: number; envelope: ArrayBuffer }>(
        "SELECT version, envelope FROM writings WHERE id = ?",
        id,
      )
      .toArray()[0];
    return row === undefined ? undefined : { version: row.version, bytes: row.envelope };
  }

  private version(id: WritingId): number {
    const row = this.ctx.storage.sql
      .exec<{ version: number }>("SELECT version FROM writings WHERE id = ?", id)
      .toArray()[0];
    return row?.version ?? 0;
  }
}
