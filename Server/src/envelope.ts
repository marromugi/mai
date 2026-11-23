/**
 * The one shape of a sealed writing the server stores. Laid out in `Server/README.md`; the app
 * writes it in `Packages/Sync/Sources/Sync/Sealed.swift`.
 */

export const magic = [0x6d, 0x61, 0x69, 0x01] as const;
const headerLength = 28;
const sealedKeyLength = 12 + 32 + 16;
const sealedContentsOverhead = 12 + 16;
export const smallestEnvelope = headerLength + sealedKeyLength + sealedContentsOverhead;
/** See the Decisions of PR #37 for why not more; Turso takes it in one batch (PR #46). */
export const largestEnvelope = 1_900_000;

/** A writing ID in the lowercase text form, which is how the server names writings. */
export type WritingId = string & { readonly brand: unique symbol };

export function parseWritingId(text: string): WritingId | undefined {
  const lowered = text.toLowerCase();
  return isWritingId(lowered) ? lowered : undefined;
}

function isWritingId(text: string): text is WritingId {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(text);
}

/** SHA-256 of a sealed writing, in lowercase hex: what tells one save from another. */
export type Revision = string & { readonly brand: unique symbol };

export type Envelope = {
  readonly id: WritingId;
  readonly revision: Revision;
  /** Milliseconds since 1970, as the device that sealed it wrote it. */
  readonly updated: number;
  readonly bytes: ArrayBuffer;
};

export type Parsed<T> = { ok: true; value: T } | { ok: false; reason: string };

export async function parseEnvelope(bytes: ArrayBuffer): Promise<Parsed<Envelope>> {
  if (bytes.byteLength < smallestEnvelope) {
    return { ok: false, reason: `a sealed writing is at least ${smallestEnvelope} bytes` };
  }
  if (bytes.byteLength > largestEnvelope) {
    return { ok: false, reason: `a sealed writing is at most ${largestEnvelope} bytes` };
  }
  const view = new DataView(bytes);
  if (!magic.every((byte, index) => view.getUint8(index) === byte)) {
    return { ok: false, reason: "a sealed writing starts with the bytes 6d 61 69 01" };
  }
  const id = idFromBytes(new Uint8Array(bytes, 4, 16));
  const updated = view.getBigUint64(20);
  if (updated === 0n || updated > BigInt(Number.MAX_SAFE_INTEGER)) {
    return { ok: false, reason: "the updated time is not a time the server can hold" };
  }
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  const revision = parseRevision(hex(digest));
  if (revision === undefined) {
    throw new Error("a SHA-256 digest always formats as a revision");
  }
  return { ok: true, value: { id, revision, updated: Number(updated), bytes } };
}

function idFromBytes(bytes: Uint8Array): WritingId {
  const digits = hex(bytes);
  const text = `${digits.slice(0, 8)}-${digits.slice(8, 12)}-${digits.slice(12, 16)}-${digits.slice(16, 20)}-${digits.slice(20)}`;
  const id = parseWritingId(text);
  if (id === undefined) {
    throw new Error(`16 bytes always format as a writing ID, but gave ${text}`);
  }
  return id;
}

/** Lowercase hex, as revisions are written. */
export function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function parseRevision(text: string): Revision | undefined {
  return isRevision(text) ? text : undefined;
}

function isRevision(text: string): text is Revision {
  return /^[0-9a-f]{64}$/.test(text);
}

/**
 * The revision a save is made over, given in the `Mai-Base-Revision` header: the one last read,
 * or `none` for a writing the server has never kept.
 */
export function parseBase(text: string | null): Parsed<Revision | null> {
  if (text === "none") {
    return { ok: true, value: null };
  }
  const revision = parseRevision(text ?? "");
  return revision === undefined
    ? {
        ok: false,
        reason: "Mai-Base-Revision is the revision last read, or none for a new writing",
      }
    : { ok: true, value: revision };
}
