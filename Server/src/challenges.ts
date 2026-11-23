import { base64urlBytes } from "./jws";
import { base64url } from "./sessions";

/**
 * A challenge is `<expires>.<random>.<mac>`: when it expires in milliseconds since 1970, 16 random
 * bytes, and an HMAC-SHA-256 of the two under the Worker's `CHALLENGE_KEY`, both in base64url. The
 * server keeps nothing when it gives one out, and keeps a used one in `used_challenges` until
 * `Store.sweep` removes it, `usedChallengeMargin` past its expiry. The app gives Apple the
 * challenge's SHA-256 in lowercase hex as the Sign in with Apple nonce, so that is the `nonce` the
 * ID token carries.
 */

export const challengeLifetime = 5 * 60 * 1000;

/** A challenge this server gave out that hasn't expired, not yet checked for being used. */
export type Challenge = {
  readonly value: string;
  readonly expires: number;
  /** The `nonce` an ID token made for this challenge carries. */
  readonly nonce: string;
};

const pattern = /^([1-9][0-9]{0,15})\.([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{43})$/;

export class Challenges {
  /** `key` is `CHALLENGE_KEY`: 32 or more random bytes in base64. */
  constructor(private readonly key: string) {}

  async issue(now: number): Promise<string> {
    const signed = `${now + challengeLifetime}.${base64url(crypto.getRandomValues(new Uint8Array(16)))}`;
    const mac = await crypto.subtle.sign("HMAC", await this.#hmacKey(), encoded(signed));
    return `${signed}.${base64url(new Uint8Array(mac))}`;
  }

  /** The challenge, when this server gave it out and it hasn't expired by `now`. */
  async check(value: string, now: number): Promise<Challenge | undefined> {
    const match = pattern.exec(value);
    const expires = Number(match?.[1]);
    const mac = base64urlBytes(match?.[3] ?? "");
    if (
      match === null ||
      mac === undefined ||
      // 43 base64url characters carry 2 bits more than the 32 bytes; only the one spelling counts.
      base64url(mac) !== match[3] ||
      !Number.isSafeInteger(expires) ||
      expires <= now
    ) {
      return undefined;
    }
    const signed = value.slice(0, value.lastIndexOf("."));
    if (!(await crypto.subtle.verify("HMAC", await this.#hmacKey(), mac, encoded(signed)))) {
      return undefined;
    }
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", encoded(value)));
    return {
      value,
      expires,
      nonce: Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join(""),
    };
  }

  async #hmacKey(): Promise<CryptoKey> {
    const bytes = Uint8Array.from(atob(this.key), (character) => character.charCodeAt(0));
    if (bytes.length < 32) {
      throw new Error("CHALLENGE_KEY is 32 or more random bytes in base64");
    }
    return crypto.subtle.importKey("raw", bytes, { name: "HMAC", hash: "SHA-256" }, false, [
      "sign",
      "verify",
    ]);
  }
}

function encoded(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}
