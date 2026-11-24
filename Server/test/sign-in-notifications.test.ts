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

/** A request to the Worker as deployed, as `token`'s device or agent. */
function deployed(path: string, token: string, method = "GET", body?: unknown): Promise<Response> {
  return exports.default.fetch(
    new Request(`https://mai.test${path}`, {
      method,
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    }),
  );
}

/**
 * Approves an agent for the account of the session `token`, turns read mode on for a minute, and
 * sends the agent a copy of the account's writing; answers the agent's token.
 */
async function readingAgent(account: string, token: string): Promise<string> {
  const key = Array.from(crypto.getRandomValues(new Uint8Array(32)), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  const approved = await deployed("/agents", token, "POST", { publicKey: key, signature: "00" });
  expect(approved.status).toBe(201);
  const agent = await approved.json<{ agent: string; token: string }>();
  const until = Date.now() + 60 * 1000;
  expect((await deployed("/read-mode", token, "PUT", { until })).status).toBe(200);
  const revision = "a".repeat(64);
  await database.execute({
    sql: "UPDATE writings SET revision = ? WHERE account_id = ?",
    args: [revision, account],
  });
  const { rows } = await database.execute({
    sql: "SELECT id FROM writings WHERE account_id = ?",
    args: [account],
  });
  const sent = await deployed("/copies", token, "POST", {
    expires: until,
    copies: [{ writing: rows[0]?.["id"], agent: agent.agent, revision, wrapped: "00" }],
  });
  expect(sent.status).toBe(200);
  expect(await agentReads(agent.token)).toBe(1);
  return agent.token;
}

/** How many writings the agent of `token` can read; 401 counts as none. */
async function agentReads(token: string): Promise<number> {
  const answer = await deployed("/agent/writings", token);
  if (answer.status === 401) {
    return 0;
  }
  expect(answer.status).toBe(200);
  return (await answer.json<{ writings: unknown[] }>()).writings.length;
}

/** Whether the account's read mode is kept, with how many copies, and its agents unrevoked. */
async function readModeOf(account: string) {
  const { rows } = await database.execute({
    sql: `SELECT (SELECT count(*) FROM read_modes WHERE account_id = :account) AS modes,
            (SELECT count(*) FROM copies WHERE account_id = :account) AS copies,
            (SELECT count(*) FROM agents WHERE account_id = :account AND revoked = 0) AS agents`,
    args: { account },
  });
  return {
    modes: Number(rows[0]?.["modes"]),
    copies: Number(rows[0]?.["copies"]),
    agents: Number(rows[0]?.["agents"]),
  };
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

  it("turns read mode off on consent-revoked, so agents read nothing, and no other account's", async () => {
    const one = await accountWithSessions();
    const other = await accountWithSessions();
    const agent = await readingAgent(one.account, one.token);
    const otherAgent = await readingAgent(other.account, other.token);

    expect((await notify(await notification({ sub: one.sub }))).status).toBe(200);

    expect(await agentReads(agent)).toBe(0);
    expect(await readModeOf(one.account)).toEqual({ modes: 0, copies: 0, agents: 1 });
    expect(await agentReads(otherAgent)).toBe(1);
    expect(await readModeOf(other.account)).toEqual({ modes: 1, copies: 1, agents: 1 });
  });

  it("keeps read mode turned on again after the user signed in again, when sent again", async () => {
    const one = await accountWithSessions();
    await readingAgent(one.account, one.token);
    const sent = await notification({ sub: one.sub, iat: Math.floor(Date.now() / 1000) - 30 });
    expect((await notify(sent)).status).toBe(200);
    const again = await newSessionToken();
    await database.execute({
      sql: `INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
            VALUES (?, ?, ?, ?, ?)`,
      args: [
        again.caller.session,
        one.account,
        again.caller.secretSha256,
        Date.now() - 10 * 1000,
        Date.now(),
      ],
    });
    const agent = await readingAgent(one.account, again.token);

    expect((await notify(sent)).status).toBe(200);

    expect(await agentReads(agent)).toBe(1);
    expect((await readModeOf(one.account)).modes).toBe(1);
  });

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

/** Puts read mode and copies straight into the database, for states the routes don't make. */
async function rawReadMode(
  account: string,
  until: number | undefined,
  copies: { agent: string; expires: number }[],
) {
  const { rows } = await database.execute({
    sql: "SELECT id FROM writings WHERE account_id = ?",
    args: [account],
  });
  const writing = rows[0]?.["id"];
  if (typeof writing !== "string") {
    throw new Error("the account has a writing");
  }
  await database.batch(
    [
      ...(until === undefined
        ? []
        : [
            {
              sql: "INSERT INTO read_modes (account_id, until) VALUES (?, ?)",
              args: [account, until],
            },
          ]),
      ...copies.map((copy) => ({
        sql: `INSERT INTO copies (account_id, writing_id, agent_id, revision, wrapped, expires)
              VALUES (?, ?, ?, 'r', X'00', ?)`,
        args: [account, writing, copy.agent, copy.expires],
      })),
    ],
    "write",
  );
}

async function sessionAt(account: string, created: number): Promise<string> {
  const again = await newSessionToken();
  await database.execute({
    sql: `INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
          VALUES (?, ?, ?, ?, ?)`,
    args: [again.caller.session, account, again.caller.secretSha256, created, Date.now()],
  });
  return again.token;
}

describe("read mode on a notification", () => {
  it("read mode on, no copies: turned off", async () => {
    const one = await accountWithSessions();
    await rawReadMode(one.account, Date.now() + 60_000, []);
    expect((await notify(await notification({ sub: one.sub }))).status).toBe(200);
    expect(await readModeOf(one.account)).toEqual({ modes: 0, copies: 0, agents: 0 });
  });

  it("copies with read mode past its end: deleted", async () => {
    const one = await accountWithSessions();
    const past = Date.now() - 1000;
    await rawReadMode(one.account, past, [{ agent: crypto.randomUUID(), expires: past }]);
    expect((await notify(await notification({ sub: one.sub }))).status).toBe(200);
    expect(await readModeOf(one.account)).toEqual({ modes: 0, copies: 0, agents: 0 });
  });

  it("copies with no read_modes row: deleted", async () => {
    const one = await accountWithSessions();
    await rawReadMode(one.account, undefined, [
      { agent: crypto.randomUUID(), expires: Date.now() + 1000 },
    ]);
    expect((await notify(await notification({ sub: one.sub }))).status).toBe(200);
    expect((await readModeOf(one.account)).copies).toBe(0);
  });

  it("several agents, one revoked, an exclusion: every copy gone, agents and exclusion as they were", async () => {
    const one = await accountWithSessions();
    const agents: { agent: string; token: string }[] = [];
    for (let i = 0; i < 3; i++) {
      const key = Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) =>
        b.toString(16).padStart(2, "0"),
      ).join("");
      const made = await deployed("/agents", one.token, "POST", {
        publicKey: key,
        signature: "00",
      });
      expect(made.status).toBe(201);
      agents.push(await made.json());
    }
    const [agent0, agent1, agent2] = agents;
    if (agent0 === undefined || agent1 === undefined || agent2 === undefined) {
      throw new Error("three agents were approved");
    }
    expect((await deployed(`/agents/${agents[2]?.agent}`, one.token, "DELETE")).status).toBe(204);
    const until = Date.now() + 60_000;
    expect((await deployed("/read-mode", one.token, "PUT", { until })).status).toBe(200);
    const revision = "b".repeat(64);
    await database.execute({
      sql: "UPDATE writings SET revision = ? WHERE account_id = ?",
      args: [revision, one.account],
    });
    const excluded = crypto.randomUUID();
    expect((await deployed(`/exclusions/${excluded}`, one.token, "PUT")).status).toBe(204);
    const { rows } = await database.execute({
      sql: "SELECT id FROM writings WHERE account_id = ?",
      args: [one.account],
    });
    const sent = await deployed("/copies", one.token, "POST", {
      expires: until,
      copies: agents
        .slice(0, 2)
        .map(({ agent }) => ({ writing: rows[0]?.["id"], agent, revision, wrapped: "00" })),
    });
    expect(sent.status).toBe(200);
    expect(await agentReads(agent0.token)).toBe(1);
    expect(await agentReads(agent1.token)).toBe(1);

    expect((await notify(await notification({ sub: one.sub }))).status).toBe(200);

    expect(await readModeOf(one.account)).toEqual({ modes: 0, copies: 0, agents: 2 });
    expect(await agentReads(agent0.token)).toBe(0);
    expect(await agentReads(agent1.token)).toBe(0);
    const ex = await database.execute({
      sql: "SELECT count(*) AS n FROM exclusions WHERE account_id = ?",
      args: [one.account],
    });
    expect(Number(ex.rows[0]?.["n"])).toBe(1);
    const revoked = await database.execute({
      sql: "SELECT revoked FROM agents WHERE id = ?",
      args: [agent2.agent],
    });
    expect(Number(revoked.rows[0]?.["revoked"])).toBe(1);
  });

  it("account-deleted whose deletion then fails: read mode already off", async () => {
    const one = await accountWithSessions();
    const agent = await readingAgent(one.account, one.token);
    const failing = replaced(env.PHOTOS, "delete", () =>
      Promise.reject(new Error("R2 is unavailable")),
    );
    await expect(
      notify(await notification({ type: "account-deleted", sub: one.sub }), undefined, {
        photos: { bucket: failing, keepAlive: () => undefined },
      }),
    ).rejects.toThrow(/R2 is unavailable/);
    expect(await accountKept(one.account)).toBe(true);
    expect(await readModeOf(one.account)).toEqual({ modes: 0, copies: 0, agents: 1 });
    expect(await agentReads(agent)).toBe(0);
  });

  it("account-deleted after the user signed in again: account still deleted", async () => {
    const one = await accountWithSessions();
    const iat = Math.floor(Date.now() / 1000) - 30;
    await sessionAt(one.account, Date.now() - 10_000);
    await rawReadMode(one.account, Date.now() + 60_000, []);
    expect(
      (await notify(await notification({ type: "account-deleted", sub: one.sub, iat }))).status,
    ).toBe(200);
    expect(await accountKept(one.account)).toBe(false);
    expect(await readModeOf(one.account)).toEqual({ modes: 0, copies: 0, agents: 0 });
  });

  it("no iat: read mode off, even with a session started within the last second", async () => {
    const one = await accountWithSessions();
    await database.execute({
      sql: "UPDATE sessions SET created = ? WHERE account_id = ?",
      args: [Date.now() - 500, one.account],
    });
    await readingAgent(one.account, one.token);
    expect(
      (await notify(await notification({ sub: one.sub, claims: { iat: undefined } }))).status,
    ).toBe(200);
    expect(await readModeOf(one.account)).toEqual({ modes: 0, copies: 0, agents: 1 });
  });

  it("iat an hour in the future: read mode off and every session ended", async () => {
    const one = await accountWithSessions();
    await sessionAt(one.account, Date.now() - 1000);
    await readingAgent(one.account, one.token);
    const iat = Math.floor(Date.now() / 1000) + 3600;
    expect((await notify(await notification({ sub: one.sub, iat }))).status).toBe(200);
    expect(await readModeOf(one.account)).toEqual({ modes: 0, copies: 0, agents: 1 });
    expect(await sessionsOf(one.account)).toBe(0);
  });

  it("iat not a whole number: read mode off", async () => {
    const one = await accountWithSessions();
    await readingAgent(one.account, one.token);
    expect(
      (await notify(await notification({ sub: one.sub, claims: { iat: "soon" } }))).status,
    ).toBe(200);
    expect((await readModeOf(one.account)).modes).toBe(0);
  });

  it("a later session started within iat's second: read mode off", async () => {
    const one = await accountWithSessions();
    const iat = Math.floor(Date.now() / 1000) - 5;
    await sessionAt(one.account, iat * 1000 + 999);
    await rawReadMode(one.account, Date.now() + 60_000, [
      { agent: crypto.randomUUID(), expires: Date.now() + 60_000 },
    ]);
    expect((await notify(await notification({ sub: one.sub, iat }))).status).toBe(200);
    expect(await readModeOf(one.account)).toEqual({ modes: 0, copies: 0, agents: 0 });
  });

  it("a later session started as the next second begins: read mode and copies kept", async () => {
    const one = await accountWithSessions();
    const iat = Math.floor(Date.now() / 1000) - 5;
    await sessionAt(one.account, (iat + 1) * 1000);
    await rawReadMode(one.account, Date.now() + 60_000, [
      { agent: crypto.randomUUID(), expires: Date.now() + 60_000 },
    ]);
    expect((await notify(await notification({ sub: one.sub, iat }))).status).toBe(200);
    expect(await readModeOf(one.account)).toEqual({ modes: 1, copies: 1, agents: 0 });
    expect(await sessionsOf(one.account)).toBe(1);
  });

  it("sent twice before a later sign-in: off both times, no error", async () => {
    const one = await accountWithSessions();
    await readingAgent(one.account, one.token);
    const sent = await notification({ sub: one.sub });
    expect((await notify(sent)).status).toBe(200);
    expect((await notify(sent)).status).toBe(200);
    expect(await readModeOf(one.account)).toEqual({ modes: 0, copies: 0, agents: 1 });
  });

  it("sent again after the later sign-in's session ended: read mode off again", async () => {
    const one = await accountWithSessions();
    const sent = await notification({ sub: one.sub, iat: Math.floor(Date.now() / 1000) - 30 });
    expect((await notify(sent)).status).toBe(200);
    const token = await sessionAt(one.account, Date.now() - 10_000);
    const agent = await readingAgent(one.account, token);
    expect((await deployed("/session", token, "DELETE")).status).toBeLessThan(500);
    await database.execute({
      sql: "DELETE FROM sessions WHERE account_id = ?",
      args: [one.account],
    });
    expect((await notify(sent)).status).toBe(200);
    expect(await agentReads(agent)).toBe(0);
    expect((await readModeOf(one.account)).modes).toBe(0);
  });

  it("sent again after the later session went 180 days unused, before the cron sweep: read mode off again", async () => {
    const one = await accountWithSessions();
    const day = 24 * 60 * 60 * 1000;
    const iat = Math.floor((Date.now() - 200 * day) / 1000);
    const dead = Date.now() - 190 * day;
    // The account's own sessions started before the notification was issued.
    await database.execute({
      sql: "UPDATE sessions SET created = ? WHERE account_id = ?",
      args: [Date.now() - 210 * day, one.account],
    });
    const again = await newSessionToken();
    await database.execute({
      sql: `INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
            VALUES (?, ?, ?, ?, ?)`,
      args: [again.caller.session, one.account, again.caller.secretSha256, dead, dead],
    });
    await rawReadMode(one.account, Date.now() + 60_000, []);
    expect(await sessionWorks(again.token)).toBe(false);
    expect((await notify(await notification({ sub: one.sub, iat }))).status).toBe(200);
    expect((await readModeOf(one.account)).modes).toBe(0);
  });

  it("a sub with no account: no account's read mode touched", async () => {
    const one = await accountWithSessions();
    const agent = await readingAgent(one.account, one.token);
    expect(
      (await notify(await notification({ sub: `unknown.${crypto.randomUUID()}` }))).status,
    ).toBe(200);
    expect(await agentReads(agent)).toBe(1);
    expect(await readModeOf(one.account)).toEqual({ modes: 1, copies: 1, agents: 1 });
  });

  it("PUT /read-mode and POST /copies from the old session racing the notification never leave read mode on", async () => {
    for (let round = 0; round < 15; round++) {
      const one = await accountWithSessions();
      const agent = await readingAgent(one.account, one.token);
      const until = Date.now() + 120_000;
      const revision = "a".repeat(64);
      const { rows } = await database.execute({
        sql: "SELECT id FROM writings WHERE account_id = ?",
        args: [one.account],
      });
      const agentId = (
        await database.execute({
          sql: "SELECT id FROM agents WHERE account_id = ?",
          args: [one.account],
        })
      ).rows[0]?.["id"];
      const body = await notification({ sub: one.sub });
      const racing = [
        deployed("/read-mode", one.token, "PUT", { until }),
        deployed("/copies", one.secondToken, "POST", {
          expires: until,
          copies: [{ writing: rows[0]?.["id"], agent: agentId, revision, wrapped: "00" }],
        }),
      ];
      const order = round % 3;
      const all =
        order === 0
          ? [notify(body), ...racing]
          : order === 1
            ? [...racing, notify(body)]
            : [...racing.slice(0, 1), notify(body), ...racing.slice(1)];
      await Promise.all(all);
      expect(await readModeOf(one.account), `round ${round}`).toEqual({
        modes: 0,
        copies: 0,
        agents: 1,
      });
      expect(await agentReads(agent)).toBe(0);
    }
  });
});
