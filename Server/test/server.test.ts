import { createScheduledController, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { createClient } from "@libsql/client/web";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "../src/index";
import { newAccount, store } from "./accounts";

/** The session token of a new account made for each test. */
let token: string;

beforeEach(async () => {
  ({ token } = await newAccount());
});

const id = "6f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f";
const otherId = "00000000-0000-0000-0000-000000000001";
/** SHA-256 of `envelope()`, and of the one saved after it, worked out apart from the Worker. */
const first = "7116a2b45463fea9eb9d2693081e287f187cd706b8c3a1dac3eb6ddecd0ef965";
const second = "98a3d39a1490f41ea9ab710ccd548dedd3cc435701d0c926a2cd698487892c97";

/** A sealed writing of `contentsLength` ciphertext bytes, laid out as `Server/README.md` says. */
function envelope({
  writing = id,
  updated = 1_790_000_000_123n,
  magic = [0x6d, 0x61, 0x69, 0x01],
  contentsLength = 10,
} = {}): Uint8Array<ArrayBuffer> {
  const bytes = new Uint8Array(4 + 16 + 8 + 60 + 12 + contentsLength + 16);
  bytes.set(magic, 0);
  bytes.set(
    Array.from(writing.replaceAll("-", "").match(/../g) ?? [], (pair) => parseInt(pair, 16)),
    4,
  );
  new DataView(bytes.buffer).setBigUint64(20, updated);
  bytes.fill(0xab, 28);
  return bytes;
}

function request(
  path: string,
  {
    method = "GET",
    body,
    base = "none",
    contentType = "application/octet-stream",
    authorization = `Bearer ${token}`,
  }: {
    method?: string;
    body?: Uint8Array<ArrayBuffer>;
    base?: string | null;
    contentType?: string;
    authorization?: string | null;
  } = {},
): Promise<Response> {
  const headers = new Headers();
  if (authorization !== null) headers.set("Authorization", authorization);
  if (method === "PUT") {
    headers.set("Content-Type", contentType);
    if (base !== null) headers.set("Mai-Base-Revision", base);
  }
  return exports.default.fetch(
    new Request(`https://mai.test${path}`, { method, headers, body: body ?? null }),
  );
}

async function listed(): Promise<unknown> {
  return (await request("/writings")).json();
}

describe("who may call", () => {
  it.each([
    ["no Authorization header", () => null],
    ["a session nobody started", () => `Bearer s1.${otherId}.${"A".repeat(43)}`],
    [
      "the token's session with another secret",
      () => `Bearer ${token.slice(0, -1)}${token.endsWith("A") ? "B" : "A"}`,
    ],
    ["the token without Bearer", () => token],
    ["the token one character short", () => `Bearer ${token.slice(0, -1)}`],
    ["a token of another form", () => "Bearer test-token"],
  ])("refuses %s", async (_, authorization) => {
    const response = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope(),
      authorization: authorization(),
    });
    expect(response.status).toBe(401);
    expect(await response.json()).toHaveProperty("error");
    expect(await listed()).toEqual({ writings: [] });
  });

  it.each([
    ["at a path that isn't a route", "/copies", {}],
    ["at a path that isn't a writing's ID", "/writings/notes", {}],
    ["as POST /writings", "/writings", { method: "POST" }],
    ["as DELETE of a writing", `/writings/${id}`, { method: "DELETE" }],
    [
      "sent as JSON",
      `/writings/${id}`,
      { method: "PUT", body: envelope(), contentType: "application/json" },
    ],
    ["with no base revision", `/writings/${id}`, { method: "PUT", body: envelope(), base: null }],
    ["of a writing too short", `/writings/${id}`, { method: "PUT", body: envelope().slice(0, 1) }],
    ["of another writing", `/writings/${otherId}`, { method: "PUT", body: envelope() }],
  ])("refuses a session nobody started before a request %s", async (_, path, options) => {
    const response = await request(path, {
      ...options,
      authorization: `Bearer s1.${otherId}.${"A".repeat(43)}`,
    });
    expect(response.status).toBe(401);
  });

  it("counts a request turned down for its shape against the day's requests", async () => {
    const authorization = await onTheDailyPlan();
    for (let used = 0; used < 4; used += 1) {
      expect((await request("/copies", { authorization })).status).toBe(404);
    }
    expect((await request("/copies", { authorization })).status).toBe(429);
  });
});

describe("saving", () => {
  it("keeps a sealed writing and lists only its ID, revision, updated time and size", async () => {
    const body = envelope();
    const saved = await request(`/writings/${id}`, { method: "PUT", body });
    expect(saved.status).toBe(200);
    expect(await saved.json()).toEqual({ revision: first });

    expect(await listed()).toEqual({
      writings: [{ id, revision: first, updated: 1_790_000_000_123, size: 126 }],
    });

    const read = await request(`/writings/${id}`);
    expect(read.status).toBe(200);
    expect(read.headers.get("Mai-Revision")).toBe(first);
    expect(read.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(body);
  });

  it("saves over the revision last read, and refuses a save over another", async () => {
    await request(`/writings/${id}`, { method: "PUT", body: envelope() });

    for (const base of ["none", "0".repeat(64)]) {
      const stale = await request(`/writings/${id}`, {
        method: "PUT",
        body: envelope({ updated: 1_790_000_000_999n }),
        base,
      });
      expect(stale.status).toBe(409);
      expect(await stale.json()).toEqual({ revision: first });
    }

    const next = envelope({ updated: 1_790_000_001_000n, contentsLength: 20 });
    const saved = await request(`/writings/${id}`, { method: "PUT", body: next, base: first });
    expect(saved.status).toBe(200);
    expect(await saved.json()).toEqual({ revision: second });
    expect(await listed()).toEqual({
      writings: [{ id, revision: second, updated: 1_790_000_001_000, size: 136 }],
    });
  });

  it("refuses a first save that claims a revision", async () => {
    const response = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope(),
      base: first,
    });
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ revision: null });
    expect(await listed()).toEqual({ writings: [] });
  });

  it("names a writing by its lowercase ID whatever case the path uses", async () => {
    const response = await request(`/writings/${id.toUpperCase()}`, {
      method: "PUT",
      body: envelope(),
    });
    expect(response.status).toBe(200);
    expect(await listed()).toEqual({
      writings: [{ id, revision: first, updated: 1_790_000_000_123, size: 126 }],
    });
  });

  it("answers 404 for a writing it doesn't have", async () => {
    expect((await request(`/writings/${id}`)).status).toBe(404);
  });
});

describe("a write not of the one shape", () => {
  it.each([
    ["is shorter than a sealed writing with no contents", 400, { body: envelope().slice(0, 115) }],
    ["is longer than 1,900,000 bytes", 400, { body: envelope({ contentsLength: 1_899_885 }) }],
    ["starts with other bytes", 400, { body: envelope({ magic: [0x6d, 0x61, 0x69, 0x02] }) }],
    ["holds another writing's ID", 400, { body: envelope({ writing: otherId }) }],
    ["has an updated time of 0", 400, { body: envelope({ updated: 0n }) }],
    [
      "has an updated time past what a number holds exactly",
      400,
      { body: envelope({ updated: 2n ** 53n }) },
    ],
    ["is sent as JSON", 415, { body: envelope(), contentType: "application/json" }],
    ["has no base revision", 400, { body: envelope(), base: null }],
    ["has a base revision of 0", 400, { body: envelope(), base: "0" }],
    ["has a base revision in capitals", 400, { body: envelope(), base: first.toUpperCase() }],
    ["has a base revision one digit short", 400, { body: envelope(), base: first.slice(1) }],
    ["has a base revision that isn't hex", 400, { body: envelope(), base: "g".repeat(64) }],
    ["has a base revision with a digit before it", 400, { body: envelope(), base: `0${first}` }],
    ["has a base revision with a digit after it", 400, { body: envelope(), base: `${first}0` }],
  ])("is refused when it %s", async (_, status, options) => {
    const response = await request(`/writings/${id}`, { method: "PUT", ...options });
    expect(response.status).toBe(status);
    expect(await response.json()).toHaveProperty("error");
    expect(await listed()).toEqual({ writings: [] });
  });

  it("is refused at a path that isn't a writing's ID", async () => {
    const response = await request("/writings/notes", { method: "PUT", body: envelope() });
    expect(response.status).toBe(404);
  });

  it.each([
    ["DELETE", `/writings/${id}`],
    ["POST", `/writings/${id}`],
    ["PUT", "/writings"],
  ])("is refused as %s %s", async (method, path) => {
    const response = await request(path, { method, body: envelope() });
    expect(response.status).toBe(405);
    expect(await listed()).toEqual({ writings: [] });
  });

  it.each(["/", "/writings/a/b", `/writings/${id}/copies`, "/copies"])(
    "is refused at %s",
    async (path) => {
      const response = await request(path);
      expect(response.status).toBe(404);
    },
  );

  it("is refused at a path past a writing it has", async () => {
    await request(`/writings/${id}`, { method: "PUT", body: envelope() });
    expect((await request(`/writings/${id}/x`)).status).toBe(404);
  });

  it("is accepted at exactly 1,900,000 bytes", async () => {
    const response = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ contentsLength: 1_899_884 }),
    });
    expect(response.status).toBe(200);
  });

  it.each([`x${id}`, `${id}0`, id.slice(1)])("is refused at /writings/%s", async (path) => {
    const response = await request(`/writings/${path}`, { method: "PUT", body: envelope() });
    expect(response.status).toBe(404);
    expect(await listed()).toEqual({ writings: [] });
  });

  it("is accepted with the latest updated time the server holds", async () => {
    const response = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ updated: 2n ** 53n - 1n }),
    });
    expect(response.status).toBe(200);
    expect(await listed()).toMatchObject({ writings: [{ updated: 9_007_199_254_740_991 }] });
  });

  it("is accepted with no contents", async () => {
    const response = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ contentsLength: 0 }),
    });
    expect(response.status).toBe(200);
  });
});

describe("one account and another", () => {
  it("can't read or write each other's writings", async () => {
    const saved = await request(`/writings/${id}`, { method: "PUT", body: envelope() });
    expect(saved.status).toBe(200);
    const other = `Bearer ${(await newAccount()).token}`;

    expect(await (await request("/writings", { authorization: other })).json()).toEqual({
      writings: [],
    });
    expect((await request(`/writings/${id}`, { authorization: other })).status).toBe(404);

    const overTheFirst = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ updated: 1_790_000_001_000n, contentsLength: 20 }),
      base: first,
      authorization: other,
    });
    expect(overTheFirst.status).toBe(409);
    expect(await overTheFirst.json()).toEqual({ revision: null });

    const ownUnderTheSameId = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ updated: 1_790_000_001_000n, contentsLength: 20 }),
      authorization: other,
    });
    expect(ownUnderTheSameId.status).toBe(200);

    expect(await listed()).toEqual({
      writings: [{ id, revision: first, updated: 1_790_000_000_123, size: 126 }],
    });
    const read = await request(`/writings/${id}`);
    expect(read.headers.get("Mai-Revision")).toBe(first);
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(envelope());
  });
});

/** A new account on the plan `test-daily` (test/sqld.ts): 4 requests a day, 2 lists, 2 saves. */
async function onTheDailyPlan(): Promise<string> {
  return `Bearer ${(await newAccount("test-daily")).token}`;
}

describe("a plan's daily limits", () => {
  it("answers 429 once the day's requests are used up", async () => {
    const authorization = await onTheDailyPlan();
    for (let used = 0; used < 4; used += 1) {
      expect((await request(`/writings/${id}`, { authorization })).status).toBe(404);
    }
    const refused = await request(`/writings/${id}`, { authorization });
    expect(refused.status).toBe(429);
    expect(await refused.json()).toHaveProperty("error");
    expect((await request("/writings", { authorization })).status).toBe(429);
  });

  it("answers 429 once the day's lists are used up, and doesn't count what it refused", async () => {
    const authorization = await onTheDailyPlan();
    expect((await request("/writings", { authorization })).status).toBe(200);
    expect((await request("/writings", { authorization })).status).toBe(200);
    expect((await request("/writings", { authorization })).status).toBe(429);
    expect((await request("/writings", { authorization })).status).toBe(429);
    // Two requests counted so far, so two more of another kind pass.
    expect((await request(`/writings/${id}`, { authorization })).status).toBe(404);
    expect((await request(`/writings/${id}`, { authorization })).status).toBe(404);
    expect((await request(`/writings/${id}`, { authorization })).status).toBe(429);
  });

  it("answers 429 once the day's saves are used up, a refused save among them", async () => {
    const authorization = await onTheDailyPlan();
    const save = (base: string): Promise<Response> =>
      request(`/writings/${id}`, { method: "PUT", body: envelope(), base, authorization });
    expect((await save("none")).status).toBe(200);
    expect((await save("none")).status).toBe(409);
    const refused = await save(first);
    expect(refused.status).toBe(429);
    expect(await refused.json()).toHaveProperty("error");
  });

  it("does the last save and list the day allows, and nothing past them", async () => {
    const authorization = await onTheDailyPlan();
    const next = envelope({ updated: 1_790_000_001_000n, contentsLength: 20 });
    const put = (body: Uint8Array<ArrayBuffer>, base: string): Promise<Response> =>
      request(`/writings/${id}`, { method: "PUT", body, base, authorization });
    expect((await put(envelope(), "none")).status).toBe(200);
    expect((await put(next, first)).status).toBe(200);
    expect((await put(envelope({ updated: 1_790_000_002_000n }), second)).status).toBe(429);

    const read = await request(`/writings/${id}`, { authorization });
    expect(read.headers.get("Mai-Revision")).toBe(second);
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(next);
    expect(await (await request("/writings", { authorization })).json()).toEqual({
      writings: [{ id, revision: second, updated: 1_790_000_001_000, size: 136 }],
    });
  });

  it("starts again the next day", async () => {
    const now = Date.now();
    const { caller } = await newAccount("test-daily", now);
    expect((await store.list(caller, now)).ok).toBe(true);
    expect((await store.list(caller, now)).ok).toBe(true);
    expect(await store.list(caller, now)).toEqual({ ok: false, refusal: "lists" });
    expect((await store.list(caller, now + 24 * 60 * 60 * 1000)).ok).toBe(true);
  });
});

describe("a plan's storage", () => {
  // The plan `test-storage` (test/sqld.ts) holds 300 bytes, and `test-count` 2 writings;
  // envelope() is 126 bytes.
  let authorization: string;

  beforeEach(async () => {
    authorization = `Bearer ${(await newAccount("test-storage")).token}`;
  });

  it("refuses a writing past the plan's number of writings", async () => {
    authorization = `Bearer ${(await newAccount("test-count")).token}`;
    for (const writing of [id, otherId]) {
      const saved = await request(`/writings/${writing}`, {
        method: "PUT",
        body: envelope({ writing }),
        authorization,
      });
      expect(saved.status).toBe(200);
    }
    const third = "00000000-0000-0000-0000-000000000002";
    const refused = await request(`/writings/${third}`, {
      method: "PUT",
      body: envelope({ writing: third }),
      authorization,
    });
    expect(refused.status).toBe(429);
    expect(await refused.json()).toHaveProperty("error");
    expect((await request(`/writings/${third}`, { authorization })).status).toBe(404);
  });

  it("refuses a save that grows the writings past the plan's bytes, and keeps the writing", async () => {
    await request(`/writings/${id}`, { method: "PUT", body: envelope(), authorization });
    await request(`/writings/${otherId}`, {
      method: "PUT",
      body: envelope({ writing: otherId }),
      authorization,
    });

    // 126 + 175 = 301 bytes.
    const grown = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ updated: 1_790_000_001_000n, contentsLength: 59 }),
      base: first,
      authorization,
    });
    expect(grown.status).toBe(429);
    const kept = await request(`/writings/${id}`, { authorization });
    expect(kept.headers.get("Mai-Revision")).toBe(first);

    // 126 + 174 = 300 bytes.
    const filled = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ updated: 1_790_000_001_000n, contentsLength: 58 }),
      base: first,
      authorization,
    });
    expect(filled.status).toBe(200);
  });

  it("takes a new writing up to the plan's bytes and refuses one past them", async () => {
    // 126 + 174 = 300 bytes.
    await request(`/writings/${id}`, { method: "PUT", body: envelope(), authorization });
    const filling = await request(`/writings/${otherId}`, {
      method: "PUT",
      body: envelope({ writing: otherId, contentsLength: 58 }),
      authorization,
    });
    expect(filling.status).toBe(200);

    const third = "00000000-0000-0000-0000-000000000002";
    const refused = await request(`/writings/${third}`, {
      method: "PUT",
      body: envelope({ writing: third, contentsLength: 0 }),
      authorization,
    });
    expect(refused.status).toBe(429);
  });

  it("lets an account over its plan shrink a writing, and doesn't hold it against another", async () => {
    const before = await newAccount("test-storage");
    const over = await newAccount("basic");
    const writings = [id, otherId, "00000000-0000-0000-0000-000000000002"];
    for (const writing of writings) {
      const saved = await request(`/writings/${writing}`, {
        method: "PUT",
        body: envelope({ writing, contentsLength: 30 }),
        authorization: `Bearer ${over.token}`,
      });
      expect(saved.status).toBe(200);
    }
    // 3 × 146 = 438 bytes, over `test-storage`'s 300.
    await createClient({ url: env.TURSO_URL }).execute({
      sql: "UPDATE accounts SET tier = 'test-storage' WHERE id = ?",
      args: [over.account],
    });
    const after = await newAccount("test-storage");

    const read = await request(`/writings/${id}`, { authorization: `Bearer ${over.token}` });
    const overBase = read.headers.get("Mai-Revision") ?? "";
    const shrunk = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ updated: 1_790_000_001_000n }),
      base: overBase,
      authorization: `Bearer ${over.token}`,
    });
    expect(shrunk.status).toBe(200);
    const grown = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ updated: 1_790_000_002_000n, contentsLength: 11 }),
      base: (await shrunk.json<{ revision: string }>()).revision,
      authorization: `Bearer ${over.token}`,
    });
    expect(grown.status).toBe(429);

    for (const other of [before, after]) {
      const others = `Bearer ${other.token}`;
      for (const writing of [id, otherId]) {
        const saved = await request(`/writings/${writing}`, {
          method: "PUT",
          body: envelope({ writing }),
          authorization: others,
        });
        expect(saved.status).toBe(200);
      }
      // 174 + 126 = 300 bytes.
      const filled = await request(`/writings/${id}`, {
        method: "PUT",
        body: envelope({ updated: 1_790_000_001_000n, contentsLength: 58 }),
        base: first,
        authorization: others,
      });
      expect(filled.status).toBe(200);
    }
  });

  it("doesn't count one account's growing writing against another", async () => {
    const growing = `Bearer ${(await newAccount("test-storage")).token}`;
    await request(`/writings/${id}`, { method: "PUT", body: envelope(), authorization });
    await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope(),
      authorization: growing,
    });
    const grown = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ updated: 1_790_000_001_000n, contentsLength: 58 }),
      base: first,
      authorization: growing,
    });
    expect(grown.status).toBe(200);

    // 126 + 174 = 300 bytes.
    const filled = await request(`/writings/${otherId}`, {
      method: "PUT",
      body: envelope({ writing: otherId, contentsLength: 58 }),
      authorization,
    });
    expect(filled.status).toBe(200);
  });
});

const lifetime = 180 * 24 * 60 * 60 * 1000;

describe("a session", () => {
  it("ends 180 days after it was last used", async () => {
    const { token: ended, caller } = await newAccount("basic", Date.now() - lifetime);
    const response = await request("/writings", { authorization: `Bearer ${ended}` });
    expect(response.status).toBe(401);
    expect(await response.json()).toHaveProperty("error");
    expect(await store.list(caller, Date.now())).toEqual({ ok: false, refusal: "session" });
  });

  it("isn't kept alive by a request with another secret", async () => {
    const now = Date.now();
    const { token: nearlyEnded, caller } = await newAccount("basic", now - lifetime + 60_000);
    const wrong = `Bearer ${nearlyEnded.slice(0, -1)}${nearlyEnded.endsWith("A") ? "B" : "A"}`;
    expect((await request("/writings", { authorization: wrong })).status).toBe(401);
    expect(await store.list(caller, now + 120_000)).toEqual({ ok: false, refusal: "session" });
  });

  it("lasts 180 days from its last use", async () => {
    const now = Date.now();
    const { token: nearlyEnded, caller } = await newAccount("basic", now - lifetime + 60_000);
    const used = await request("/writings", { authorization: `Bearer ${nearlyEnded}` });
    expect(used.status).toBe(200);
    expect((await store.list(caller, now + 120_000)).ok).toBe(true);
    expect(await store.list(caller, now + lifetime + 60_000)).toEqual({
      ok: false,
      refusal: "session",
    });
  });
});

describe("the cron trigger", () => {
  it("removes ended sessions and past days' counts", async () => {
    const now = Date.now();
    const longAgo = now - lifetime - 24 * 60 * 60 * 1000;
    const ended = await newAccount("basic", longAgo);
    expect((await store.list(ended.caller, longAgo)).ok).toBe(true);
    const alive = await newAccount("basic", now);
    expect((await store.list(alive.caller, now)).ok).toBe(true);

    await worker.scheduled(createScheduledController(), env);

    expect(await store.list(ended.caller, longAgo)).toEqual({ ok: false, refusal: "session" });
    expect((await store.list(alive.caller, now)).ok).toBe(true);
    const counted = await createClient({ url: env.TURSO_URL }).execute({
      sql: "SELECT account_id FROM usage WHERE account_id IN (?, ?)",
      args: [ended.account, alive.account],
    });
    expect(counted.rows.map((row) => row["account_id"])).toEqual([alive.account]);
  });
});
