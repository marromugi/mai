/** The three parts of a compact JWS (RFC 7515), read but not yet checked. */

export type Checked<T, F extends string> = { ok: true; value: T } | { ok: false; failure: F };

export type Json = { readonly [key: string]: unknown };

export type CompactJws = {
  readonly header: Json;
  readonly payload: Json;
  /** The bytes the signature covers: `<header>.<payload>` as sent. */
  readonly signingInput: Uint8Array;
  readonly signature: Uint8Array;
};

export function readCompactJws(compact: string): CompactJws | undefined {
  const parts = compact.split(".");
  const [header, payload, signature] = parts;
  if (
    parts.length !== 3 ||
    header === undefined ||
    payload === undefined ||
    signature === undefined
  ) {
    return undefined;
  }
  const headerJson = jsonOf(base64urlBytes(header));
  const payloadJson = jsonOf(base64urlBytes(payload));
  const signatureBytes = base64urlBytes(signature);
  if (headerJson === undefined || payloadJson === undefined || signatureBytes === undefined) {
    return undefined;
  }
  return {
    header: headerJson,
    payload: payloadJson,
    signingInput: new TextEncoder().encode(`${header}.${payload}`),
    signature: signatureBytes,
  };
}

export function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

export function base64urlBytes(encoded: string): Uint8Array | undefined {
  if (!/^[A-Za-z0-9_-]*$/.test(encoded) || encoded.length % 4 === 1) {
    return undefined;
  }
  return binary(atob(encoded.replaceAll("-", "+").replaceAll("_", "/")));
}

/** Standard base64 with padding, as `x5c` holds certificates. */
export function base64Bytes(encoded: string): Uint8Array | undefined {
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
    return undefined;
  }
  return binary(atob(encoded));
}

function binary(characters: string): Uint8Array {
  return Uint8Array.from(characters, (character) => character.charCodeAt(0));
}

function jsonOf(bytes: Uint8Array | undefined): Json | undefined {
  if (bytes === undefined) {
    return undefined;
  }
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch (error) {
    if (error instanceof SyntaxError || error instanceof TypeError) {
      return undefined;
    }
    throw error;
  }
  return isJson(value) ? value : undefined;
}

export function isJson(value: unknown): value is Json {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function text(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

/** A whole number, as JSON carries times in milliseconds or seconds. */
export function whole(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) ? value : undefined;
}
