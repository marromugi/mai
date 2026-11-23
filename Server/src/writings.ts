import { DurableObject } from "cloudflare:workers";
import type { Envelope, Revision, WritingId } from "./envelope";

export type Listed = { id: WritingId; revision: Revision; updated: number; size: number };

export type Saved = { saved: boolean; revision: Revision | null };

export type Read = { revision: Revision; bytes: ArrayBuffer } | undefined;

/**
 * Every sealed writing of the one user. `save` is the read mode model's `Save` for the writing
 * itself (`Specs/ReadMode`); the model has no refused save, so #26 sends copies only for a save
 * that landed. `list` and `read` take the writings, which the model leaves out; its `Sync` takes
 * the settings #26 adds.
 */
export class Writings extends DurableObject<Env> {
  constructor(state: DurableObjectState, env: Env) {
    super(state, env);
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS writings (
        id TEXT PRIMARY KEY,
        revision TEXT NOT NULL,
        updated INTEGER NOT NULL,
        envelope BLOB NOT NULL
      )`);
  }

  /** Saves `envelope` only when `base` is the writing's current revision, null for none yet. */
  save(envelope: Envelope, base: Revision | null): Saved {
    const current = this.revision(envelope.id);
    if (current !== base) {
      return { saved: false, revision: current };
    }
    this.ctx.storage.sql.exec(
      `INSERT INTO writings (id, revision, updated, envelope) VALUES (?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET
         revision = excluded.revision, updated = excluded.updated, envelope = excluded.envelope`,
      envelope.id,
      envelope.revision,
      envelope.updated,
      envelope.bytes,
    );
    return { saved: true, revision: envelope.revision };
  }

  list(): Listed[] {
    return this.ctx.storage.sql
      .exec<Listed>("SELECT id, revision, updated, length(envelope) AS size FROM writings")
      .toArray();
  }

  read(id: WritingId): Read {
    const row = this.ctx.storage.sql
      .exec<{ revision: Revision; envelope: ArrayBuffer }>(
        "SELECT revision, envelope FROM writings WHERE id = ?",
        id,
      )
      .toArray()[0];
    return row === undefined ? undefined : { revision: row.revision, bytes: row.envelope };
  }

  private revision(id: WritingId): Revision | null {
    const row = this.ctx.storage.sql
      .exec<{ revision: Revision }>("SELECT revision FROM writings WHERE id = ?", id)
      .toArray()[0];
    return row?.revision ?? null;
  }
}
