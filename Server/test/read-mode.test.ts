import { env } from "cloudflare:test";
import { createClient } from "@libsql/client/web";
import { beforeEach, describe, expect, it } from "vitest";
import type { AccountId } from "../src/account-id";
import { newAccount, runCron, store } from "./accounts";
import { callAt, type Sent } from "./calls";
import { sealedWriting } from "./envelopes";

const database = createClient({ url: env.TURSO_URL });
const minute = 60 * 1000;

/** The time each request is sent at: now when a test starts, moved on by `wait`. */
let now: number;

beforeEach(() => {
  now = Date.now();
});

function wait(by: number): void {
  now += by;
}

function call(path: string, { token, ...sent }: Sent & { token: string }): Promise<Response> {
  return callAt(now, path, token, sent);
}

/**
 * The read-mode part of the cron trigger's sweep, as of `now`. Only that part: `now` may be ahead
 * of the other tests' time, and the rest of the sweep reaches every account.
 */
function sweep(account: AccountId): Promise<void> {
  return store.sweepReadMode(now, [account]);
}

async function json<T>(response: Response | Promise<Response>): Promise<T> {
  return (await response).json<T>();
}

/** Saves `writing` over `base`, as a device does, and answers its new revision. */
async function save(token: string, writing: string, base = "none", updated = 1n): Promise<string> {
  const saved = await call(`/writings/${writing}`, {
    method: "PUT",
    token,
    body: sealedWriting({ writing, updated: 1_790_000_000_000n + updated }),
    base,
  });
  expect(saved.status).toBe(200);
  return (await json<{ revision: string }>(saved)).revision;
}

/** A public key of 32 bytes no other agent has, in hex. */
function newKey(): string {
  return crypto.randomUUID().replaceAll("-", "").repeat(2);
}

async function approve(
  token: string,
  publicKey = newKey(),
): Promise<{ agent: string; token: string; publicKey: string }> {
  const approved = await call("/agents", {
    method: "POST",
    token,
    json: { publicKey, signature: "bb".repeat(64) },
  });
  expect(approved.status).toBe(201);
  return { ...(await json<{ agent: string; token: string }>(approved)), publicKey };
}

async function turnOn(token: string, until: number): Promise<void> {
  expect((await call("/read-mode", { method: "PUT", token, json: { until } })).status).toBe(200);
}

type Kept = { writing: string; agent: string; refused: string | null };

async function sendCopy(
  token: string,
  copy: { writing: string; agent: string; revision: string },
  expires: number,
): Promise<string | null> {
  const sent = await call("/copies", {
    method: "POST",
    token,
    json: { expires, copies: [{ ...copy, wrapped: "cc".repeat(40) }] },
  });
  expect(sent.status).toBe(200);
  const [kept] = (await json<{ copies: Kept[] }>(sent)).copies;
  return kept?.refused ?? null;
}

/**
 * An account with a saved writing, an approved agent, read mode on for a minute from now, and the
 * writing's copy for the agent.
 */
async function reading() {
  const { account, token } = await newAccount();
  const writing = crypto.randomUUID();
  const revision = await save(token, writing);
  const agent = await approve(token);
  const until = now + minute;
  await turnOn(token, until);
  expect(await sendCopy(token, { writing, agent: agent.agent, revision }, until)).toBe(null);
  return { account, token, writing, revision, agent, until };
}

async function copiesOf(account: string): Promise<number> {
  const { rows } = await database.execute({
    sql: "SELECT count(*) AS count FROM copies WHERE account_id = ?",
    args: [account],
  });
  return Number(rows[0]?.["count"]);
}

async function readModesOf(account: string): Promise<number> {
  const { rows } = await database.execute({
    sql: "SELECT count(*) AS count FROM read_modes WHERE account_id = ?",
    args: [account],
  });
  return Number(rows[0]?.["count"]);
}

describe("an agent reading", () => {
  it("lists and reads the writings it has a copy of, with the key wrapped for it", async () => {
    const { token, writing, revision, agent, until } = await reading();
    expect(await json(call("/agent/writings", { token: agent.token }))).toEqual({
      writings: [{ id: writing, revision, updated: 1_790_000_000_001, size: 126, expires: until }],
    });
    const read = await call(`/agent/writings/${writing}`, { token: agent.token });
    expect(read.status).toBe(200);
    expect(read.headers.get("Mai-Revision")).toBe(revision);
    expect(read.headers.get("Mai-Wrapped-Key")).toBe("cc".repeat(40));
    expect(read.headers.get("Mai-Expires")).toBe(String(until));
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(
      sealedWriting({ writing, updated: 1_790_000_000_001n }),
    );

    const other = crypto.randomUUID();
    await save(token, other);
    expect((await call(`/agent/writings/${other}`, { token: agent.token })).status).toBe(404);
  });

  it("only reads", async () => {
    const { writing, agent } = await reading();
    for (const method of ["PUT", "DELETE", "POST"]) {
      const answer = await call(`/agent/writings/${writing}`, { method, token: agent.token });
      expect(answer.status).toBe(405);
    }
    expect((await call("/agent/account", { token: agent.token })).status).toBe(404);
  });

  it("is refused by the device's routes, and a session by the agent's", async () => {
    const { writing, token, agent } = await reading();
    for (const path of ["/writings", `/writings/${writing}`, "/account", "/agents", "/read-mode"]) {
      expect((await call(path, { token: agent.token })).status).toBe(401);
    }
    expect((await call("/agent/writings", { token })).status).toBe(401);
    expect((await call(`/agent/writings/${writing}`, { token })).status).toBe(401);
  });

  it("can't read another account's writings, nor have a copy sent for it", async () => {
    const one = await reading();
    const other = await reading();
    const read = await call(`/agent/writings/${one.writing}`, { token: other.agent.token });
    expect(read.status).toBe(404);
    expect(await json(call("/agent/writings", { token: other.agent.token }))).toMatchObject({
      writings: [{ id: other.writing }],
    });
    const forOther = { writing: one.writing, agent: other.agent.agent, revision: one.revision };
    expect(await sendCopy(one.token, forOther, one.until)).toBe("agent");
  });

  it("stops once its agent is revoked, and the copies for it go", async () => {
    const { account, token, writing, revision, agent, until } = await reading();
    expect((await call(`/agents/${agent.agent}`, { method: "DELETE", token })).status).toBe(204);
    expect(await copiesOf(account)).toBe(0);
    expect((await call(`/agent/writings/${writing}`, { token: agent.token })).status).toBe(401);
    expect((await call("/agent/writings", { token: agent.token })).status).toBe(401);
    expect(await sendCopy(token, { writing, agent: agent.agent, revision }, until)).toBe("agent");
    expect(await json(call("/agents", { token }))).toMatchObject({
      agents: [{ id: agent.agent, revoked: true }],
    });
  });

  it("isn't served a copy past its expiry, which the sweep then deletes", async () => {
    const { account, writing, agent, until } = await reading();
    wait(until - now - 1);
    expect((await call(`/agent/writings/${writing}`, { token: agent.token })).status).toBe(200);
    wait(1);
    expect((await call(`/agent/writings/${writing}`, { token: agent.token })).status).toBe(404);
    expect(await json(call("/agent/writings", { token: agent.token }))).toEqual({ writings: [] });
    expect(await copiesOf(account)).toBe(1);

    await sweep(account);
    expect(await copiesOf(account)).toBe(0);
    expect(await readModesOf(account)).toBe(0);
  });

  it("isn't served once the account lapses, and the sweep deletes its read mode and copies", async () => {
    const { account, token, writing, revision, agent, until } = await reading();
    await database.execute({
      sql: "UPDATE accounts SET paid_until = ? WHERE id = ?",
      args: [now - 1, account],
    });
    expect((await call(`/agent/writings/${writing}`, { token: agent.token })).status).toBe(404);
    const resent = await call("/copies", {
      method: "POST",
      token,
      json: { expires: until, copies: [{ writing, agent: agent.agent, revision, wrapped: "cc" }] },
    });
    expect(resent.status).toBe(402);
    expect((await call("/read-mode", { method: "PUT", token, json: { until } })).status).toBe(402);

    await sweep(account);
    expect(await copiesOf(account)).toBe(0);
    expect(await readModesOf(account)).toBe(0);
  });
});

describe("agents", () => {
  it("are approved with a token each, and listed with their keys", async () => {
    const { token } = await newAccount();
    const first = await approve(token);
    const second = await approve(token);
    expect(first.token).toMatch(new RegExp(`^agent\\.${first.agent}\\.[A-Za-z0-9_-]{43}$`));
    expect(second.agent).not.toBe(first.agent);
    expect(await json(call("/agents", { token }))).toEqual({
      agents: [first, second].map(({ agent, publicKey }) => ({
        id: agent,
        publicKey,
        signature: "bb".repeat(64),
        revoked: false,
      })),
    });
  });

  it.each([
    ["no body", undefined],
    ["no signature", { publicKey: "aa" }],
    ["a key not in hex", { publicKey: "zz", signature: "bb" }],
    ["an empty key", { publicKey: "", signature: "bb" }],
    ["a key too long", { publicKey: "aa".repeat(1025), signature: "bb" }],
  ])("are refused with %s", async (_, body) => {
    const { token } = await newAccount();
    const answer = await call("/agents", { method: "POST", token, json: body ?? null });
    expect(answer.status).toBe(400);
    expect(await json(call("/agents", { token }))).toEqual({ agents: [] });
  });

  it("are at most 10 not revoked", async () => {
    const { token } = await newAccount();
    const approved = [];
    for (let count = 0; count < 10; count += 1) {
      approved.push(await approve(token));
    }
    const eleventh = { publicKey: newKey(), signature: "bb" };
    expect((await call("/agents", { method: "POST", token, json: eleventh })).status).toBe(409);
    const [first] = approved;
    await call(`/agents/${first?.agent}`, { method: "DELETE", token });
    expect((await call("/agents", { method: "POST", token, json: eleventh })).status).toBe(201);
  });

  it("are revoked only by their own account", async () => {
    const one = await reading();
    const other = await newAccount();
    const revoke = await call(`/agents/${one.agent.agent}`, {
      method: "DELETE",
      token: other.token,
    });
    expect(revoke.status).toBe(404);
    expect((await call(`/agent/writings/${one.writing}`, { token: one.agent.token })).status).toBe(
      200,
    );
    const unknown = await call(`/agents/${crypto.randomUUID()}`, {
      method: "DELETE",
      token: one.token,
    });
    expect(unknown.status).toBe(404);
  });

  it("aren't approved twice with one key, nor again once it is revoked", async () => {
    const { token, agent } = await reading();
    const again = { publicKey: agent.publicKey, signature: "bb".repeat(64) };
    expect((await call("/agents", { method: "POST", token, json: again })).status).toBe(409);
    await call(`/agents/${agent.agent}`, { method: "DELETE", token });
    expect((await call("/agents", { method: "POST", token, json: again })).status).toBe(409);
    const other = await newAccount();
    expect(
      (await call("/agents", { method: "POST", token: other.token, json: again })).status,
    ).toBe(201);
  });
});

describe("a lapsed account", () => {
  it("changes nothing of read mode, and its agents read nothing", async () => {
    const { account, token, writing, agent } = await reading();
    await database.execute({
      sql: "UPDATE accounts SET paid_until = ? WHERE id = ?",
      args: [now - 1, account],
    });
    for (const [path, method, body] of [
      ["/agents", "POST", { publicKey: "aa", signature: "bb" }],
      [`/agents/${agent.agent}`, "DELETE", undefined],
      ["/read-mode", "PUT", { until: now + minute }],
      ["/read-mode", "DELETE", undefined],
      [`/exclusions/${writing}`, "PUT", undefined],
      [`/exclusions/${writing}`, "DELETE", undefined],
    ] as const) {
      expect((await call(path, { method, token, json: body })).status).toBe(402);
    }
    expect((await call("/agents", { token })).status).toBe(200);
    expect((await call("/agent/writings", { token: agent.token })).status).toBe(200);
    expect(await json(call("/agent/writings", { token: agent.token }))).toEqual({ writings: [] });
  });
});

describe("the cron trigger", () => {
  it("deletes copies and read modes that have ended", async () => {
    const { account } = await newAccount();
    const ended = Date.now() - 1;
    await database.batch([
      { sql: "INSERT INTO read_modes (account_id, until) VALUES (?, ?)", args: [account, ended] },
      {
        sql: `INSERT INTO copies (account_id, writing_id, agent_id, revision, wrapped, expires)
              VALUES (?, ?, ?, 'r', X'01', ?)`,
        args: [account, crypto.randomUUID(), crypto.randomUUID(), ended],
      },
    ]);
    await runCron();
    expect(await copiesOf(account)).toBe(0);
    expect(await readModesOf(account)).toBe(0);
  });
});

describe("read mode", () => {
  it("is on until its end, and off once turned off, with every copy gone", async () => {
    const { account, token, until } = await reading();
    expect(await json(call("/read-mode", { token }))).toEqual({ until });
    expect((await call("/read-mode", { method: "DELETE", token })).status).toBe(204);
    expect(await json(call("/read-mode", { token }))).toEqual({ until: null });
    expect(await copiesOf(account)).toBe(0);
  });

  it("reads as off past its end, before it is swept", async () => {
    const { token, until } = await reading();
    wait(until - now);
    expect(await json(call("/read-mode", { token }))).toEqual({ until: null });
  });

  it("is turned on for a new period with the copies of the last one gone", async () => {
    const { account, token, writing, revision, agent, until } = await reading();
    const later = until + minute;
    await turnOn(token, later);
    expect(await copiesOf(account)).toBe(0);
    expect(await sendCopy(token, { writing, agent: agent.agent, revision }, until)).toBe(
      "read-mode",
    );
    expect(await sendCopy(token, { writing, agent: agent.agent, revision }, later)).toBe(null);
  });

  it.each([
    ["an end that has passed", () => ({ until: now - 1 })],
    ["no end", () => ({})],
    ["an end that isn't a whole number", () => ({ until: now + 0.5 })],
  ])("isn't turned on with %s", async (_, body) => {
    const { token } = await newAccount();
    expect((await call("/read-mode", { method: "PUT", token, json: body() })).status).toBe(400);
    expect(await json(call("/read-mode", { token }))).toEqual({ until: null });
  });
});

describe("copies", () => {
  it("are refused while read mode is off, or for another period", async () => {
    const { token } = await newAccount();
    const writing = crypto.randomUUID();
    const revision = await save(token, writing);
    const { agent } = await approve(token);
    const until = now + minute;
    expect(await sendCopy(token, { writing, agent, revision }, until)).toBe("read-mode");
    await turnOn(token, until);
    expect(await sendCopy(token, { writing, agent, revision }, until - 1)).toBe("read-mode");
    expect(await sendCopy(token, { writing, agent, revision }, until)).toBe(null);
  });

  it("are refused past the read mode's end, before it is swept", async () => {
    const { account, token, writing, revision, agent, until } = await reading();
    await call("/read-mode", { method: "DELETE", token });
    await turnOn(token, until);
    wait(until - now);
    expect(await sendCopy(token, { writing, agent: agent.agent, revision }, until)).toBe(
      "read-mode",
    );
    expect(await copiesOf(account)).toBe(0);
  });

  it("aren't kept for an excluded writing, and go when it is excluded", async () => {
    const { account, token, writing, revision, agent, until } = await reading();
    expect((await call(`/exclusions/${writing}`, { method: "PUT", token })).status).toBe(204);
    expect(await copiesOf(account)).toBe(0);
    expect(await json(call("/exclusions", { token }))).toEqual({ exclusions: [writing] });
    expect(await sendCopy(token, { writing, agent: agent.agent, revision }, until)).toBe(
      "excluded",
    );
    expect((await call(`/agent/writings/${writing}`, { token: agent.token })).status).toBe(404);

    expect((await call(`/exclusions/${writing}`, { method: "DELETE", token })).status).toBe(204);
    expect(await json(call("/exclusions", { token }))).toEqual({ exclusions: [] });
    expect(await sendCopy(token, { writing, agent: agent.agent, revision }, until)).toBe(null);
  });

  it("are of the writing's current revision, the last one's going when it is saved", async () => {
    const { account, token, writing, revision, agent, until } = await reading();
    const next = await save(token, writing, revision, 2n);
    expect(await copiesOf(account)).toBe(0);
    expect(await sendCopy(token, { writing, agent: agent.agent, revision }, until)).toBe(
      "revision",
    );
    const unsaved = crypto.randomUUID();
    expect(await sendCopy(token, { writing: unsaved, agent: agent.agent, revision }, until)).toBe(
      "revision",
    );
    expect(await sendCopy(token, { writing, agent: agent.agent, revision: next }, until)).toBe(
      null,
    );
  });

  it("are kept one by one, each answered in the order sent", async () => {
    const { token, writing, revision, agent, until } = await reading();
    const excluded = crypto.randomUUID();
    const excludedRevision = await save(token, excluded);
    await call(`/exclusions/${excluded}`, { method: "PUT", token });
    const sent = await call("/copies", {
      method: "POST",
      token,
      json: {
        expires: until,
        copies: [
          { writing: excluded, agent: agent.agent, revision: excludedRevision, wrapped: "01" },
          { writing, agent: agent.agent, revision, wrapped: "02" },
        ],
      },
    });
    expect(await json(sent)).toEqual({
      copies: [
        { writing: excluded, agent: agent.agent, refused: "excluded" },
        { writing, agent: agent.agent, refused: null },
      ],
    });
    const read = await call(`/agent/writings/${writing}`, { token: agent.token });
    expect(read.headers.get("Mai-Wrapped-Key")).toBe("02");
  });

  it.each([
    ["no copies", (copy: object) => ({ expires: 1, copies: [copy].slice(1) })],
    [
      "101 copies",
      (copy: object) => ({ expires: 1, copies: Array.from({ length: 101 }, () => copy) }),
    ],
    ["the same writing and agent twice", (copy: object) => ({ expires: 1, copies: [copy, copy] })],
    ["no expiry", (copy: object) => ({ copies: [copy] })],
    [
      "a wrapped key too long",
      (copy: object) => ({ expires: 1, copies: [{ ...copy, wrapped: "aa".repeat(1025) }] }),
    ],
    [
      "a revision that isn't one",
      (copy: object) => ({ expires: 1, copies: [{ ...copy, revision: "r" }] }),
    ],
  ])("are refused with %s", async (_, body) => {
    const { token } = await newAccount();
    const copy = {
      writing: crypto.randomUUID(),
      agent: crypto.randomUUID(),
      revision: "a".repeat(64),
      wrapped: "aa",
    };
    expect((await call("/copies", { method: "POST", token, json: body(copy) })).status).toBe(400);
  });
});
