import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { createClient } from "@libsql/client/web";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { deleteLapsedAccounts } from "../src/account-deletion";
import { appleIssuer, appleKeysUrl } from "../src/apple-sign-in";
import { appleRevokeUrl } from "../src/apple-tokens";
import { serve, signInOf } from "../src/index";
import { RefreshTokens } from "../src/refresh-tokens";
import { newSessionToken } from "../src/sessions";
import type { SignIn } from "../src/sign-in";
import { accountTables, type Store } from "../src/store";
import type { Photos } from "../src/photos";
import { newAccount, photos } from "./accounts";
import { jwks, makeSignInKey, signIdentityToken, type SignInKey } from "./apple-fakes";

const database = createClient({ url: env.TURSO_URL });

/** The notifications' signer, standing in for Apple's JWKS. */
let signer: SignInKey;
/** The Worker's Sign in with Apple key, which signs `client_secret` for Apple's revoke endpoint. */
let clientKeyPem: string;

afterEach(() => {
  vi.restoreAllMocks();
});

beforeAll(async () => {
  signer = await makeSignInKey("test-key");
  const made = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ]);
  if (!("privateKey" in made)) {
    throw new Error("ECDSA makes a key pair");
  }
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", made.privateKey);
  if (!(pkcs8 instanceof ArrayBuffer)) {
    throw new Error("a key exported as PKCS #8 is bytes");
  }
  clientKeyPem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...new Uint8Array(pkcs8)))}\n-----END PRIVATE KEY-----`;
});

type FakeApple = {
  keysAnswer?: () => Response;
  /** What the revoke endpoint answers; 200 when left out. */
  revokeAnswer?: () => Response;
  /** Each refresh token the revoke endpoint was sent. */
  revoked: string[];
};

/**
 * What the Worker reaches Apple and Turso through, with Apple's JWKS answering with `signer`'s key,
 * and Apple's revoke endpoint, as `apple` has them.
 */
async function signInWith(apple: FakeApple): Promise<SignIn> {
  const send = async (url: string, init?: RequestInit): Promise<Response> => {
    if (url === appleKeysUrl) {
      return apple.keysAnswer?.() ?? new Response(await jwks([signer]));
    }
    if (url === appleRevokeUrl && init?.body instanceof URLSearchParams) {
      apple.revoked.push(init.body.get("token") ?? "");
      return apple.revokeAnswer?.() ?? new Response(null, { status: 200 });
    }
    throw new Error(`the Worker reached ${url}, which the fake Apple doesn't serve`);
  };
  return signInOf(
    { ...env, APPLE_SIGN_IN_KEY: clientKeyPem },
    send,
    await caches.open(crypto.randomUUID()),
  );
}

/**
 * Sends `body` to `POST /apple/sign-in-notifications` as Apple would, with Apple as `apple` has
 * it, and Turso and R2 as `server` has them.
 */
async function notify(
  body: string,
  apple: FakeApple = { revoked: [] },
  server: { store?: (store: Store) => Store; photos?: Photos } = {},
): Promise<Response> {
  const signIn = await signInWith(apple);
  return serve(
    new Request("https://mai.test/apple/sign-in-notifications", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
    }),
    { ...signIn, store: server.store?.(signIn.store) ?? signIn.store },
    server.photos ?? photos,
  );
}

/** `target` with `name` replaced. */
function replaced<T extends object, K extends keyof T>(target: T, name: K, value: T[K]): T {
  return new Proxy(target, {
    get(inner, key, receiver) {
      if (key === name) return value;
      const found: unknown = Reflect.get(inner, key, receiver);
      return typeof found === "function" ? found.bind(inner) : found;
    },
  });
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

/**
 * An account with two sessions, both started a minute ago, a writing, its subscription, an object
 * in R2, and its Apple user. Its Apple refresh token is sealed as `POST /account` seals it.
 */
async function accountWithSessions() {
  const started = Date.now() - 60 * 1000;
  const made = await newAccount(undefined, started);
  const second = await newSessionToken();
  const refreshToken = `refresh-${crypto.randomUUID()}`;
  await database.batch(
    [
      {
        sql: `INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
              VALUES (?, ?, ?, ?, ?)`,
        args: [second.caller.session, made.account, second.caller.secretSha256, started, started],
      },
      {
        sql: "UPDATE accounts SET apple_refresh_token = ? WHERE id = ?",
        args: [
          await new RefreshTokens(env.REFRESH_TOKEN_KEY).seal(refreshToken, made.account),
          made.account,
        ],
      },
      {
        sql: `INSERT INTO writings (account_id, id, revision, updated, size, envelope)
              VALUES (?, ?, 'r', 0, 3, X'010203')`,
        args: [made.account, crypto.randomUUID()],
      },
    ],
    "write",
  );
  await env.PHOTOS.put(`${made.account}/photo/photo/upload`, "x");
  return { ...made, sub: `test.${made.account}`, secondToken: second.token, refreshToken };
}

async function accountKept(account: string): Promise<boolean> {
  const { rows } = await database.execute({
    sql: "SELECT count(*) AS count FROM accounts WHERE id = ?",
    args: [account],
  });
  return Number(rows[0]?.["count"]) === 1;
}

async function objectsOf(account: string): Promise<number> {
  return (await env.PHOTOS.list({ prefix: `${account}/` })).objects.length;
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

  for (const type of ["account-deleted", "account-delete"]) {
    it(`deletes the account on ${type} as DELETE /account does, and no other account`, async () => {
      const one = await accountWithSessions();
      const other = await accountWithSessions();
      const apple: FakeApple = { revoked: [] };
      expect((await notify(await notification({ type, sub: one.sub }), apple)).status).toBe(200);
      expect(apple.revoked).toEqual([one.refreshToken]);
      expect(await accountKept(one.account)).toBe(false);
      for (const table of accountTables) {
        const { rows } = await database.execute({
          sql: `SELECT count(*) AS count FROM ${table} WHERE account_id = ?`,
          args: [one.account],
        });
        expect(Number(rows[0]?.["count"]), table).toBe(0);
      }
      expect(await objectsOf(one.account)).toBe(0);
      expect(await accountKept(other.account)).toBe(true);
      expect(await objectsOf(other.account)).toBe(1);
      expect(await sessionWorks(other.token)).toBe(true);
    });
  }

  it("keeps the account on consent-revoked", async () => {
    const one = await accountWithSessions();
    const apple: FakeApple = { revoked: [] };
    expect((await notify(await notification({ sub: one.sub }), apple)).status).toBe(200);
    expect(apple.revoked).toEqual([]);
    expect(await accountKept(one.account)).toBe(true);
    expect(await objectsOf(one.account)).toBe(1);
  });

  it("does no harm when account-deleted is sent again", async () => {
    const one = await accountWithSessions();
    const sent = await notification({ type: "account-deleted", sub: one.sub });
    expect((await notify(sent)).status).toBe(200);
    const apple: FakeApple = { revoked: [] };
    expect((await notify(sent, apple)).status).toBe(200);
    expect(apple.revoked).toEqual([]);
  });

  it("leaves the account marked when Apple's revoke endpoint doesn't answer, for the cron trigger to finish", async () => {
    const one = await accountWithSessions();
    const sent = await notification({ type: "account-deleted", sub: one.sub });
    const down: FakeApple = {
      revoked: [],
      revokeAnswer: () => new Response(null, { status: 503 }),
    };
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    expect((await notify(sent, down)).status).toBe(200);
    expect(await accountKept(one.account)).toBe(true);
    expect(await objectsOf(one.account)).toBe(1);
    expect(await sessionsOf(one.account)).toBe(0);

    // The cron trigger, kept to this account: other test files' accounts are due too.
    const apple: FakeApple = { revoked: [] };
    const signIn = await signInWith(apple);
    const store = replaced(signIn.store, "dueForDeletion", async (now: number) =>
      (await signIn.store.dueForDeletion(now, 1000)).filter(
        ({ account }) => account === one.account,
      ),
    );
    await deleteLapsedAccounts({ ...signIn, store }, photos, Date.now());
    expect(apple.revoked).toEqual([one.refreshToken]);
    expect(await accountKept(one.account)).toBe(false);
    expect(await objectsOf(one.account)).toBe(0);
  });

  it("ends the sessions first, even when the deletion then fails", async () => {
    const one = await accountWithSessions();
    const failing = replaced(env.PHOTOS, "delete", () =>
      Promise.reject(new Error("R2 is unavailable")),
    );
    await expect(
      notify(await notification({ type: "account-deleted", sub: one.sub }), undefined, {
        photos: { bucket: failing, keepAlive: () => undefined },
      }),
    ).rejects.toThrow(/R2 is unavailable/);
    expect(await sessionsOf(one.account)).toBe(0);
    expect(await accountKept(one.account)).toBe(true);
  });

  it("sweeps R2 again for a photo stored while the rows went", async () => {
    const one = await accountWithSessions();
    const late = `${one.account}/late/photo/upload`;
    const kept: Promise<unknown>[] = [];
    const answer = await notify(
      await notification({ type: "account-deleted", sub: one.sub }),
      undefined,
      {
        store: (store) =>
          replaced(store, "deleteAccount", async (account) => {
            await env.PHOTOS.put(late, "x");
            return store.deleteAccount(account);
          }),
        photos: { bucket: env.PHOTOS, keepAlive: (work) => kept.push(work) },
      },
    );
    await Promise.all(kept);
    expect(answer.status).toBe(200);
    expect(await objectsOf(one.account)).toBe(0);
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
    const answer = await notify(await notification({ sub: one.sub }), {
      revoked: [],
      keysAnswer: () => new Response(null, { status: 503 }),
    });
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
