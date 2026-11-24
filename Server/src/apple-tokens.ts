import { appleIssuer } from "./apple-sign-in";
import { isJson, readCompactJws, text, type Checked, type Json } from "./jws";
import { base64url } from "./secrets";

/**
 * Sign in with Apple's token and revoke endpoints, as
 * https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens
 * says: an authorization code the app got is exchanged for the user's refresh token, which is
 * revoked when the account is deleted.
 */

export const appleTokenUrl = "https://appleid.apple.com/auth/token";
export const appleRevokeUrl = "https://appleid.apple.com/auth/revoke";

/** A `client_secret` is made fresh for each call and lasts this long. */
export const clientSecretLifetime = 5 * 60 * 1000;

export type Client = {
  /** The app's bundle ID. */
  readonly clientId: string;
  readonly teamId: string;
  /** The ID of the Sign in with Apple key, `APPLE_SIGN_IN_KEY_ID`. */
  readonly keyId: string;
  /** The Sign in with Apple key (.p8) as Apple Developer gives it, `APPLE_SIGN_IN_KEY`. */
  readonly key: string;
};

/** Apple refused the code (used, expired, or not this app's), or didn't answer. */
export type ExchangeFailure = "refused" | "unavailable";

/** What Apple gave for a code: the refresh token, and the user it was issued for. */
export type Exchanged = { readonly refreshToken: string; readonly sub: string };

export class AppleTokens {
  /** `post` is `fetch` outside the tests; the URL is `appleTokenUrl` or `appleRevokeUrl`. */
  constructor(
    private readonly post: (url: string, init: RequestInit) => Promise<Response>,
    private readonly client: Client,
  ) {}

  async exchange(code: string, now: number): Promise<Checked<Exchanged, ExchangeFailure>> {
    const sent = await this.#post(
      appleTokenUrl,
      { code, grant_type: "authorization_code" },
      ["invalid_grant"],
      now,
    );
    if (sent === "unavailable") {
      return { ok: false, failure: "unavailable" };
    }
    const { response, answer } = sent;
    if (response.status >= 400 && response.status < 500) {
      return { ok: false, failure: "refused" };
    }
    const refreshToken = text(answer["refresh_token"]);
    const idToken = readCompactJws(text(answer["id_token"]) ?? "");
    // Apple answered over TLS, so its ID token is read as Apple's word without checking it again.
    const sub = idToken?.payload["iss"] === appleIssuer ? text(idToken.payload["sub"]) : undefined;
    if (!response.ok || refreshToken === undefined || sub === undefined) {
      return { ok: false, failure: "unavailable" };
    }
    return { ok: true, value: { refreshToken, sub } };
  }

  /**
   * Revokes the user's refresh token, and with it what the user granted the app, as
   * https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens says. Apple
   * answers 200 for a token revoked before too, so this can be called again.
   */
  async revoke(refreshToken: string, now: number): Promise<Checked<undefined, "unavailable">> {
    const sent = await this.#post(
      appleRevokeUrl,
      { token: refreshToken, token_type_hint: "refresh_token" },
      [],
      now,
    );
    return sent === "unavailable" || !sent.response.ok
      ? { ok: false, failure: "unavailable" }
      : { ok: true, value: undefined };
  }

  /**
   * Posts `fields` to `url` as this app, with a fresh `client_secret`. Answers "unavailable" when
   * the network fails. Throws on a 4xx whose error isn't one of `expected`: those are about the
   * Worker's own request or its APPLE_ secrets.
   */
  async #post(
    url: string,
    fields: Record<string, string>,
    expected: readonly string[],
    now: number,
  ): Promise<{ response: Response; answer: Json } | "unavailable"> {
    const form = new URLSearchParams({
      client_id: this.client.clientId,
      client_secret: await this.#clientSecret(now),
      ...fields,
    });
    let response: Response;
    try {
      response = await this.post(url, { method: "POST", body: form });
    } catch (error) {
      // fetch rejects with a TypeError when the network fails.
      if (error instanceof TypeError) {
        return "unavailable";
      }
      throw error;
    }
    let body: unknown;
    try {
      body = await response.json();
    } catch (error) {
      if (!(error instanceof SyntaxError)) {
        throw error;
      }
    }
    const answer = isJson(body) ? body : {};
    const error = answer["error"];
    const clientError = response.status >= 400 && response.status < 500;
    if (clientError && !(typeof error === "string" && expected.includes(error))) {
      const endpoint = new URL(url).pathname.split("/").at(-1);
      throw new Error(
        `Apple's ${endpoint} endpoint answered ${response.status} to the Worker: ${String(error)}`,
      );
    }
    return { response, answer };
  }

  async #clientSecret(now: number): Promise<string> {
    const issued = Math.floor(now / 1000);
    const input = [
      { alg: "ES256", kid: this.client.keyId },
      {
        iss: this.client.teamId,
        iat: issued,
        exp: issued + clientSecretLifetime / 1000,
        aud: appleIssuer,
        sub: this.client.clientId,
      },
    ]
      .map((part) => base64url(new TextEncoder().encode(JSON.stringify(part))))
      .join(".");
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      await this.#signingKey(),
      new TextEncoder().encode(input),
    );
    return `${input}.${base64url(new Uint8Array(signature))}`;
  }

  async #signingKey(): Promise<CryptoKey> {
    const base64 = this.client.key.replace(/-----[A-Z ]+-----/g, "");
    const der = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
    return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, [
      "sign",
    ]);
  }
}
