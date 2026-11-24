import { env } from "cloudflare:test";
import { createClient } from "@libsql/client/web";
import { describe, expect, it } from "vitest";
import { hex } from "../src/hex";
import { serve, signInOf } from "../src/index";
import { newSessionToken } from "../src/sessions";
import { newAccount } from "./accounts";

const database = createClient({ url: env.TURSO_URL });
const day = 24 * 60 * 60 * 1000;

const check = new Uint8Array(32).fill(0xab);

/**
 * Answers `path` as the Worker does at `now`, with `token`, Apple never reached, and what it keeps
 * alive past the request awaited.
 */
async function call(
  path: string,
  token: string,
  {
    method = "GET",
    headers = {},
    body,
  }: { method?: string; headers?: Record<string, string>; body?: Uint8Array<ArrayBuffer> } = {},
  now = Date.now(),
): Promise<Response> {
  const kept: Promise<unknown>[] = [];
  const request = new Request(`https://mai.test${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, ...headers },
    body: body ?? null,
  });
  const signIn = signInOf(
    env,
    () => Promise.reject(new Error("starting over doesn't reach Apple")),
    await caches.open(crypto.randomUUID()),
  );
  const answer = await serve(
    request,
    signIn,
    { bucket: env.PHOTOS, keepAlive: (work) => kept.push(work) },
    now,
  );
  await Promise.all(kept);
  return answer;
}

/** `sent` null sends no `Mai-Own-Key-Check`. */
function startOver(token: string, sent: string | null = hex(check), now = Date.now()) {
  return call(
    "/account/own-key-check",
    token,
    { method: "DELETE", headers: sent === null ? {} : { "Mai-Own-Key-Check": sent } },
    now,
  );
}

/** A sealed writing of 128 bytes, laid out as `Server/README.md` says, with the ID `id`. */
function envelope(id: string): Uint8Array<ArrayBuffer> {
  const bytes = new Uint8Array(4 + 16 + 8 + 60 + 12 + 12 + 16);
  bytes.set([0x6d, 0x61, 0x69, 0x01], 0);
  bytes.set(
    id
      .replaceAll("-", "")
      .match(/../g)
      ?.map((pair) => parseInt(pair, 16)) ?? [],
    4,
  );
  new DataView(bytes.buffer).setBigUint64(20, 1_790_000_000_123n);
  return bytes;
}

/**
 * A new account whose own key check is `check`, holding a writing, a photo with its thumbnail, and
 * a read mode copy, with a second session beside its own.
 */
async function filledAccount(now = Date.now()) {
  const made = await newAccount(undefined, now);
  const kept = await call("/account/own-key-check", made.token, {
    method: "PUT",
    headers: { "Content-Type": "application/octet-stream" },
    body: check,
  });
  expect(kept.status).toBe(204);
  const writing = crypto.randomUUID();
  const saved = await call(`/writings/${writing}`, made.token, {
    method: "PUT",
    headers: { "Content-Type": "application/octet-stream", "Mai-Base-Revision": "none" },
    body: envelope(writing),
  });
  expect(saved.status).toBe(200);
  const photo = crypto.randomUUID();
  for (const part of ["", "/thumbnail"]) {
    const put = await call(`/photos/${photo}${part}`, made.token, {
      method: "PUT",
      headers: { "Content-Type": "application/octet-stream", "Content-Length": "16" },
      body: new Uint8Array(16).fill(1),
    });
    expect(put.status).toBe(201);
  }
  await database.execute({
    sql: `INSERT INTO copies (account_id, writing_id, agent_id, revision, wrapped, expires)
          VALUES (?, ?, ?, 'r', x'01', ?)`,
    args: [made.account, writing, crypto.randomUUID(), now + day],
  });
  const other = await newSessionToken();
  await database.execute({
    sql: `INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
          VALUES (?, ?, ?, ?, ?)`,
    args: [other.caller.session, made.account, other.caller.secretSha256, now, now],
  });
  return { ...made, writing, photo, otherToken: other.token };
}

async function countOf(table: string, account: string): Promise<number> {
  const { rows } = await database.execute({
    sql: `SELECT count(*) AS n FROM ${table} WHERE account_id = ?`,
    args: [account],
  });
  return Number(rows[0]?.["n"]);
}

async function keysOf(account: string): Promise<string[]> {
  return (await env.PHOTOS.list({ prefix: `${account}/` })).objects.map((object) => object.key);
}

type Read = {
  ownKeyCheck: string | null;
  usage: Record<string, { used: number }>;
  lapsed: boolean;
};

async function readAccount(token: string): Promise<Read> {
  const answer = await call("/account", token);
  expect(answer.status).toBe(200);
  return answer.json<Read>();
}

describe("DELETE /account/own-key-check", () => {
  it("deletes what the own key sealed, drops the check, and ends the account's other sessions", async () => {
    const account = await filledAccount();
    expect(await keysOf(account.account)).toHaveLength(2);

    expect((await startOver(account.token)).status).toBe(204);

    const read = await readAccount(account.token);
    expect(read.ownKeyCheck).toBeNull();
    expect(read.lapsed).toBe(false);
    expect(read.usage["writings"]?.used).toBe(0);
    expect(read.usage["writingsBytes"]?.used).toBe(0);
    expect(read.usage["photosBytes"]?.used).toBe(0);
    for (const table of ["writings", "photos", "copies"]) {
      expect(await countOf(table, account.account)).toBe(0);
    }
    expect(await keysOf(account.account)).toEqual([]);
    expect(await countOf("subscriptions", account.account)).toBe(1);
    expect((await call("/writings", account.otherToken)).status).toBe(401);
    const listed = await call("/writings", account.token);
    expect(await listed.json()).toEqual({ writings: [] });
  });

  it("lets the account put a new own key check and write again", async () => {
    const account = await filledAccount();
    expect((await startOver(account.token)).status).toBe(204);
    const another = new Uint8Array(32).fill(9);
    const kept = await call("/account/own-key-check", account.token, {
      method: "PUT",
      headers: { "Content-Type": "application/octet-stream" },
      body: another,
    });
    expect(kept.status).toBe(204);
    expect((await readAccount(account.token)).ownKeyCheck).toBe(hex(another));
    const saved = await call(`/writings/${account.writing}`, account.token, {
      method: "PUT",
      headers: { "Content-Type": "application/octet-stream", "Mai-Base-Revision": "none" },
      body: envelope(account.writing),
    });
    expect(saved.status).toBe(200);
  });

  it("changes nothing, answering 409, when the check sent isn't the account's", async () => {
    const account = await filledAccount();
    const answer = await startOver(account.token, hex(new Uint8Array(32).fill(8)));
    expect(answer.status).toBe(409);
    expect((await readAccount(account.token)).ownKeyCheck).toBe(hex(check));
    for (const table of ["writings", "photos", "copies"]) {
      expect(await countOf(table, account.account)).toBeGreaterThan(0);
    }
    expect(await keysOf(account.account)).toHaveLength(2);
    expect((await call("/writings", account.otherToken)).status).toBe(200);
  });

  it("answers 409 when sent again, keeping what was written since", async () => {
    const account = await filledAccount();
    expect((await startOver(account.token)).status).toBe(204);
    const saved = await call(`/writings/${account.writing}`, account.token, {
      method: "PUT",
      headers: { "Content-Type": "application/octet-stream", "Mai-Base-Revision": "none" },
      body: envelope(account.writing),
    });
    expect(saved.status).toBe(200);
    expect((await startOver(account.token)).status).toBe(409);
    expect(await countOf("writings", account.account)).toBe(1);
  });

  it("answers 409 for an account with no own key check", async () => {
    const { token } = await newAccount();
    expect((await startOver(token)).status).toBe(409);
  });

  it("leaves other accounts as they are", async () => {
    const account = await filledAccount();
    const other = await filledAccount();
    expect((await startOver(account.token)).status).toBe(204);
    expect(await countOf("writings", other.account)).toBe(1);
    expect(await keysOf(other.account)).toHaveLength(2);
    expect((await call("/writings", other.otherToken)).status).toBe(200);
  });

  it("starts a lapsed account over too", async () => {
    const now = Date.now();
    const account = await filledAccount(now);
    const later = now + 31 * day;
    expect((await startOver(account.token, hex(check), later)).status).toBe(204);
    expect(await countOf("writings", account.account)).toBe(0);
  });

  it.each([
    ["no header", null],
    ["uppercase hex", hex(check).toUpperCase()],
    ["31 bytes", hex(check.slice(1))],
    ["not hex", "z".repeat(64)],
  ])("refuses %s with 400 and changes nothing", async (_, sent) => {
    const account = await filledAccount();
    expect((await startOver(account.token, sent)).status).toBe(400);
    expect((await readAccount(account.token)).ownKeyCheck).toBe(hex(check));
  });

  it("needs a live session", async () => {
    const { token } = await newSessionToken();
    expect((await startOver(token)).status).toBe(401);
  });
});
