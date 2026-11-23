/** Lowercase hex: how revisions, the Sign in with Apple nonce and the own key check are written. */
export function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
