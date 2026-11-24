import { env } from "cloudflare:test";
import { createClient } from "@libsql/client/web";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { deleteLapsedAccounts, lapsedDeletedAtOnce } from "../src/account-deletion";
import { parseAccountId } from "../src/account-id";
import { appleIssuer } from "../src/apple-sign-in";
import { appleRevokeUrl } from "../src/apple-tokens";
import { serve, signInOf } from "../src/index";
import { readCompactJws } from "../src/jws";
import { RefreshTokens } from "../src/refresh-tokens";
import { newSessionToken } from "../src/sessions";
import type { SignIn } from "../src/sign-in";
import { accountTables, lapsedKept, type Purchase, type Store } from "../src/store";
import { newAccount, products, runCron, store as testStore } from "./accounts";

const database = createClient({ url: env.TURSO_URL });
const day = 24 * 60 * 60 * 1000;
const month = 30 * day;

/** The Worker's Sign in with Apple key; the fake revoke endpoint checks `client_secret` with it. */
let clientKey: CryptoKeyPair;
let clientKeyPem: string;

beforeAll(async () => {
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
  clientKeyPem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...new Uint8Array(pkcs8)))}\n-----END PRIVATE KEY-----`;
});

/**
 * Apple's revoke endpoint, answering from the test: 200 for this app's well-made request, as
 * Apple does for a token revoked before too, or what `answer` gives. Every token it was sent is in
 * `revoked`.
 */
function fakeApple(answer?: () => Response | Promise<Response>) {
  const revoked: string[] = [];
  const send = async (url: string, init?: RequestInit): Promise<Response> => {
    if (url !== appleRevokeUrl || !(init?.body instanceof URLSearchParams)) {
      throw new Error(`deleting an account reached ${url}, which the fake Apple doesn't serve`);
    }
    const form = init.body;
    if (answer !== undefined) {
      return answer();
    }
    const fromThisApp =
      form.get("client_id") === env.APPLE_CLIENT_ID &&
      (await clientSecretHolds(form.get("client_secret") ?? ""));
    if (!fromThisApp || form.get("token_type_hint") !== "refresh_token") {
      return Response.json({ error: "invalid_client" }, { status: 400 });
    }
    revoked.push(form.get("token") ?? "");
    return new Response(null, { status: 200 });
  };
  return { revoked, send };
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
  const { iss, aud, sub } = jws.payload;
  return (
    signed &&
    jws.header["kid"] === env.APPLE_SIGN_IN_KEY_ID &&
    iss === env.APPLE_TEAM_ID &&
    aud === appleIssuer &&
    sub === env.APPLE_CLIENT_ID
  );
}

type Server = {
  apple?: ReturnType<typeof fakeApple>;
  bucket?: R2Bucket;
  /** Replaces what the routes reach Turso through. */
  store?: (store: Store) => Store;
  /**
   * Where what the Worker keeps alive past the request goes, unawaited, when given: each resolves
   * to undefined, or to the error it failed with.
   */
  kept?: Promise<unknown>[];
};

/**
 * Answers `sent` as the Worker does, with Apple's revoke endpoint faked and R2 reached through
 * `bucket`; what the Worker keeps alive past the request is awaited before this answers, unless
 * `kept` takes it.
 */
async function serveWith(sent: Request, server: Server = {}): Promise<Response> {
  const kept: Promise<unknown>[] = [];
  const answer = await serve(sent, await signInWith(server), {
    bucket: server.bucket ?? env.PHOTOS,
    keepAlive: (work) =>
      server.kept === undefined
        ? kept.push(work)
        : server.kept.push(
            work.then(
              () => undefined,
              (error: unknown) => error,
            ),
          ),
  });
  await Promise.all(kept);
  return answer;
}

/** What the Worker reaches Apple and Turso through, as `server` has them. */
async function signInWith(server: Server): Promise<SignIn> {
  const signed: SignIn = signInOf(
    { ...env, APPLE_SIGN_IN_KEY: clientKeyPem },
    (server.apple ?? fakeApple()).send,
    await caches.open(crypto.randomUUID()),
  );
  return { ...signed, store: server.store?.(signed.store) ?? signed.store };
}

function request(method: string, path: string, token: string, body?: Uint8Array): Request {
  const headers = new Headers({ Authorization: `Bearer ${token}` });
  if (body !== undefined) {
    headers.set("Content-Type", "application/octet-stream");
    headers.set("Content-Length", String(body.byteLength));
  }
  return new Request(`https://mai.test${path}`, { method, headers, body: body ?? null });
}

function deleteAccount(token: string, server?: Server): Promise<Response> {
  return serveWith(request("DELETE", "/account", token), server);
}

/** `env.PHOTOS` with `name` replaced. */
function bucketWith<K extends keyof R2Bucket>(name: K, replacement: R2Bucket[K]): R2Bucket {
  return new Proxy(env.PHOTOS, {
    get(target, key, receiver) {
      if (key === name) return replacement;
      const value: unknown = Reflect.get(target, key, receiver);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

function tursoFailing(store: Store): Store {
  return storeWith(store, "deleteAccount", () => Promise.reject(new Error("Turso is unavailable")));
}

/** `store` with `name` replaced. */
function storeWith<K extends keyof Store>(
  store: Store,
  name: K,
  replacement: NoInfer<Store[K]>,
): Store {
  return new Proxy(store, {
    get(target, key, receiver) {
      if (key === name) return replacement;
      const value: unknown = Reflect.get(target, key, receiver);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

/**
 * An account with a row in every table that holds an account's rows, and photos in R2: a second
 * session, a writing, a photo and its thumbnail, the day's usage, its subscription, an agent, its
 * read mode, an exclusion, and a copy of the writing for the agent. Its Apple
 * refresh token is sealed as `POST /account` seals it.
 */
async function fullAccount(product?: string) {
  const made = await newAccount(product);
  const refreshToken = `refresh-${crypto.randomUUID()}`;
  await database.execute({
    sql: "UPDATE accounts SET apple_refresh_token = ? WHERE id = ?",
    args: [
      await new RefreshTokens(env.REFRESH_TOKEN_KEY).seal(refreshToken, made.account),
      made.account,
    ],
  });
  const second = await newSessionToken();
  await database.execute({
    sql: `INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
          VALUES (?, ?, ?, ?, ?)`,
    args: [second.caller.session, made.account, second.caller.secretSha256, Date.now(), Date.now()],
  });
  const writing = crypto.randomUUID();
  const agent = crypto.randomUUID();
  await database.batch([
    {
      sql: `INSERT INTO writings (account_id, id, revision, updated, size, envelope)
            VALUES (?, ?, 'r', 0, 3, X'010203')`,
      args: [made.account, writing],
    },
    {
      sql: `INSERT INTO agents (id, account_id, public_key, signature, token_sha256, created)
            VALUES (?, ?, X'01', X'02', X'03', 0)`,
      args: [agent, made.account],
    },
    {
      // Far ahead, so that no test's sweep reaches it while the account is paid for.
      sql: "INSERT INTO read_modes (account_id, until) VALUES (?, ?)",
      args: [made.account, Date.now() + 10 * 365 * 24 * 60 * 60 * 1000],
    },
    {
      sql: "INSERT INTO exclusions (account_id, writing_id) VALUES (?, ?)",
      args: [made.account, crypto.randomUUID()],
    },
    {
      sql: `INSERT INTO copies (account_id, writing_id, agent_id, revision, wrapped, expires)
            SELECT account_id, ?, ?, 'r', X'04', until FROM read_modes WHERE account_id = ?`,
      args: [writing, agent, made.account],
    },
  ]);
  const photo = crypto.randomUUID();
  const put = (path: string) =>
    serveWith(request("PUT", path, made.token, new Uint8Array(20).fill(7)));
  expect((await put(`/photos/${photo}`)).status).toBe(201);
  expect((await put(`/photos/${photo}/thumbnail`)).status).toBe(201);
  return { ...made, refreshToken, secondToken: second.token, photo };
}

/** How many rows of the account each table holds, `accounts` included. */
async function rowsOf(account: string): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  for (const table of ["accounts", ...accountTables]) {
    const column = table === "accounts" ? "id" : "account_id";
    const { rows } = await database.execute({
      sql: `SELECT count(*) AS count FROM ${table} WHERE ${column} = ?`,
      args: [account],
    });
    counts[table] = Number(rows[0]?.["count"]);
  }
  return counts;
}

const everyRow = {
  accounts: 1,
  writings: 1,
  photos: 2,
  usage: 1,
  subscriptions: 1,
  copies: 1,
  read_modes: 1,
  exclusions: 1,
  agents: 1,
  sessions: 2,
};
/** A lapsed account's rows: its read mode and copies are swept once it lapses. */
const lapsedRows = { ...everyRow, copies: 0, read_modes: 0 };
const noRow = Object.fromEntries(Object.keys(everyRow).map((table) => [table, 0]));

/** Every key R2 holds under `<account>/`, over as many pages as it lists them in. */
async function keysOf(account: string): Promise<string[]> {
  const keys: string[] = [];
  let listed: R2Objects | undefined;
  do {
    const after: R2ListOptions = listed?.truncated === true ? { cursor: listed.cursor } : {};
    listed = await env.PHOTOS.list({ prefix: `${account}/`, ...after });
    keys.push(...listed.objects.map((object) => object.key));
  } while (listed.truncated);
  return keys;
}

async function sessionWorks(token: string): Promise<boolean> {
  const answer = await serveWith(request("GET", "/account", token));
  expect([200, 401]).toContain(answer.status);
  return answer.status === 200;
}

describe("deleting an account", () => {
  it("revokes its Apple token and deletes every row and object of it, and nothing else", async () => {
    const apple = fakeApple();
    const one = await fullAccount();
    const other = await fullAccount();
    expect(await rowsOf(one.account)).toEqual(everyRow);
    expect(await keysOf(one.account)).toHaveLength(2);

    expect((await deleteAccount(one.token, { apple })).status).toBe(204);

    expect(apple.revoked).toEqual([one.refreshToken]);
    expect(await rowsOf(one.account)).toEqual(noRow);
    expect(await keysOf(one.account)).toEqual([]);
    expect(await rowsOf(other.account)).toEqual(everyRow);
    expect(await keysOf(other.account)).toHaveLength(2);
    expect(await sessionWorks(other.token)).toBe(true);
  });

  it("ends every session of the account", async () => {
    const one = await fullAccount();
    await deleteAccount(one.token);
    expect(await sessionWorks(one.token)).toBe(false);
    expect(await sessionWorks(one.secondToken)).toBe(false);
    expect((await deleteAccount(one.token)).status).toBe(401);
  });

  it("empties R2 of more objects than it lists at once before the rows go", async () => {
    const { account, token } = await fullAccount();
    await Promise.all(
      Array.from({ length: 1100 }, (_, index) => env.PHOTOS.put(`${account}/extra/${index}`, "x")),
    );
    let leftBeforeRows: number | undefined;
    const answer = await deleteAccount(token, {
      store: (store) =>
        storeWith(store, "deleteAccount", async (...args) => {
          leftBeforeRows = (await env.PHOTOS.list({ prefix: `${account}/` })).objects.length;
          return store.deleteAccount(...args);
        }),
    });
    expect(answer.status).toBe(204);
    expect(leftBeforeRows).toBe(0);
    expect(await keysOf(account)).toEqual([]);
  });

  it("deletes nothing for a token with the session's ID and another secret, or an expired one", async () => {
    const one = await fullAccount();
    const [, session] = one.token.split(".");
    const forged = `s1.${session}.${"A".repeat(43)}`;
    expect((await deleteAccount(forged)).status).toBe(401);

    const old = await fullAccount();
    await database.execute({
      sql: "UPDATE sessions SET last_used = ? WHERE account_id = ?",
      args: [Date.now() - 181 * 24 * 60 * 60 * 1000, old.account],
    });
    expect((await deleteAccount(old.token)).status).toBe(401);

    expect(await rowsOf(one.account)).toEqual(everyRow);
    // Another test's sweep may have deleted the ended sessions.
    expect(await rowsOf(old.account)).toEqual({ ...everyRow, sessions: expect.any(Number) });
    for (const account of [one, old]) {
      expect(await keysOf(account.account)).toHaveLength(2);
    }
  });

  it("leaves the photos of an account made again with the same ID before R2 is swept again", async () => {
    const one = await fullAccount();
    // The second sweep's list waits until the account is made again.
    let lists = 0;
    const madeAgain = Promise.withResolvers<void>();
    const bucket = bucketWith("list", async (options?: R2ListOptions) => {
      lists += 1;
      if (lists === 2) await madeAgain.promise;
      return env.PHOTOS.list(options);
    });
    const kept: Promise<unknown>[] = [];
    expect((await deleteAccount(one.token, { bucket, kept })).status).toBe(204);

    // The purchase's appAccountToken makes the account again with the same ID.
    const again = await newAccount(undefined, Date.now(), undefined, one.account);
    const photo = crypto.randomUUID();
    const put = request("PUT", `/photos/${photo}`, again.token, new Uint8Array(20).fill(7));
    expect((await serveWith(put)).status).toBe(201);
    // More held photos than R2 lists at once, and an old upload's bytes past them, on page two.
    const held = Array.from({ length: 1000 }, () => crypto.randomUUID());
    await database.execute({
      sql: `INSERT INTO photos (account_id, id, part, upload, size, state, reserved)
            SELECT ?, value, 'photo', value, 1, 'stored', 0 FROM json_each(?)`,
      args: [one.account, JSON.stringify(held)],
    });
    const heldKeys = held.map((upload) => `${one.account}/held/photo/${upload}`);
    await Promise.all(heldKeys.map((key) => env.PHOTOS.put(key, "x")));
    const oldUpload = `${one.account}/zz-old/photo/upload`;
    await env.PHOTOS.put(oldUpload, "x");

    madeAgain.resolve();
    expect(await Promise.all(kept)).toEqual([undefined]);
    expect(lists).toBe(3);
    expect((await serveWith(request("GET", `/photos/${photo}`, again.token))).status).toBe(200);
    const left = new Set(await keysOf(one.account));
    expect(left.has(oldUpload)).toBe(false);
    expect(heldKeys.every((key) => left.has(key))).toBe(true);
  });

  it("deletes a lapsed account, and one past its day's requests", async () => {
    const lapsed = await fullAccount();
    await database.execute({
      sql: "UPDATE accounts SET paid_until = ? WHERE id = ?",
      args: [Date.now() - month, lapsed.account],
    });
    const write = request("PUT", `/photos/${crypto.randomUUID()}`, lapsed.token, new Uint8Array(1));
    expect((await serveWith(write)).status).toBe(402);
    expect((await deleteAccount(lapsed.token)).status).toBe(204);
    expect(await rowsOf(lapsed.account)).toEqual(noRow);

    // test-daily takes 4 requests a day; making the account used 2 of them.
    const busy = await fullAccount("test-daily");
    await serveWith(request("GET", "/account", busy.token));
    await serveWith(request("GET", "/account", busy.token));
    expect((await serveWith(request("GET", "/account", busy.token))).status).toBe(429);
    expect((await deleteAccount(busy.token)).status).toBe(204);
    expect(await rowsOf(busy.account)).toEqual(noRow);
  });

  it("empties every table that holds an account's rows by account_id", async () => {
    const { rows } = await database.execute(
      `SELECT m.name FROM sqlite_master m, pragma_table_info(m.name) c
       WHERE m.type = 'table' AND c.name = 'account_id' ORDER BY m.name`,
    );
    expect(rows.map((row) => row["name"])).toEqual(accountTables.toSorted());
  });

  it("deletes the photo of a put that stored its bytes while the account was being deleted", async () => {
    const { account, token } = await fullAccount();
    const late = `${account}/late/photo/upload`;
    const answer = await deleteAccount(token, {
      store: (store) =>
        storeWith(store, "deleteAccount", async (...args) => {
          await env.PHOTOS.put(late, "x");
          return store.deleteAccount(...args);
        }),
    });
    expect(answer.status).toBe(204);
    expect(await keysOf(account)).toEqual([]);
  });
});

describe("a deletion that fails partway", () => {
  it("deletes nothing when Apple's revoke endpoint doesn't answer, and can be called again", async () => {
    const one = await fullAccount();
    for (const answer of [
      () => Promise.reject(new TypeError("network connection lost")),
      () => new Response("unavailable", { status: 503 }),
    ]) {
      const failed = await deleteAccount(one.token, { apple: fakeApple(answer) });
      expect(failed.status).toBe(502);
      expect(await rowsOf(one.account)).toEqual(everyRow);
      expect(await keysOf(one.account)).toHaveLength(2);
      expect(await sessionWorks(one.token)).toBe(true);
    }

    const apple = fakeApple();
    expect((await deleteAccount(one.token, { apple })).status).toBe(204);
    expect(apple.revoked).toEqual([one.refreshToken]);
    expect(await rowsOf(one.account)).toEqual(noRow);
  });

  it("deletes nothing when Apple refuses the Worker's own request", async () => {
    const one = await fullAccount();
    for (const error of ["invalid_client", "invalid_grant"]) {
      const apple = fakeApple(() => Response.json({ error }, { status: 400 }));
      await expect(deleteAccount(one.token, { apple })).rejects.toThrow(
        `revoke endpoint answered 400 to the Worker: ${error}`,
      );
      expect(await rowsOf(one.account)).toEqual(everyRow);
      expect(await keysOf(one.account)).toHaveLength(2);
    }
  });

  it("answers 204 when R2 fails after the rows go, the failure going to the runtime", async () => {
    const one = await fullAccount();
    const late = `${one.account}/late/photo/upload`;
    let deletes = 0;
    const bucket = bucketWith("delete", async (keys: string | string[]) => {
      deletes += 1;
      if (deletes > 1) throw new Error("R2 is unavailable");
      return env.PHOTOS.delete(keys);
    });
    const kept: Promise<unknown>[] = [];
    const answer = await deleteAccount(one.token, {
      bucket,
      kept,
      store: (store) =>
        storeWith(store, "deleteAccount", async (...args) => {
          await env.PHOTOS.put(late, "x");
          return store.deleteAccount(...args);
        }),
    });
    expect(answer.status).toBe(204);
    expect(await rowsOf(one.account)).toEqual(noRow);
    expect(await Promise.all(kept)).toEqual([new Error("R2 is unavailable")]);
    expect(await keysOf(one.account)).toEqual([late]);
  });

  it("keeps every row when R2 fails, and finishes when called again", async () => {
    const one = await fullAccount();
    const bucket = bucketWith("delete", () => Promise.reject(new Error("R2 is unavailable")));
    await expect(deleteAccount(one.token, { bucket })).rejects.toThrow(/R2 is unavailable/);
    expect(await rowsOf(one.account)).toEqual(everyRow);
    expect(await keysOf(one.account)).toHaveLength(2);
    expect(await sessionWorks(one.token)).toBe(true);

    const apple = fakeApple();
    expect((await deleteAccount(one.token, { apple })).status).toBe(204);
    expect(apple.revoked).toEqual([one.refreshToken]);
    expect(await rowsOf(one.account)).toEqual(noRow);
    expect(await keysOf(one.account)).toEqual([]);
  });

  it("keeps every row when Turso fails, with R2 emptied, and finishes when called again", async () => {
    const one = await fullAccount();
    await expect(deleteAccount(one.token, { store: tursoFailing })).rejects.toThrow(
      /Turso is unavailable/,
    );
    expect(await rowsOf(one.account)).toEqual(everyRow);
    expect(await keysOf(one.account)).toEqual([]);
    expect(await sessionWorks(one.token)).toBe(true);
    // Its photos' rows outlive their bytes until the deletion is called again.
    await expect(serveWith(request("GET", `/photos/${one.photo}`, one.token))).rejects.toThrow(
      /R2 has no such object/,
    );

    expect((await deleteAccount(one.token)).status).toBe(204);
    expect(await rowsOf(one.account)).toEqual(noRow);
  });

  it("deletes no row when the session ends before the rows go", async () => {
    const one = await fullAccount();
    const answer = await deleteAccount(one.token, {
      store: (store) =>
        storeWith(store, "deleteAccount", async (caller, account, now) => {
          await store.endSession(caller, now);
          return store.deleteAccount(caller, account, now);
        }),
    });
    expect(answer.status).toBe(401);
    expect(await rowsOf(one.account)).toMatchObject({ ...everyRow, sessions: 1 });
    expect((await deleteAccount(one.secondToken)).status).toBe(204);
    expect(await rowsOf(one.account)).toEqual(noRow);
  });
});

/**
 * When the next lapse test's accounts lapse: a year before the last test's, so that its runs never
 * reach an earlier test's accounts, and decades before any account another test file makes, so
 * that they reach none of those either.
 */
let lapse = Date.UTC(2001, 0, 1);

function nextLapse(): number {
  lapse -= 365 * day;
  return lapse;
}

/**
 * `fullAccount`, with its subscription, and so the account, paid until `at`, and without the read
 * mode and copies a sweep deletes once it lapses.
 */
async function lapsedAccount(at: number) {
  const made = await fullAccount();
  await database.batch(
    [
      { sql: "DELETE FROM read_modes WHERE account_id = ?", args: [made.account] },
      { sql: "DELETE FROM copies WHERE account_id = ?", args: [made.account] },
      {
        sql: `UPDATE subscriptions SET period_ends = ?, paid_until = ?, signed_date = ?
              WHERE account_id = ?`,
        args: [at, at, at - month, made.account],
      },
      { sql: "UPDATE accounts SET paid_until = ? WHERE id = ?", args: [at, made.account] },
    ],
    "write",
  );
  return made;
}

async function paidUntilOf(account: string): Promise<number> {
  const { rows } = await database.execute({
    sql: "SELECT paid_until FROM accounts WHERE id = ?",
    args: [account],
  });
  return Number(rows[0]?.["paid_until"]);
}

/** A renewal of the account's subscription signed at `signed`, paying for a month from then. */
function renewal(made: { account: string; original: string }, signed: number): Purchase {
  return {
    originalTransactionId: made.original,
    account: parseAccountId(made.account),
    productId: products.basic,
    periodEnds: signed + month,
    paidUntil: signed + month,
    revoked: false,
    environment: "Production",
    signedDate: signed,
  };
}

/**
 * Deletes lapsed accounts as the cron trigger does at `now`, with Apple, R2 and Turso as `server`
 * has them, and waits for what it keeps alive.
 */
async function deleteLapsed(now: number, server: Server = {}): Promise<void> {
  const kept: Promise<unknown>[] = [];
  await deleteLapsedAccounts(
    await signInWith(server),
    { bucket: server.bucket ?? env.PHOTOS, keepAlive: (work) => kept.push(work) },
    now,
  );
  await Promise.all(kept);
}

describe("the cron trigger, for lapsed accounts", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  // First in the block, before its other tests leave lapsed accounts behind for the run to pick.
  it("is what the Worker's cron trigger runs, with Apple reached through fetch", async () => {
    const one = await lapsedAccount(Date.now() - lapsedKept - day);
    const revoked: string[] = [];
    const real = globalThis.fetch;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      if (input !== appleRevokeUrl) {
        return real(input, init);
      }
      const form = init?.body;
      if (form instanceof URLSearchParams) revoked.push(form.get("token") ?? "");
      return new Response(null, { status: 200 });
    });
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    await runCron({ APPLE_SIGN_IN_KEY: clientKeyPem });

    expect(revoked).toContain(one.refreshToken);
    expect(await rowsOf(one.account)).toEqual(noRow);
    expect(await keysOf(one.account)).toEqual([]);
  });

  it("deletes an account lapsed 90 days ago, as DELETE /account does, and not one lapsed 89", async () => {
    const at = nextLapse();
    const old = await lapsedAccount(at);
    const recent = await lapsedAccount(at + day);
    const apple = fakeApple();

    await deleteLapsed(at + lapsedKept, { apple });

    expect(apple.revoked).toEqual([old.refreshToken]);
    expect(await rowsOf(old.account)).toEqual(noRow);
    expect(await keysOf(old.account)).toEqual([]);
    expect(await rowsOf(recent.account)).toEqual(lapsedRows);
    expect(await keysOf(recent.account)).toHaveLength(2);
  });

  it("keeps an account resubscribed within the 90 days, until it lapses again", async () => {
    const at = nextLapse();
    const one = await lapsedAccount(at);
    const back = at + 60 * day;
    await testStore.keepNotified(renewal(one, back));
    expect(await paidUntilOf(one.account)).toBe(back + month);

    const apple = fakeApple();
    await deleteLapsed(at + lapsedKept, { apple });
    expect(apple.revoked).toEqual([]);
    expect(await rowsOf(one.account)).toEqual(lapsedRows);
    expect(await keysOf(one.account)).toHaveLength(2);

    await deleteLapsed(back + month + lapsedKept, { apple });
    expect(apple.revoked).toEqual([one.refreshToken]);
    expect(await rowsOf(one.account)).toEqual(noRow);
  });

  it("keeps an account resubscribed after it was read, before anything of it is deleted", async () => {
    const at = nextLapse();
    const one = await lapsedAccount(at);
    await deleteLapsed(at + lapsedKept, {
      store: (reached) =>
        storeWith(reached, "markForDeletion", async (account, now) => {
          await reached.keepNotified(renewal(one, at + lapsedKept));
          return reached.markForDeletion(account, now);
        }),
    });
    expect(await rowsOf(one.account)).toEqual(lapsedRows);
    expect(await keysOf(one.account)).toHaveLength(2);
  });

  it("deletes an account resubscribed once its deletion started", async () => {
    const at = nextLapse();
    const one = await lapsedAccount(at);
    await deleteLapsed(at + lapsedKept, {
      store: (reached) =>
        storeWith(reached, "markForDeletion", async (account, now) => {
          const marked = await reached.markForDeletion(account, now);
          await reached.keepNotified(renewal(one, at + lapsedKept));
          return marked;
        }),
    });
    expect(await rowsOf(one.account)).toEqual(noRow);
    expect(await keysOf(one.account)).toEqual([]);
  });

  it(`deletes at most ${lapsedDeletedAtOnce} accounts a run`, async () => {
    const at = nextLapse();
    const made = [];
    for (let index = 0; index <= lapsedDeletedAtOnce; index += 1) {
      made.push(await lapsedAccount(at - index));
    }
    const apple = fakeApple();

    await deleteLapsed(at + lapsedKept, { apple });
    expect(apple.revoked).toHaveLength(lapsedDeletedAtOnce);
    const left = [];
    for (const one of made) {
      if ((await rowsOf(one.account)).accounts === 1) left.push(one);
    }
    expect(left).toHaveLength(1);
    expect(apple.revoked).not.toContain(left[0]?.refreshToken);

    await deleteLapsed(at + lapsedKept, { apple });
    expect(await rowsOf(left[0]?.account ?? "")).toEqual(noRow);
  });

  it(`reaches other accounts while ${lapsedDeletedAtOnce} fail every run`, async () => {
    const at = nextLapse();
    for (let index = 0; index < lapsedDeletedAtOnce; index += 1) {
      const failing = await lapsedAccount(at - index);
      await database.execute({
        sql: "UPDATE accounts SET apple_refresh_token = ? WHERE id = ?",
        args: [new Uint8Array(40), failing.account],
      });
    }
    const fine = await lapsedAccount(at);
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    for (let run = 0; run < 20 && (await rowsOf(fine.account)).accounts === 1; run += 1) {
      await deleteLapsed(at + lapsedKept);
    }
    expect(await rowsOf(fine.account)).toEqual(noRow);
  });

  it("keeps an account a late renewal shows lapsed under 90 days when it is marked", async () => {
    const at = nextLapse();
    const one = await lapsedAccount(at);
    await deleteLapsed(at + lapsedKept, {
      store: (reached) =>
        storeWith(reached, "markForDeletion", async (account, now) => {
          // Signed a day after the lapse, so paid until 59 days before the run.
          await reached.keepNotified(renewal(one, at + day));
          return reached.markForDeletion(account, now);
        }),
    });
    expect(await paidUntilOf(one.account)).toBe(at + day + month);
    expect(await rowsOf(one.account)).toEqual(lapsedRows);
  });

  it("sweeps R2 again for a put that landed while the rows went, whatever rows the account had", async () => {
    const at = nextLapse();
    const one = await lapsedAccount(at);
    await database.execute({
      sql: "DELETE FROM writings WHERE account_id = ?",
      args: [one.account],
    });
    const late = `${one.account}/late/photo/upload`;
    await deleteLapsed(at + lapsedKept, {
      store: (reached) =>
        storeWith(reached, "deleteLapsedAccount", async (account) => {
          await env.PHOTOS.put(late, "x");
          return reached.deleteLapsedAccount(account);
        }),
    });
    expect(await rowsOf(one.account)).toEqual(noRow);
    expect(await keysOf(one.account)).toEqual([]);
  });

  it("goes on with the other accounts when one fails, and finishes it in a later run", async () => {
    const at = nextLapse();
    const sealedWrong = await lapsedAccount(at);
    const r2Fails = await lapsedAccount(at + 1);
    const fine = await lapsedAccount(at + 2);
    await database.execute({
      sql: "UPDATE accounts SET apple_refresh_token = ? WHERE id = ?",
      args: [new Uint8Array(40), sealedWrong.account],
    });
    const bucket = bucketWith("delete", async (keys: string | string[]) => {
      if ([keys].flat().some((key) => key.startsWith(`${r2Fails.account}/`))) {
        throw new Error("R2 is unavailable");
      }
      return env.PHOTOS.delete(keys);
    });
    const logged = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await deleteLapsed(at + lapsedKept + 2, { bucket });

    expect(await rowsOf(fine.account)).toEqual(noRow);
    expect(await keysOf(fine.account)).toEqual([]);
    expect(await rowsOf(sealedWrong.account)).toEqual(lapsedRows);
    expect(await keysOf(sealedWrong.account)).toHaveLength(2);
    expect(await rowsOf(r2Fails.account)).toEqual(lapsedRows);
    expect(await keysOf(r2Fails.account)).toHaveLength(2);
    expect(logged.mock.calls.map(([message]) => String(message)).toSorted()).toEqual(
      [
        `deleting the lapsed account ${sealedWrong.account} failed; the next run tries again`,
        `deleting the lapsed account ${r2Fails.account} failed; the next run tries again`,
      ].toSorted(),
    );

    // Marked before R2 failed, so a resubscription now comes too late.
    await testStore.keepNotified(renewal(r2Fails, at + lapsedKept));
    await database.execute({
      sql: "UPDATE accounts SET apple_refresh_token = ? WHERE id = ?",
      args: [
        await new RefreshTokens(env.REFRESH_TOKEN_KEY).seal(
          sealedWrong.refreshToken,
          sealedWrong.account,
        ),
        sealedWrong.account,
      ],
    });
    await deleteLapsed(at + lapsedKept + 2);
    expect(await rowsOf(sealedWrong.account)).toEqual(noRow);
    expect(await rowsOf(r2Fails.account)).toEqual(noRow);
    expect(await keysOf(r2Fails.account)).toEqual([]);
  });

  it("deletes nothing of an account whose Apple token wasn't revoked, and tries it again", async () => {
    const at = nextLapse();
    const one = await lapsedAccount(at);
    const warned = vi.spyOn(console, "warn").mockImplementation(() => undefined);

    await deleteLapsed(at + lapsedKept, {
      apple: fakeApple(() => new Response("unavailable", { status: 503 })),
    });
    expect(await rowsOf(one.account)).toEqual(lapsedRows);
    expect(await keysOf(one.account)).toHaveLength(2);
    expect(warned).toHaveBeenCalledTimes(1);

    // Not marked, so a resubscription still keeps it.
    await testStore.keepNotified(renewal(one, at + lapsedKept));
    await deleteLapsed(at + lapsedKept);
    expect(await rowsOf(one.account)).toEqual(lapsedRows);
  });
});
