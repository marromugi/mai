/**
 * Apple's refresh token for an account, as `accounts.apple_refresh_token` keeps it: a 12-byte
 * nonce, then the token sealed with AES-256-GCM under the Worker's `REFRESH_TOKEN_KEY`, the
 * account ID as additional data, so a sealed token opens only on its own account's row.
 */
export class RefreshTokens {
  /** `key` is `REFRESH_TOKEN_KEY`: 32 random bytes in base64. */
  constructor(private readonly key: string) {}

  async seal(token: string, account: string): Promise<Uint8Array> {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const sealed = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData: encoded(account) },
      await this.#aesKey(),
      encoded(token),
    );
    const kept = new Uint8Array(12 + sealed.byteLength);
    kept.set(iv);
    kept.set(new Uint8Array(sealed), 12);
    return kept;
  }

  /** The token sealed for `account`; throws when `kept` isn't one this key sealed for it. */
  async open(kept: Uint8Array, account: string): Promise<string> {
    const opened = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: kept.subarray(0, 12), additionalData: encoded(account) },
      await this.#aesKey(),
      kept.subarray(12),
    );
    return new TextDecoder().decode(opened);
  }

  async #aesKey(): Promise<CryptoKey> {
    const bytes = Uint8Array.from(atob(this.key), (character) => character.charCodeAt(0));
    if (bytes.length !== 32) {
      throw new Error("REFRESH_TOKEN_KEY is 32 random bytes in base64");
    }
    return crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
  }
}

function encoded(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}
