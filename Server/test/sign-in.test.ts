import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { createClient } from "@libsql/client/web";
import { beforeAll, describe, expect, it } from "vitest";
import { appleIssuer, appleKeysUrl } from "../src/apple-sign-in";
import { appleTokenUrl } from "../src/apple-tokens";
import { Challenges, challengeLifetime } from "../src/challenges";
import { serve, signInOf } from "../src/index";
import { newSessionToken } from "../src/sessions";
import { readCompactJws } from "../src/jws";
import { RefreshTokens } from "../src/refresh-tokens";
import type { SignIn } from "../src/sign-in";
import { store } from "./accounts";
import { base64url, jwks, makeSignInKey, signIdentityToken, type SignInKey } from "./apple-fakes";

const database = createClient({ url: env.TURSO_URL });

/** The ID tokens' signer, standing in for Apple's JWKS. */
let signer: SignInKey;
/** The Worker's Sign in with Apple key; the fake token endpoint checks `client_secret` with it. */
let clientKey: CryptoKeyPair;
let clientKeyPem: string;

beforeAll(async () => {
  signer = await makeSignInKey("test-key");
  const made = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ]);
  if (!("privateKey" in made)) {
    throw new Error("ECDSA makes a key pair");
  }
  clientKey = made;
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", clientKey.privateKey);
  if (!(pkcs8 instanceof ArrayBuffer)) {
    throw new Error("a key exported as PKCS #8 is bytes");
  }
  const body = btoa(String.fromCharCode(...new Uint8Array(pkcs8)));
  // Laid out as Apple Developer's .p8 file is.
  clientKeyPem = [
    "-----BEGIN PRIVATE KEY-----",
    ...(body.match(/.{1,64}/g) ?? []),
    "-----END PRIVATE KEY-----",
  ].join("\n");
});

type Grant = { sub: string; refreshToken: string };

/**
 * Apple's JWKS and token endpoints, answering from the test. `codes` are the authorization codes
 * Apple would take, each once; `answer`, when given, is what the token endpoint answers instead;
 * `key` is the Worker's `APPLE_SIGN_IN_KEY`, the .p8 as Apple gives it when left out.
 */
function fakeApple(
  options: {
    answer?: () => Response;
    key?: string;
    /** Milliseconds each endpoint waits before it answers. */
    delay?: number;
    keysAnswer?: () => Response;
  } = {},
) {
  const codes = new Map<string, Grant>();
  const asked: { url: string; form?: URLSearchParams }[] = [];
  const send = async (url: string, init?: RequestInit): Promise<Response> => {
    if (options.delay !== undefined) {
      await new Promise((resolve) => setTimeout(resolve, options.delay));
    }
    if (url === appleKeysUrl) {
      asked.push({ url });
      return options.keysAnswer?.() ?? new Response(await jwks([signer]));
    }
    if (url !== appleTokenUrl || !(init?.body instanceof URLSearchParams)) {
      throw new Error(`the Worker reached ${url}, which the fake Apple doesn't serve`);
    }
    const form = init.body;
    asked.push({ url, form });
    if (options.answer !== undefined) {
      return options.answer();
    }
    if (!(await clientSecretHolds(form.get("client_secret") ?? ""))) {
      return Response.json({ error: "invalid_client" }, { status: 400 });
    }
    const grant = codes.get(form.get("code") ?? "");
    if (form.get("grant_type") !== "authorization_code" || grant === undefined) {
      return Response.json({ error: "invalid_grant" }, { status: 400 });
    }
    codes.delete(form.get("code") ?? "");
    return Response.json({
      access_token: "access",
      token_type: "Bearer",
      expires_in: 3600,
      refresh_token: grant.refreshToken,
      id_token: await signIdentityToken(
        { iss: appleIssuer, aud: env.APPLE_CLIENT_ID, sub: grant.sub },
        signer,
      ),
    });
  };
  const signIn: Promise<SignIn> = caches
    .open(crypto.randomUUID())
    .then((cache) =>
      signInOf({ ...env, APPLE_SIGN_IN_KEY: options.key ?? clientKeyPem }, send, cache),
    );
  return { codes, asked, signIn };
}

async function clientSecretHolds(secret: string): Promise<boolean> {
  const jws = readCompactJws(secret);
  if (jws === undefined) {
    return false;
  }
  const signed = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    clientKey.publicKey,
    jws.signature,
    jws.signingInput,
  );
  const { iss, aud, sub, iat, exp } = jws.payload;
  return (
    signed &&
    jws.header["alg"] === "ES256" &&
    jws.header["kid"] === env.APPLE_SIGN_IN_KEY_ID &&
    iss === env.APPLE_TEAM_ID &&
    aud === appleIssuer &&
    sub === env.APPLE_CLIENT_ID &&
    typeof iat === "number" &&
    typeof exp === "number" &&
    Math.abs(iat - Date.now() / 1000) < 60 &&
    exp - iat === 300
  );
}

async function call(signIn: SignIn | Promise<SignIn>, path: string, body?: unknown) {
  const request = new Request(`https://mai.test${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? null : JSON.stringify(body),
  });
  return serve(request, await signIn);
}

/** A request to the Worker as deployed, with its own secrets and Apple unreached. */
function deployed(path: string, init: RequestInit = {}): Promise<Response> {
  return exports.default.fetch(new Request(`https://mai.test${path}`, init));
}

async function challenge(signIn: SignIn | Promise<SignIn>): Promise<string> {
  const answer = await call(signIn, "/challenges");
  expect(answer.status).toBe(201);
  const { challenge: value } = await answer.json<{ challenge: string }>();
  return value;
}

/** Apple's ID token for `sub`, made for the challenge `madeFor` as the app asks for it. */
async function identityToken(sub: string, madeFor: string, now = Date.now()): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(madeFor));
  const nonce = Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  return signIdentityToken(
    {
      iss: appleIssuer,
      aud: env.APPLE_CLIENT_ID,
      exp: Math.floor(now / 1000) + 600,
      iat: Math.floor(now / 1000),
      sub,
      nonce,
      nonce_supported: true,
    },
    signer,
  );
}

function newSub(): string {
  return `001234.${crypto.randomUUID().replaceAll("-", "")}.0123`;
}

/** Makes an account through `POST /account`, as the app does after the purchase. */
async function makeAccount(
  apple: ReturnType<typeof fakeApple>,
  sub = newSub(),
  account: string = crypto.randomUUID(),
) {
  const code = `code-${crypto.randomUUID()}`;
  const refreshToken = `refresh-${crypto.randomUUID()}`;
  apple.codes.set(code, { sub, refreshToken });
  const fresh = await challenge(apple.signIn);
  const answer = await call(apple.signIn, "/account", {
    account,
    challenge: fresh,
    identityToken: await identityToken(sub, fresh),
    authorizationCode: code,
  });
  return { account, sub, code, refreshToken, answer };
}

async function signInAs(apple: ReturnType<typeof fakeApple>, sub: string) {
  const fresh = await challenge(apple.signIn);
  return call(apple.signIn, "/sessions", {
    challenge: fresh,
    identityToken: await identityToken(sub, fresh),
  });
}

/** How many sessions the account has, and how many accounts the Apple user has. */
async function rowsOf(account: string, sub: string) {
  const { rows } = await database.execute({
    sql: `SELECT (SELECT count(*) FROM sessions WHERE account_id = ?) AS sessions,
            (SELECT count(*) FROM accounts WHERE apple_sub = ?) AS accounts`,
    args: [account, sub],
  });
  return { sessions: Number(rows[0]?.["sessions"]), accounts: Number(rows[0]?.["accounts"]) };
}

async function accountRow(id: string) {
  const { rows } = await database.execute({
    sql: "SELECT apple_sub, apple_refresh_token, tier FROM accounts WHERE id = ?",
    args: [id],
  });
  return rows[0];
}

describe("making an account", () => {
  it("makes it from a valid ID token and code, with a session the writings routes take", async () => {
    const apple = fakeApple();
    const { account, sub, code, answer } = await makeAccount(apple);

    expect(answer.status).toBe(201);
    const { token } = await answer.json<{ token: string }>();
    expect(token).toMatch(/^s1\./);
    expect(await accountRow(account)).toMatchObject({ apple_sub: sub, tier: "basic" });
    const exchange = apple.asked.find((asked) => asked.url === appleTokenUrl);
    expect(exchange?.form?.get("code")).toBe(code);
    expect(exchange?.form?.get("client_id")).toBe(env.APPLE_CLIENT_ID);

    const listed = await deployed("/writings", { headers: { Authorization: `Bearer ${token}` } });
    expect(listed.status).toBe(200);
    expect(await listed.json()).toEqual({ writings: [] });
  });

  it("keeps Apple's refresh token only sealed, opening only on its own account", async () => {
    const apple = fakeApple();
    const { account, refreshToken } = await makeAccount(apple);

    const kept = (await accountRow(account))?.["apple_refresh_token"];
    if (!(kept instanceof ArrayBuffer)) {
      throw new Error("accounts.apple_refresh_token is a BLOB");
    }
    const bytes = new Uint8Array(kept);
    const plain = new TextEncoder().encode(refreshToken);
    const holdsPlain = bytes.some((_, start) =>
      plain.every((byte, offset) => bytes[start + offset] === byte),
    );
    expect(holdsPlain).toBe(false);
    const tokens = new RefreshTokens(env.REFRESH_TOKEN_KEY);
    expect(await tokens.open(bytes, account)).toBe(refreshToken);
    await expect(tokens.open(bytes, crypto.randomUUID())).rejects.toThrow();
    const otherKey = new RefreshTokens(btoa(String.fromCharCode(...new Uint8Array(32))));
    await expect(otherKey.open(bytes, account)).rejects.toThrow();
  });

  it("refuses a second account for the same Apple user, and keeps the first", async () => {
    const apple = fakeApple();
    const first = await makeAccount(apple);
    expect(first.answer.status).toBe(201);
    const before = await accountRow(first.account);

    const second = await makeAccount(apple, first.sub);

    expect(second.answer.status).toBe(409);
    expect(await accountRow(second.account)).toBeUndefined();
    expect(await accountRow(first.account)).toEqual(before);
    expect(await rowsOf(first.account, first.sub)).toEqual({ sessions: 1, accounts: 1 });
  });

  it("refuses a retry with the same Apple user and account ID, starting no session", async () => {
    const apple = fakeApple();
    const first = await makeAccount(apple);
    const retry = await makeAccount(apple, first.sub, first.account);
    expect(retry.answer.status).toBe(409);
    expect(await rowsOf(first.account, first.sub)).toEqual({ sessions: 1, accounts: 1 });
  });

  it("makes one account when two requests for the same Apple user come at once", async () => {
    const apple = fakeApple();
    const sub = newSub();
    const both = await Promise.all([makeAccount(apple, sub), makeAccount(apple, sub)]);
    expect(both.map((made) => made.answer.status).toSorted((a, b) => a - b)).toEqual([201, 409]);
    expect((await rowsOf(both[0].account, sub)).accounts).toBe(1);
  });

  it("stores an account ID sent in capitals in lowercase", async () => {
    const apple = fakeApple();
    const account = crypto.randomUUID();
    const made = await makeAccount(apple, newSub(), account.toUpperCase());
    expect(made.answer.status).toBe(201);
    expect(await accountRow(account)).toBeDefined();
  });

  it("asks Apple for nothing when the challenge or the ID token doesn't hold", async () => {
    const apple = fakeApple();
    const fresh = await challenge(apple.signIn);
    const answer = await call(apple.signIn, "/account", {
      account: crypto.randomUUID(),
      challenge: fresh,
      identityToken: await identityToken(newSub(), await challenge(apple.signIn)),
      authorizationCode: "code",
    });
    expect(answer.status).toBe(401);
    expect(apple.asked.some((asked) => asked.url === appleTokenUrl)).toBe(false);
  });

  it("refuses an account ID another Apple user's account has", async () => {
    const apple = fakeApple();
    const first = await makeAccount(apple);
    const code = `code-${crypto.randomUUID()}`;
    const sub = newSub();
    apple.codes.set(code, { sub, refreshToken: "refresh-other" });
    const fresh = await challenge(apple.signIn);

    const answer = await call(apple.signIn, "/account", {
      account: first.account,
      challenge: fresh,
      identityToken: await identityToken(sub, fresh),
      authorizationCode: code,
    });

    expect(answer.status).toBe(409);
    expect(await accountRow(first.account)).toMatchObject({ apple_sub: first.sub });
    expect(await rowsOf(first.account, sub)).toEqual({ sessions: 1, accounts: 0 });
  });

  it("refuses a code Apple turns down, and a code for another Apple user", async () => {
    const apple = fakeApple();
    const sub = newSub();
    const account = crypto.randomUUID();
    let fresh = await challenge(apple.signIn);
    const unknown = await call(apple.signIn, "/account", {
      account,
      challenge: fresh,
      identityToken: await identityToken(sub, fresh),
      authorizationCode: "a code Apple never gave",
    });
    expect(unknown.status).toBe(401);

    apple.codes.set("someone else's", { sub: newSub(), refreshToken: "refresh-x" });
    fresh = await challenge(apple.signIn);
    const another = await call(apple.signIn, "/account", {
      account,
      challenge: fresh,
      identityToken: await identityToken(sub, fresh),
      authorizationCode: "someone else's",
    });
    expect(another.status).toBe(401);
    expect(await accountRow(account)).toBeUndefined();
  });

  it("signs to Apple with the .p8 key given as only its base64 lines", async () => {
    const lines = clientKeyPem.split("\n").filter((line) => !line.startsWith("-----"));
    const apple = fakeApple({ key: lines.join("") });
    expect((await makeAccount(apple)).answer.status).toBe(201);
  });

  it.each([
    [
      "no answer",
      () => {
        throw new TypeError("Network connection lost.");
      },
    ],
    [
      "tokens with a status that isn't OK",
      () =>
        Response.json(
          {
            refresh_token: "refresh",
            id_token: `e30.${base64url(new TextEncoder().encode(JSON.stringify({ iss: appleIssuer, sub: "x" })))}.e30`,
          },
          { status: 302 },
        ),
    ],
    ["a 503 page", () => new Response("<html>busy</html>", { status: 503 })],
    ["a 500 page", () => new Response("<html>oops</html>", { status: 500 })],
    ["invalid_grant with a 500", () => Response.json({ error: "invalid_grant" }, { status: 500 })],
    [
      "an ID token that isn't Apple's",
      () =>
        Response.json({
          refresh_token: "refresh",
          id_token: `e30.${base64url(new TextEncoder().encode(JSON.stringify({ iss: "https://example.com", sub: "x" })))}.e30`,
        }),
    ],
    ["a 200 that isn't JSON", () => new Response("<html>ok</html>")],
    ["a 200 with no ID token", () => Response.json({ refresh_token: "refresh" })],
  ])("answers 502 when Apple's token endpoint gives %s, and makes nothing", async (_, answer) => {
    const apple = fakeApple({ answer });
    const made = await makeAccount(apple);
    expect(made.answer.status).toBe(502);
    expect(await accountRow(made.account)).toBeUndefined();
  });

  it.each([
    ["401 invalid_grant", () => Response.json({ error: "invalid_grant" }, { status: 401 })],
  ])("takes %s as Apple refusing the code", async (_, answer) => {
    const made = await makeAccount(fakeApple({ answer }));
    expect(made.answer.status).toBe(401);
  });

  it.each([
    ["400 invalid_client", () => Response.json({ error: "invalid_client" }, { status: 400 })],
    ["401 invalid_client", () => Response.json({ error: "invalid_client" }, { status: 401 })],
    [
      "400 unauthorized_client",
      () => Response.json({ error: "unauthorized_client" }, { status: 400 }),
    ],
    ["a 400 page that isn't JSON", () => new Response("<html>bad</html>", { status: 400 })],
  ])("stops on %s from Apple, the Worker's own fault", async (_, answer) => {
    await expect(makeAccount(fakeApple({ answer }))).rejects.toThrow(/token endpoint answered 4/);
  });

  it.each([
    ["no account ID", { account: undefined }],
    ["an account ID that isn't a UUID", { account: "not-a-uuid" }],
    ["an account ID with something before it", { account: `x${crypto.randomUUID()}` }],
    ["an account ID with something after it", { account: `${crypto.randomUUID()}x` }],
    ["no authorization code", { authorizationCode: undefined }],
  ])("refuses a request with %s", async (_, change) => {
    const apple = fakeApple();
    const sub = newSub();
    const fresh = await challenge(apple.signIn);
    const answer = await call(apple.signIn, "/account", {
      account: crypto.randomUUID(),
      challenge: fresh,
      identityToken: await identityToken(sub, fresh),
      authorizationCode: "code",
      ...change,
    });
    expect(answer.status).toBe(400);
  });
});

describe("a challenge", () => {
  it("is refused the second time, whichever route used it first", async () => {
    const apple = fakeApple();
    const { account, sub, answer } = await makeAccount(apple);
    expect(answer.status).toBe(201);

    const fresh = await challenge(apple.signIn);
    const body = { challenge: fresh, identityToken: await identityToken(sub, fresh) };
    expect((await call(apple.signIn, "/sessions", body)).status).toBe(200);
    expect((await call(apple.signIn, "/sessions", body)).status).toBe(401);
    expect(await rowsOf(account, sub)).toEqual({ sessions: 2, accounts: 1 });

    const code = `code-${crypto.randomUUID()}`;
    const otherSub = newSub();
    const otherAccount = crypto.randomUUID();
    apple.codes.set(code, { sub: otherSub, refreshToken: "refresh-y" });
    const again = await call(apple.signIn, "/account", {
      challenge: fresh,
      identityToken: await identityToken(otherSub, fresh),
      account: otherAccount,
      authorizationCode: code,
    });
    expect(again.status).toBe(401);
    expect(await rowsOf(otherAccount, otherSub)).toEqual({ sessions: 0, accounts: 0 });
  });

  it("is taken by only one of several requests that send it at once", async () => {
    const apple = fakeApple();
    const { account, sub } = await makeAccount(apple);
    const fresh = await challenge(apple.signIn);
    const body = { challenge: fresh, identityToken: await identityToken(sub, fresh) };
    const answers = await Promise.all(
      Array.from({ length: 5 }, () => call(apple.signIn, "/sessions", body)),
    );
    expect(answers.map((answer) => answer.status).toSorted((a, b) => a - b)).toEqual([
      200, 401, 401, 401, 401,
    ]);
    expect((await rowsOf(account, sub)).sessions).toBe(2);
  });

  it("is refused when it expires while the Worker waits on Apple", async () => {
    const apple = fakeApple({ delay: 300 });
    const sub = newSub();
    const code = `code-${crypto.randomUUID()}`;
    apple.codes.set(code, { sub, refreshToken: "refresh-late" });
    const nearlyExpired = await new Challenges(env.CHALLENGE_KEY).issue(
      Date.now() - challengeLifetime + 400,
    );
    const account = crypto.randomUUID();
    const answer = await call(apple.signIn, "/account", {
      account,
      challenge: nearlyExpired,
      identityToken: await identityToken(sub, nearlyExpired),
      authorizationCode: code,
    });
    expect(answer.status).toBe(401);
    expect(await accountRow(account)).toBeUndefined();

    const signIn = fakeApple({ delay: 600 });
    const { sub: existing } = await makeAccount(fakeApple());
    const late = await new Challenges(env.CHALLENGE_KEY).issue(
      Date.now() - challengeLifetime + 300,
    );
    const session = await call(signIn.signIn, "/sessions", {
      challenge: late,
      identityToken: await identityToken(existing, late),
    });
    expect(session.status).toBe(401);
  });

  it("used by one account's request is refused to the next even when that made nothing", async () => {
    const apple = fakeApple();
    const first = await makeAccount(apple);
    const fresh = await challenge(apple.signIn);
    const code = `code-${crypto.randomUUID()}`;
    apple.codes.set(code, { sub: first.sub, refreshToken: "refresh-z" });
    const body = {
      account: crypto.randomUUID(),
      challenge: fresh,
      identityToken: await identityToken(first.sub, fresh),
      authorizationCode: code,
    };
    expect((await call(apple.signIn, "/account", body)).status).toBe(409);

    expect(
      (
        await call(apple.signIn, "/sessions", {
          challenge: fresh,
          identityToken: body.identityToken,
        })
      ).status,
    ).toBe(401);
  });

  it.each([
    ["made up", async () => `${Date.now() + 60_000}.${"A".repeat(22)}.${"A".repeat(43)}`],
    [
      "given out by a server with another key",
      () => new Challenges(btoa(String.fromCharCode(...new Uint8Array(32)))).issue(Date.now()),
    ],
    ["expired", () => new Challenges(env.CHALLENGE_KEY).issue(Date.now() - challengeLifetime - 1)],
  ])("is refused when %s", async (_, made) => {
    const apple = fakeApple();
    const { sub } = await makeAccount(apple);
    const value = await made();
    const answer = await call(apple.signIn, "/sessions", {
      challenge: value,
      identityToken: await identityToken(sub, value),
    });
    expect(answer.status).toBe(401);
  });

  it("is refused with an ID token made for another challenge", async () => {
    const apple = fakeApple();
    const { sub } = await makeAccount(apple);
    const answer = await call(apple.signIn, "/sessions", {
      challenge: await challenge(apple.signIn),
      identityToken: await identityToken(sub, await challenge(apple.signIn)),
    });
    expect(answer.status).toBe(401);
  });

  it("is refused when only its MAC's spare bits differ", async () => {
    const apple = fakeApple();
    const { sub } = await makeAccount(apple);
    const value = await challenge(apple.signIn);
    const last = value.at(-1) ?? "";
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const index = alphabet.indexOf(last);
    // The last character holds 4 bits of the MAC and 2 spare ones.
    const twin = `${value.slice(0, -1)}${alphabet[index ^ 1] ?? ""}`;
    expect(twin).not.toBe(value);
    const answer = await call(apple.signIn, "/sessions", {
      challenge: twin,
      identityToken: await identityToken(sub, twin),
    });
    expect(answer.status).toBe(401);
  });

  it("is kept as used for an hour past its expiry, and then swept", async () => {
    const apple = fakeApple();
    const { sub } = await makeAccount(apple);
    const fresh = await challenge(apple.signIn);
    await call(apple.signIn, "/sessions", {
      challenge: fresh,
      identityToken: await identityToken(sub, fresh),
    });
    const kept = async () =>
      (
        await database.execute({
          sql: "SELECT count(*) AS n FROM used_challenges WHERE value = ?",
          args: [fresh],
        })
      ).rows[0]?.["n"];
    const swept = Number(fresh.split(".")[0]) + 60 * 60 * 1000;

    await store.sweep(swept - 1);
    expect(await kept()).toBe(1);
    await store.sweep(swept);
    expect(await kept()).toBe(0);
  });

  it("checked in time but used after a sweep past its expiry is still refused", async () => {
    const apple = fakeApple();
    const { sub } = await makeAccount(apple);
    const signIn = await apple.signIn;
    const issued = Date.now();
    const checked = await signIn.challenges.check(await signIn.challenges.issue(issued), issued);
    if (checked === undefined) {
      throw new Error("a challenge just given out passes its check");
    }
    const first = await store.signIn(sub, checked, (await newSessionToken()).caller, issued);
    expect(first.signedIn).toBe(true);

    await store.sweep(checked.expires);
    const late = await store.signIn(
      sub,
      checked,
      (await newSessionToken()).caller,
      checked.expires,
    );
    expect(late).toEqual({ signedIn: false, reason: "challenge-used" });
  });

  it("checked in time but first used after it expired is refused", async () => {
    const apple = fakeApple();
    const { sub } = await makeAccount(apple);
    const signIn = await apple.signIn;
    const issued = Date.now();
    const checked = await signIn.challenges.check(await signIn.challenges.issue(issued), issued);
    if (checked === undefined) {
      throw new Error("a challenge just given out passes its check");
    }
    const late = await store.signIn(
      sub,
      checked,
      (await newSessionToken()).caller,
      checked.expires,
    );
    expect(late).toEqual({ signedIn: false, reason: "challenge-used" });
  });
});

describe("signing in", () => {
  it("answers 401 for an ID token that isn't a JWS", async () => {
    const apple = fakeApple();
    const answer = await call(apple.signIn, "/sessions", {
      challenge: await challenge(apple.signIn),
      identityToken: "not.a-token",
    });
    expect(answer.status).toBe(401);
  });

  it("answers 400 for a body that isn't JSON", async () => {
    const apple = fakeApple();
    const request = new Request("https://mai.test/sessions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{not json",
    });
    expect((await serve(request, await apple.signIn)).status).toBe(400);
  });

  it("answers 502 when Apple's keys can't be fetched", async () => {
    const apple = fakeApple({ keysAnswer: () => new Response("down", { status: 503 }) });
    const fresh = await challenge(apple.signIn);
    const answer = await call(apple.signIn, "/sessions", {
      challenge: fresh,
      identityToken: await identityToken(newSub(), fresh),
    });
    expect(answer.status).toBe(502);
  });

  it.each([
    ["application/json; charset=utf-8", 404],
    ["text/plain", 400],
  ])("takes a body sent as %s with %i", async (contentType, status) => {
    const apple = fakeApple();
    const fresh = await challenge(apple.signIn);
    const request = new Request("https://mai.test/sessions", {
      method: "POST",
      headers: { "Content-Type": contentType },
      body: JSON.stringify({
        challenge: fresh,
        identityToken: await identityToken(newSub(), fresh),
      }),
    });
    expect((await serve(request, await apple.signIn)).status).toBe(status);
  });

  it("starts a session on the Apple user's account that the writings routes take", async () => {
    const apple = fakeApple();
    const { account, sub } = await makeAccount(apple);

    const answer = await signInAs(apple, sub);

    expect(answer.status).toBe(200);
    const body = await answer.json<{ account: string; token: string }>();
    expect(body).toEqual({ account, token: expect.stringMatching(/^s1\./) });
    const listed = await deployed("/writings", {
      headers: { Authorization: `Bearer ${body.token}` },
    });
    expect(listed.status).toBe(200);
  });

  it("answers 404 for an Apple user with no account", async () => {
    const apple = fakeApple();
    expect((await signInAs(apple, newSub())).status).toBe(404);
  });

  it("ends the session on sign-out, and only that session", async () => {
    const apple = fakeApple();
    const made = await makeAccount(apple);
    const { token: kept } = await made.answer.json<{ token: string }>();
    const { token } = await (await signInAs(apple, made.sub)).json<{ token: string }>();
    const out = await deployed("/session", { method: "DELETE", ...as(token) });

    expect(out.status).toBe(204);
    expect((await deployed("/writings", as(token))).status).toBe(401);
    expect((await deployed("/session", { method: "DELETE", ...as(token) })).status).toBe(401);
    expect((await deployed("/writings", as(kept))).status).toBe(200);
  });
});

function as(bearer: string): RequestInit {
  return { headers: { Authorization: `Bearer ${bearer}` } };
}

function putOwnKeyCheck(
  token: string,
  check: Uint8Array<ArrayBuffer>,
  contentType = "application/octet-stream",
): Promise<Response> {
  return deployed("/account/own-key-check", {
    method: "PUT",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": contentType },
    body: check,
  });
}

describe("the own key check", () => {
  const put = putOwnKeyCheck;

  it("is kept once, and a second own key's check is refused", async () => {
    const apple = fakeApple();
    const made = await makeAccount(apple);
    const { token } = await made.answer.json<{ token: string }>();
    const first = crypto.getRandomValues(new Uint8Array(32));

    expect((await put(token, first)).status).toBe(204);
    expect((await put(token, first)).status).toBe(204);
    expect((await put(token, crypto.getRandomValues(new Uint8Array(32)))).status).toBe(409);
  });

  it("is one account's own: another account's check doesn't stop it", async () => {
    const apple = fakeApple();
    const one = await (await makeAccount(apple)).answer.json<{ token: string }>();
    const two = await (await makeAccount(apple)).answer.json<{ token: string }>();
    expect((await put(one.token, crypto.getRandomValues(new Uint8Array(32)))).status).toBe(204);
    expect((await put(two.token, crypto.getRandomValues(new Uint8Array(32)))).status).toBe(204);
  });

  it.each([
    ["31 bytes", new Uint8Array(31), "application/octet-stream", 400],
    ["33 bytes", new Uint8Array(33), "application/octet-stream", 400],
    ["JSON", new Uint8Array(32), "application/json", 415],
  ])("is refused as %s", async (_, check, contentType, status) => {
    const apple = fakeApple();
    const { token } = await (await makeAccount(apple)).answer.json<{ token: string }>();
    expect((await put(token, check, contentType)).status).toBe(status);
    expect((await put(token, new Uint8Array(32))).status).toBe(204);
  });

  it("needs a session", async () => {
    const answer = await deployed("/account/own-key-check", {
      method: "PUT",
      headers: { "Content-Type": "application/octet-stream" },
      body: new Uint8Array(32),
    });
    expect(answer.status).toBe(401);
  });
});
