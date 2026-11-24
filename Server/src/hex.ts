/**
 * Lowercase hex: how revisions, the Sign in with Apple nonce, the own key check, and the keys and
 * wrapped keys of read mode are written.
 */
export function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** The bytes `text` writes in lowercase hex; undefined for any other text. */
export function parseHex(text: string): Uint8Array | undefined {
  if (!/^(?:[0-9a-f]{2})*$/.test(text)) {
    return undefined;
  }
  return Uint8Array.from(text.match(/../g) ?? [], (pair) => parseInt(pair, 16));
}
