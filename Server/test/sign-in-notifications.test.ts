import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { createClient } from "@libsql/client/web";
import { beforeAll, describe, expect, it } from "vitest";
import { appleIssuer, appleKeysUrl } from "../src/apple-sign-in";
import { serve, signInOf } from "../src/index";
import { newSessionToken } from "../src/sessions";
import { newAccount, photos } from "./accounts";
import { jwks, makeSignInKey, signIdentityToken, type SignInKey } from "./apple-fakes";

const database = createClient({ url: env.TURSO_URL });

/** The notifications' signer, standing in for Apple's JWKS. */
let signer: SignInKey;

beforeAll(async () => {
  signer = await makeSignInKey("test-key");
});

/**
 * Sends `body` to `POST /apple/sign-in-notifications` as Apple would, with Apple's JWKS answering
 * with `signer`'s key, or with `keysAnswer`.
 */
async function notify(body: string, keysAnswer?: () => Response): Promise<Response> {
  const send = async (url: string): Promise<Response> => {
    if (url !== appleKeysUrl) {
      throw new Error(`the Worker reached ${url}, which the fake Apple doesn't serve`);
    }
    return keysAnswer?.() ?? new Response(await jwks([signer]));
  };
  return serve(
    new Request("https://mai.test/apple/sign-in-notifications", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
    }),
    signInOf(env, send, await caches.open(crypto.randomUUID())),
    photos,
  );
}

type Notification = {
  type?: string;
  sub?: string;
  /** Seconds, as `iat` counts; a second ago when left out. */
  iat?: number;
  claims?: Record<string, unknown>;
  /** `events` written as a JSON string, rather than as an object. */
  eventsAsText?: boolean;
  key?: SignInKey;
  header?: Record<string, unknown>;
};

/** A notification's body as Apple sends it, shaped like the examples in Apple's documentation. */
async function notification(options: Notification): Promise<string> {
  const events = {
    type: options.type ?? "consent-revoked",
    sub: options.sub,
    event_time: Date.now(),
  };
  const payload = await signIdentityToken(
    {
      iss: appleIssuer,
      aud: env.APPLE_CLIENT_ID,
      iat: options.iat ?? Math.floor(Date.now() / 1000) - 1,
      jti: crypto.randomUUID(),
      events: options.eventsAsText === true ? JSON.stringify(events) : events,
      ...options.claims,
    },
    options.key ?? signer,
    options.header,
  );
  return JSON.stringify({ payload });
}

/** An account with two sessions, both started a minute ago, and its Apple user. */
async function accountWithSessions() {
  const started = Date.now() - 60 * 1000;
  const made = await newAccount(undefined, started);
  const second = await newSessionToken();
  await database.execute({
    sql: `INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
          VALUES (?, ?, ?, ?, ?)`,
    args: [second.caller.session, made.account, second.caller.secretSha256, started, started],
  });
  return { ...made, sub: `test.${made.account}`, secondToken: second.token };
}

async function sessionsOf(account: string): Promise<number> {
  const { rows } = await database.execute({
    sql: "SELECT count(*) AS count FROM sessions WHERE account_id = ?",
    args: [account],
  });
  return Number(rows[0]?.["count"]);
}

async function sessionWorks(token: string): Promise<boolean> {
  const answer = await serve(
    new Request("https://mai.test/account", { headers: { Authorization: `Bearer ${token}` } }),
    signInOf(env, () => Promise.reject(new Error("unreached")), caches.default),
    photos,
  );
  expect([200, 401]).toContain(answer.status);
  return answer.status === 200;
}

describe("Sign in with Apple notifications", () => {
  for (const type of ["consent-revoked", "account-deleted", "account-delete"]) {
    it(`ends every session of the account on ${type}, and no other account's`, async () => {
      const one = await accountWithSessions();
      const other = await accountWithSessions();
      const answer = await notify(await notification({ type, sub: one.sub }));
      expect(answer.status).toBe(200);
      expect(await sessionsOf(one.account)).toBe(0);
      expect(await sessionWorks(one.token)).toBe(false);
      expect(await sessionWorks(one.secondToken)).toBe(false);
      expect(await sessionsOf(other.account)).toBe(2);
      expect(await sessionWorks(other.token)).toBe(true);
    });
  }

  it("keeps the account itself on account-deleted", async () => {
    const one = await accountWithSessions();
    expect(
      (await notify(await notification({ type: "account-deleted", sub: one.sub }))).status,
    ).toBe(200);
    const { rows } = await database.execute({
      sql: "SELECT count(*) AS count FROM accounts WHERE id = ?",
      args: [one.account],
    });
    expect(Number(rows[0]?.["count"])).toBe(1);
  });

  for (const type of ["email-enabled", "email-disabled", "some-later-event"]) {
    it(`accepts ${type} and changes nothing`, async () => {
      const one = await accountWithSessions();
      const answer = await notify(await notification({ type, sub: one.sub }));
      expect(answer.status).toBe(200);
      expect(await sessionsOf(one.account)).toBe(2);
    });
  }

  it("reads events written as a JSON string", async () => {
    const one = await accountWithSessions();
    const answer = await notify(await notification({ sub: one.sub, eventsAsText: true }));
    expect(answer.status).toBe(200);
    expect(await sessionsOf(one.account)).toBe(0);
  });

  it("answers 200 for a user with no account", async () => {
    const answer = await notify(await notification({ sub: `unknown.${crypto.randomUUID()}` }));
    expect(answer.status).toBe(200);
  });

  it("does no harm sent again, after the user signed in again", async () => {
    const one = await accountWithSessions();
    // Issued 30 seconds ago; the user signed in again 10 seconds ago, before it was sent again.
    const sent = await notification({ sub: one.sub, iat: Math.floor(Date.now() / 1000) - 30 });
    expect((await notify(sent)).status).toBe(200);
    const again = await newSessionToken();
    const signedInAgain = Date.now() - 10 * 1000;
    await database.execute({
      sql: `INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
            VALUES (?, ?, ?, ?, ?)`,
      args: [
        again.caller.session,
        one.account,
        again.caller.secretSha256,
        signedInAgain,
        Date.now(),
      ],
    });
    expect((await notify(sent)).status).toBe(200);
    expect(await sessionWorks(again.token)).toBe(true);
    expect(await sessionsOf(one.account)).toBe(1);
  });

  it("ends a session started within the second Apple issued it", async () => {
    const one = await accountWithSessions();
    const iat = Math.floor(Date.now() / 1000) - 5;
    await database.execute({
      sql: "UPDATE sessions SET created = ? WHERE account_id = ?",
      args: [iat * 1000 + 999, one.account],
    });
    expect((await notify(await notification({ sub: one.sub, iat }))).status).toBe(200);
    expect(await sessionsOf(one.account)).toBe(0);
  });

  it("keeps a session started as the second after Apple issued it begins", async () => {
    const one = await accountWithSessions();
    const iat = Math.floor(Date.now() / 1000) - 5;
    await database.execute({
      sql: "UPDATE sessions SET created = ? WHERE account_id = ?",
      args: [(iat + 1) * 1000, one.account],
    });
    expect((await notify(await notification({ sub: one.sub, iat }))).status).toBe(200);
    expect(await sessionsOf(one.account)).toBe(2);
  });

  it("ends every session up to now when it carries no iat", async () => {
    const one = await accountWithSessions();
    // Within the last second, so that a cutoff short of now would leave it.
    await database.execute({
      sql: "UPDATE sessions SET created = ? WHERE account_id = ?",
      args: [Date.now() - 500, one.account],
    });
    expect(
      (await notify(await notification({ sub: one.sub, claims: { iat: undefined } }))).status,
    ).toBe(200);
    expect(await sessionsOf(one.account)).toBe(0);
  });
});

describe("a notification refused", () => {
  const refusals: [string, (sub: string) => Promise<string>][] = [
    [
      "signed by another key under Apple's key ID",
      async (sub) => notification({ sub, key: await makeSignInKey("test-key") }),
    ],
    [
      "signed with a key Apple doesn't publish",
      async (sub) => notification({ sub, key: await makeSignInKey("other-key") }),
    ],
    ["with another algorithm", (sub) => notification({ sub, header: { alg: "HS256" } })],
    [
      "from another issuer",
      (sub) => notification({ sub, claims: { iss: "https://appleid.example.com" } }),
    ],
    ["for another app", (sub) => notification({ sub, claims: { aud: "com.example.other" } })],
    ["with no sub", () => notification({})],
    ["with no events", (sub) => notification({ sub, claims: { events: undefined } })],
    ["with events that aren't JSON", (sub) => notification({ sub, claims: { events: "{" } })],
    ["whose payload isn't a JWS", () => Promise.resolve(JSON.stringify({ payload: "a.b" }))],
    ["with no payload", () => Promise.resolve("{}")],
    ["that isn't JSON", () => Promise.resolve("payload")],
  ];
  for (const [name, body] of refusals) {
    it(`answers 400 for one ${name}, and ends no session`, async () => {
      const one = await accountWithSessions();
      const answer = await notify(await body(one.sub));
      expect(answer.status).toBe(400);
      expect(await sessionsOf(one.account)).toBe(2);
    });
  }

  it("answers 502 when Apple's keys can't be fetched, and ends no session", async () => {
    const one = await accountWithSessions();
    const answer = await notify(
      await notification({ sub: one.sub }),
      () => new Response(null, { status: 503 }),
    );
    expect(answer.status).toBe(502);
    expect(await sessionsOf(one.account)).toBe(2);
  });

  it("is a route of the Worker that needs no session", async () => {
    const answer = await exports.default.fetch(
      new Request("https://mai.test/apple/sign-in-notifications", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      }),
    );
    expect(answer.status).toBe(400);
  });
});
