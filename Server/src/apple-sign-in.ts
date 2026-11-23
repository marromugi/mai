import { isJson, readCompactJws, text, whole, type Checked } from "./jws";

/**
 * Checks a Sign in with Apple ID token as
 * https://developer.apple.com/documentation/signinwithapple/verifying-a-user says: the signature
 * against Apple's published keys, `iss`, `aud`, `exp`, and `nonce`.
 */

export const appleIssuer = "https://appleid.apple.com";
export const appleKeysUrl = "https://appleid.apple.com/auth/keys";

/** Apple's keys are kept this long before they are fetched again. */
export const keysLifetime = 24 * 60 * 60 * 1000;

/**
 * A token naming a key the kept copy lacks has the keys fetched again, but not sooner than this
 * after the last fetch, so tokens with made-up key IDs can't have every request fetch from Apple.
 */
export const refetchGap = 5 * 60 * 1000;

export type SignInFailure =
  | "malformed"
  | "algorithm"
  | "unknown-key"
  | "keys-unavailable"
  | "signature"
  | "issuer"
  | "audience"
  | "expired"
  | "nonce";

/** Who signed in: Apple's stable ID for the user within the developer's team. */
export type AppleUser = { readonly sub: string };

export type ExpectedToken = {
  /** The app's bundle ID, which Apple puts in `aud`. */
  readonly bundleId: string;
  /** The `nonce` the token must carry, exactly as the app gave it to Apple. */
  readonly nonce: string;
};

export async function verifyIdentityToken(
  token: string,
  expected: ExpectedToken,
  keys: AppleSignInKeys,
  now: number,
): Promise<Checked<AppleUser, SignInFailure>> {
  const jws = readCompactJws(token);
  if (jws === undefined) {
    return { ok: false, failure: "malformed" };
  }
  // Apple's documentation says ES256; the keys it publishes are RS256 (checked for #44).
  if (jws.header["alg"] !== "RS256") {
    return { ok: false, failure: "algorithm" };
  }
  const kid = text(jws.header["kid"]);
  if (kid === undefined) {
    return { ok: false, failure: "malformed" };
  }
  const key = await keys.key(kid, now);
  if (!key.ok) {
    return key;
  }
  const signed = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key.value,
    jws.signature,
    jws.signingInput,
  );
  if (!signed) {
    return { ok: false, failure: "signature" };
  }

  const claims = jws.payload;
  const sub = text(claims["sub"]);
  const exp = whole(claims["exp"]);
  if (sub === undefined || exp === undefined) {
    return { ok: false, failure: "malformed" };
  }
  if (claims["iss"] !== appleIssuer) {
    return { ok: false, failure: "issuer" };
  }
  if (claims["aud"] !== expected.bundleId) {
    return { ok: false, failure: "audience" };
  }
  if (exp * 1000 <= now) {
    return { ok: false, failure: "expired" };
  }
  if (claims["nonce"] !== expected.nonce) {
    return { ok: false, failure: "nonce" };
  }
  return { ok: true, value: { sub } };
}

type KeySet = {
  readonly keys: ReadonlyMap<string, JsonWebKey>;
  /** The JWKS as Apple sent it. */
  readonly body: string;
  /** When Apple sent it. */
  readonly fetched: number;
  /** When Apple was last asked, whether or not it answered. */
  readonly tried: number;
};

/**
 * Apple's JWKS, kept in a Cache for `keysLifetime`. `fetchKeys` is `fetch` outside the tests; the
 * URL is always `appleKeysUrl`.
 */
export class AppleSignInKeys {
  constructor(
    private readonly fetchKeys: (url: string) => Promise<Response>,
    private readonly cache: Cache,
  ) {}

  async key(kid: string, now: number): Promise<Checked<CryptoKey, SignInFailure>> {
    let set = (await this.kept(now)) ?? (await this.fetched(now));
    if (set !== undefined && !set.keys.has(kid) && now - set.tried >= refetchGap) {
      // A failed fetch is kept as tried too, so it holds off the next one as a good one would.
      set = (await this.fetched(now)) ?? (await this.keep({ ...set, tried: now }));
    }
    if (set === undefined) {
      return { ok: false, failure: "keys-unavailable" };
    }
    const jwk = set.keys.get(kid);
    if (jwk === undefined) {
      return { ok: false, failure: "unknown-key" };
    }
    try {
      const key = await crypto.subtle.importKey(
        "jwk",
        jwk,
        { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
        false,
        ["verify"],
      );
      return { ok: true, value: key };
    } catch (error) {
      if (error instanceof DOMException && error.name === "DataError") {
        return { ok: false, failure: "keys-unavailable" };
      }
      throw error;
    }
  }

  private async kept(now: number): Promise<KeySet | undefined> {
    const response = await this.cache.match(appleKeysUrl);
    const fetched = Number(response?.headers.get("Mai-Fetched"));
    const tried = Number(response?.headers.get("Mai-Tried") ?? fetched);
    if (
      response === undefined ||
      !Number.isSafeInteger(fetched) ||
      !Number.isSafeInteger(tried) ||
      now - fetched >= keysLifetime
    ) {
      return undefined;
    }
    return keySet(await response.text(), fetched, tried);
  }

  /** Apple's keys fetched now and kept, or undefined when Apple didn't answer with them. */
  private async fetched(now: number): Promise<KeySet | undefined> {
    let body: string;
    try {
      const response = await this.fetchKeys(appleKeysUrl);
      if (!response.ok) {
        return undefined;
      }
      body = await response.text();
    } catch (error) {
      if (error instanceof TypeError) {
        return undefined;
      }
      throw error;
    }
    const set = keySet(body, now, now);
    return set === undefined ? undefined : this.keep(set);
  }

  private async keep(set: KeySet): Promise<KeySet> {
    await this.cache.put(
      appleKeysUrl,
      new Response(set.body, {
        headers: {
          "Content-Type": "application/json",
          "Cache-Control": `max-age=${keysLifetime / 1000}`,
          "Mai-Fetched": String(set.fetched),
          "Mai-Tried": String(set.tried),
        },
      }),
    );
    return set;
  }
}

/** The RS256 RSA keys of a JWKS by key ID; keys of any other kind are left out. */
function keySet(body: string, fetched: number, tried: number): KeySet | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch (error) {
    if (error instanceof SyntaxError) {
      return undefined;
    }
    throw error;
  }
  const list = isJson(parsed) ? parsed["keys"] : undefined;
  if (!Array.isArray(list)) {
    return undefined;
  }
  const keys = new Map<string, JsonWebKey>();
  for (const entry of list) {
    if (!isJson(entry) || entry["kty"] !== "RSA" || entry["alg"] !== "RS256") {
      continue;
    }
    const kid = text(entry["kid"]);
    const n = text(entry["n"]);
    const e = text(entry["e"]);
    if (kid !== undefined && n !== undefined && e !== undefined) {
      keys.set(kid, { kty: "RSA", alg: "RS256", n, e });
    }
  }
  return { keys, body, fetched, tried };
}
