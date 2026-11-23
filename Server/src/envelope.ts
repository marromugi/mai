/**
 * The one shape of a sealed writing the server stores. Laid out in `Server/README.md`; the app
 * writes it in `Packages/Sync/Sources/Sync/Sealed.swift`.
 */

export const magic = [0x6d, 0x61, 0x69, 0x01] as const;
const headerLength = 28;
const sealedKeyLength = 12 + 32 + 16;
const sealedContentsOverhead = 12 + 16;
export const smallestEnvelope = headerLength + sealedKeyLength + sealedContentsOverhead;
/** Leaves room in a Durable Object's 2 MB row for the other columns. */
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

export type Envelope = {
  readonly id: WritingId;
  /** Milliseconds since 1970, as the device that sealed it wrote it. */
  readonly updated: number;
  readonly bytes: ArrayBuffer;
};

export type Parsed<T> = { ok: true; value: T } | { ok: false; reason: string };

export function parseEnvelope(bytes: ArrayBuffer): Parsed<Envelope> {
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
  return { ok: true, value: { id, updated: Number(updated), bytes } };
}

function idFromBytes(bytes: Uint8Array): WritingId {
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  const text = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  const id = parseWritingId(text);
  if (id === undefined) {
    throw new Error(`16 bytes always format as a writing ID, but gave ${text}`);
  }
  return id;
}

/** A count the client last saw, given in the `Mai-Base-Version` header. */
export function parseVersion(text: string | null): number | undefined {
  if (text === null || !/^(0|[1-9][0-9]{0,15})$/.test(text)) {
    return undefined;
  }
  const version = Number(text);
  return Number.isSafeInteger(version) ? version : undefined;
}
