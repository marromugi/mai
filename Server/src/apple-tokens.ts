import { appleIssuer } from "./apple-sign-in";
import { isJson, readCompactJws, text, type Checked } from "./jws";
import { base64url } from "./sessions";

/**
 * Sign in with Apple's token endpoint, as
 * https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens
 * says: an authorization code the app got is exchanged for the user's refresh token.
 */

export const appleTokenUrl = "https://appleid.apple.com/auth/token";

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
  /** `post` is `fetch` outside the tests; the URL is always `appleTokenUrl`. */
  constructor(
    private readonly post: (url: string, init: RequestInit) => Promise<Response>,
    private readonly client: Client,
  ) {}

  async exchange(code: string, now: number): Promise<Checked<Exchanged, ExchangeFailure>> {
    const form = new URLSearchParams({
      client_id: this.client.clientId,
      client_secret: await this.#clientSecret(now),
      code,
      grant_type: "authorization_code",
    });
    let response: Response;
    let body: unknown;
    try {
      response = await this.post(appleTokenUrl, { method: "POST", body: form });
      body = await response.json();
    } catch (error) {
      if (error instanceof TypeError || error instanceof SyntaxError) {
        return { ok: false, failure: "unavailable" };
      }
      throw error;
    }
    const answer = isJson(body) ? body : {};
    if (response.status === 400 && answer["error"] === "invalid_client") {
      throw new Error("Apple refused the Worker's client_secret; check the APPLE_ secrets");
    }
    if (response.status === 400) {
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
    const base64 = this.client.key.replace(/-----[A-Z ]+-----/g, "").replace(/\s/g, "");
    const der = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
    return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, [
      "sign",
    ]);
  }
}
