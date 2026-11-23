import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { createClient } from "@libsql/client/web";
import { describe, expect, it } from "vitest";
import { newAccount, products, store } from "./accounts";

const database = createClient({ url: env.TURSO_URL });
const day = 24 * 60 * 60 * 1000;

function call(path: string, token: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${token}`);
  return exports.default.fetch(new Request(`https://mai.test${path}`, { ...init, headers }));
}

function putOwnKeyCheck(token: string, check: Uint8Array<ArrayBuffer>): Promise<Response> {
  return call("/account/own-key-check", token, {
    method: "PUT",
    headers: { "Content-Type": "application/octet-stream" },
    body: check,
  });
}

async function readAccount(token: string): Promise<unknown> {
  const answer = await call("/account", token);
  expect(answer.status).toBe(200);
  return answer.json();
}

async function paidUntilOf(account: string): Promise<number> {
  const { rows } = await database.execute({
    sql: "SELECT paid_until FROM accounts WHERE id = ?",
    args: [account],
  });
  return Number(rows[0]?.["paid_until"]);
}

/** A sealed writing of 128 bytes, laid out as `Server/README.md` says. */
function envelope(): Uint8Array<ArrayBuffer> {
  const bytes = new Uint8Array(4 + 16 + 8 + 60 + 12 + 12 + 16);
  bytes.set([0x6d, 0x61, 0x69, 0x01], 0);
  bytes.set(
    Array.from({ length: 16 }, (_, index) => index + 1),
    4,
  );
  new DataView(bytes.buffer).setBigUint64(20, 1_790_000_000_123n);
  return bytes;
}

describe("GET /account", () => {
  it("answers the plan, its limits and no own key check for a new account", async () => {
    const { account, token } = await newAccount();
    expect(await readAccount(token)).toEqual({
      plan: "basic",
      paidUntil: await paidUntilOf(account),
      lapsed: false,
      usage: {
        writingsBytes: { used: 0, limit: 100_000_000 },
        writings: { used: 0, limit: 10_000 },
        requests: { used: 0, limit: 3000 },
        lists: { used: 0, limit: 200 },
        saves: { used: 0, limit: 500 },
      },
      ownKeyCheck: null,
    });
  });

  it("answers the own key check a device kept, in lowercase hex", async () => {
    const { token } = await newAccount(products.plus);
    const check = new Uint8Array(32).map((_, index) => index * 8);
    expect((await putOwnKeyCheck(token, check)).status).toBe(204);
    expect(await readAccount(token)).toMatchObject({
      plan: "plus",
      ownKeyCheck: "0008101820283038404850586068707880889098a0a8b0b8c0c8d0d8e0e8f0f8",
    });
  });

  it("answers what the account has used, before this request", async () => {
    const { token } = await newAccount();
    expect(
      (
        await call("/writings/01020304-0506-0708-090a-0b0c0d0e0f10", token, {
          method: "PUT",
          headers: { "Content-Type": "application/octet-stream", "Mai-Base-Revision": "none" },
          body: envelope(),
        })
      ).status,
    ).toBe(200);
    expect((await call("/writings", token)).status).toBe(200);
    expect(await readAccount(token)).toMatchObject({
      usage: {
        writingsBytes: { used: 128 },
        writings: { used: 1 },
        requests: { used: 2 },
        lists: { used: 1 },
        saves: { used: 1 },
      },
    });
    expect(await readAccount(token)).toMatchObject({ usage: { requests: { used: 3 } } });
  });

  it("is read by a lapsed account, which it says has lapsed", async () => {
    const { account, token } = await newAccount(products.basic, Date.now() - 60 * day);
    const paidUntil = await paidUntilOf(account);
    expect(paidUntil).toBeLessThan(Date.now());
    expect(await readAccount(token)).toMatchObject({ paidUntil, lapsed: true, plan: "basic" });
  });

  it("says an account has lapsed from the moment it is paid until", async () => {
    const { account, caller } = await newAccount();
    const paidUntil = await paidUntilOf(account);
    expect(await store.account(caller, paidUntil - 1)).toMatchObject({
      ok: true,
      value: { lapsed: false },
    });
    expect(await store.account(caller, paidUntil)).toMatchObject({
      ok: true,
      value: { lapsed: true },
    });
  });

  it("answers only the session's own account", async () => {
    const one = await newAccount();
    const two = await newAccount(products.pro);
    expect((await putOwnKeyCheck(one.token, new Uint8Array(32).fill(1))).status).toBe(204);

    expect(await readAccount(two.token)).toMatchObject({
      plan: "pro",
      paidUntil: await paidUntilOf(two.account),
      ownKeyCheck: null,
    });
    expect((await putOwnKeyCheck(two.token, new Uint8Array(32).fill(2))).status).toBe(204);
    expect(await readAccount(two.token)).toMatchObject({ ownKeyCheck: "02".repeat(32) });
    expect(await readAccount(one.token)).toMatchObject({ ownKeyCheck: "01".repeat(32) });
  });

  it("needs a live session", async () => {
    const { token } = await newAccount();
    expect((await call("/session", token, { method: "DELETE" })).status).toBe(204);
    expect((await call("/account", token)).status).toBe(401);
    const answer = await exports.default.fetch(new Request("https://mai.test/account"));
    expect(answer.status).toBe(401);
  });

  it("answers 429 once the day's requests are used up, and is counted itself", async () => {
    const { account, token } = await newAccount("test-daily");
    await database.execute({
      sql: "INSERT INTO usage (account_id, day, requests) VALUES (?, ?, 3)",
      args: [account, Math.floor(Date.now() / day)],
    });
    expect(await readAccount(token)).toMatchObject({ usage: { requests: { used: 3, limit: 4 } } });
    expect((await call("/account", token)).status).toBe(429);
  });
});
