import { env } from "cloudflare:test";
import { createClient } from "@libsql/client/web";
import { beforeAll, describe, expect, it } from "vitest";
import { appleIssuer } from "../src/apple-sign-in";
import { appleRevokeUrl } from "../src/apple-tokens";
import { serve, signInOf } from "../src/index";
import { readCompactJws } from "../src/jws";
import { RefreshTokens } from "../src/refresh-tokens";
import { newSessionToken } from "../src/sessions";
import type { SignIn } from "../src/sign-in";
import { accountTables, type Store } from "../src/store";
import { newAccount } from "./accounts";

const database = createClient({ url: env.TURSO_URL });
const month = 30 * 24 * 60 * 60 * 1000;

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
  const signed: SignIn = signInOf(
    { ...env, APPLE_SIGN_IN_KEY: clientKeyPem },
    (server.apple ?? fakeApple()).send,
    await caches.open(crypto.randomUUID()),
  );
  const signIn = { ...signed, store: server.store?.(signed.store) ?? signed.store };
  const kept: Promise<unknown>[] = [];
  const answer = await serve(sent, signIn, {
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
  return storeWith(store, () => Promise.reject(new Error("Turso is unavailable")));
}

/** `store` with `deleteAccount` replaced. */
function storeWith(store: Store, replacement: Store["deleteAccount"]): Store {
  return new Proxy(store, {
    get(target, key, receiver) {
      if (key === "deleteAccount") return replacement;
      const value: unknown = Reflect.get(target, key, receiver);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

/**
 * An account with a row in every table that holds an account's rows, and photos in R2: a second
 * session, a writing, a photo and its thumbnail, the day's usage and its subscription. Its Apple
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
  await database.execute({
    sql: `INSERT INTO writings (account_id, id, revision, updated, size, envelope)
          VALUES (?, ?, 'r', 0, 3, X'010203')`,
    args: [made.account, crypto.randomUUID()],
  });
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
  sessions: 2,
};
const noRow = { accounts: 0, writings: 0, photos: 0, usage: 0, subscriptions: 0, sessions: 0 };

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
        storeWith(store, async (...args) => {
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

    for (const account of [one, old]) {
      expect(await rowsOf(account.account)).toEqual(everyRow);
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
    await database.batch(
      held.map((upload) => ({
        sql: `INSERT INTO photos (account_id, id, part, upload, size, state, reserved)
              VALUES (?, ?, 'photo', ?, 1, 'stored', 0)`,
        args: [one.account, crypto.randomUUID(), upload],
      })),
      "write",
    );
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
        storeWith(store, async (...args) => {
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
        storeWith(store, async (...args) => {
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
        storeWith(store, async (caller, account, now) => {
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
