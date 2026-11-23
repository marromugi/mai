import { createScheduledController, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { createClient } from "@libsql/client/web";
import { describe, expect, it } from "vitest";
import worker, { serve, signInOf } from "../src/index";
import { parseAccountId } from "../src/account-id";
import { parsePhotoId, parsePhotoPart } from "../src/photo-id";
import { largestPart } from "../src/photos";
import { uploadLifetime, type Upload } from "../src/store";
import { newAccount, products, store } from "./accounts";

const database = createClient({ url: env.TURSO_URL });
const day = 24 * 60 * 60 * 1000;

/** Sealed bytes as the app would send them: the server never looks inside. */
function sealed(length: number, fill = 0xab): Uint8Array<ArrayBuffer> {
  return new Uint8Array(length).fill(fill);
}

function photoRequest(
  path: string,
  token: string,
  {
    method = "GET",
    body,
    contentType = "application/octet-stream",
    contentLength = body?.byteLength,
  }: {
    method?: string;
    body?: Uint8Array<ArrayBuffer>;
    contentType?: string | null;
    contentLength?: number | string;
  } = {},
): Request {
  const headers = new Headers({ Authorization: `Bearer ${token}` });
  if (method === "PUT") {
    if (contentType !== null) headers.set("Content-Type", contentType);
    // serve() called directly sees only the headers set here; a device always sends it.
    if (contentLength !== undefined) headers.set("Content-Length", String(contentLength));
  }
  return new Request(`https://mai.test${path}`, { method, headers, body: body ?? null });
}

function call(...request: Parameters<typeof photoRequest>): Promise<Response> {
  return exports.default.fetch(photoRequest(...request));
}

function put(path: string, token: string, body: Uint8Array<ArrayBuffer>): Promise<Response> {
  return call(path, token, { method: "PUT", body });
}

/** Answers `request` with R2 reached through `bucket`, and Apple never reached. */
async function serveWith(request: Request, bucket: R2Bucket): Promise<Response> {
  const signIn = signInOf(
    env,
    () => Promise.reject(new Error("the photo routes don't reach Apple")),
    await caches.open(crypto.randomUUID()),
  );
  return serve(request, signIn, bucket);
}

/** `env.PHOTOS` with `put` replaced. */
function bucketWith(replacement: R2Bucket["put"]): R2Bucket {
  return new Proxy(env.PHOTOS, {
    get(target, name, receiver) {
      if (name === "put") return replacement;
      const value: unknown = Reflect.get(target, name, receiver);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

/** The upload a key of `photoKey` names, read back from the key. */
function uploadOf(key: string, size: number): Upload {
  const [account, id, part, upload] = key.split("/");
  const parsed = {
    account: parseAccountId(account ?? ""),
    id: parsePhotoId(id ?? ""),
    part: parsePhotoPart(part ?? ""),
  };
  if (
    parsed.account === undefined ||
    parsed.id === undefined ||
    parsed.part === undefined ||
    upload === undefined
  ) {
    throw new Error(`${key} isn't a key photoKey makes`);
  }
  return { account: parsed.account, id: parsed.id, part: parsed.part, upload, size };
}

async function keysOf(account: string): Promise<string[]> {
  const listed = await env.PHOTOS.list({ prefix: `${account}/` });
  return listed.objects.map((object) => object.key).toSorted();
}

async function photoRows(account: string): Promise<unknown[]> {
  const { rows } = await database.execute({
    sql: "SELECT id, part, size, stored FROM photos WHERE account_id = ? ORDER BY id, part",
    args: [account],
  });
  return rows.map((row) => ({ ...row }));
}

async function photosBytes(account: string): Promise<number> {
  const { rows } = await database.execute({
    sql: "SELECT photos_bytes FROM accounts WHERE id = ?",
    args: [account],
  });
  return Number(rows[0]?.["photos_bytes"]);
}

async function usageOf(token: string): Promise<unknown> {
  const answer = await call("/account", token);
  expect(answer.status).toBe(200);
  const { usage } = await answer.json<{ usage: unknown }>();
  return usage;
}

async function bytesOf(answer: Response): Promise<Uint8Array> {
  return new Uint8Array(await answer.arrayBuffer());
}

describe("a photo and its thumbnail", () => {
  it("are kept apart and read back as they were sent", async () => {
    const { account, token } = await newAccount();
    const id = crypto.randomUUID();
    expect((await put(`/photos/${id}`, token, sealed(500, 1))).status).toBe(201);
    expect((await put(`/photos/${id}/thumbnail`, token, sealed(40, 2))).status).toBe(201);

    const photo = await call(`/photos/${id}`, token);
    expect(photo.status).toBe(200);
    expect(photo.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(photo.headers.get("Content-Length")).toBe("500");
    expect(await bytesOf(photo)).toEqual(sealed(500, 1));
    const thumbnail = await call(`/photos/${id}/thumbnail`, token);
    expect(thumbnail.status).toBe(200);
    expect(await bytesOf(thumbnail)).toEqual(sealed(40, 2));

    expect(await keysOf(account)).toHaveLength(2);
    for (const key of await keysOf(account)) {
      expect(key.startsWith(`${account}/${id}/`)).toBe(true);
    }
    expect(await photosBytes(account)).toBe(540);
  });

  it("are named by their lowercase ID whatever case the path uses", async () => {
    const { token } = await newAccount();
    const id = crypto.randomUUID();
    expect((await put(`/photos/${id.toUpperCase()}`, token, sealed(10))).status).toBe(201);
    expect((await call(`/photos/${id}`, token)).status).toBe(200);
  });

  it("are counted in the account's usage, the thumbnail not as one of the day's photos", async () => {
    const { token } = await newAccount();
    const id = crypto.randomUUID();
    await put(`/photos/${id}`, token, sealed(500));
    await put(`/photos/${id}/thumbnail`, token, sealed(40));
    expect(await usageOf(token)).toMatchObject({
      photosBytes: { used: 540, limit: 5_000_000_000 },
      photos: { used: 1, limit: 100 },
    });
  });

  it("answer 404 when the server has none", async () => {
    const { token } = await newAccount();
    const id = crypto.randomUUID();
    expect((await call(`/photos/${id}`, token)).status).toBe(404);
    await put(`/photos/${id}`, token, sealed(10));
    expect((await call(`/photos/${id}/thumbnail`, token)).status).toBe(404);
  });

  it("are taken once: a second put of the same part is 409 and changes nothing", async () => {
    const { account, token } = await newAccount();
    const id = crypto.randomUUID();
    expect((await put(`/photos/${id}`, token, sealed(10, 1))).status).toBe(201);
    const again = await put(`/photos/${id}`, token, sealed(20, 2));
    expect(again.status).toBe(409);
    expect(await bytesOf(await call(`/photos/${id}`, token))).toEqual(sealed(10, 1));
    expect(await photosBytes(account)).toBe(10);
    expect(await keysOf(account)).toHaveLength(1);
  });
});

describe("one account and another", () => {
  it("can't read each other's photos, and keep their own under the same ID", async () => {
    const one = await newAccount();
    const two = await newAccount();
    const id = crypto.randomUUID();
    await put(`/photos/${id}`, one.token, sealed(10, 1));
    await put(`/photos/${id}/thumbnail`, one.token, sealed(5, 1));
    expect((await call(`/photos/${id}`, two.token)).status).toBe(404);
    expect((await call(`/photos/${id}/thumbnail`, two.token)).status).toBe(404);

    expect((await put(`/photos/${id}`, two.token, sealed(30, 2))).status).toBe(201);
    expect(await bytesOf(await call(`/photos/${id}`, one.token))).toEqual(sealed(10, 1));
    expect(await bytesOf(await call(`/photos/${id}`, two.token))).toEqual(sealed(30, 2));
    expect(await photosBytes(one.account)).toBe(15);
    expect(await photosBytes(two.account)).toBe(30);
  });

  it("can't be read without a session", async () => {
    const { token } = await newAccount();
    const id = crypto.randomUUID();
    await put(`/photos/${id}`, token, sealed(10));
    const answer = await exports.default.fetch(new Request(`https://mai.test/photos/${id}`));
    expect(answer.status).toBe(401);
  });
});

describe("a plan's photo storage", () => {
  it("takes photos up to the plan's bytes and refuses one past them, keeping nothing of it", async () => {
    // test/sqld.ts: test-photos holds 300 bytes of photos.
    const { account, token } = await newAccount("test-photos");
    expect((await put(`/photos/${crypto.randomUUID()}`, token, sealed(200))).status).toBe(201);
    const over = crypto.randomUUID();
    const refused = await put(`/photos/${over}/thumbnail`, token, sealed(101));
    expect(refused.status).toBe(429);
    expect(await refused.json()).toEqual({
      error: "the plan's storage for photos has no room for this",
    });
    expect(await photosBytes(account)).toBe(200);
    expect(await keysOf(account)).toHaveLength(1);
    expect((await call(`/photos/${over}/thumbnail`, token)).status).toBe(404);
    expect((await put(`/photos/${over}/thumbnail`, token, sealed(100))).status).toBe(201);
    expect(await photosBytes(account)).toBe(300);
  });

  it("doesn't count one account's photos against another's", async () => {
    const one = await newAccount("test-photos");
    const two = await newAccount("test-photos");
    expect((await put(`/photos/${crypto.randomUUID()}`, one.token, sealed(300))).status).toBe(201);
    expect((await put(`/photos/${crypto.randomUUID()}`, two.token, sealed(300))).status).toBe(201);
  });
});

describe("a plan's photos for the day", () => {
  it("answers 429 past the day's photos, and still takes thumbnails", async () => {
    // test/sqld.ts: test-daily takes 2 photos and 4 requests a day.
    const { account, token } = await newAccount("test-daily");
    const id = crypto.randomUUID();
    expect((await put(`/photos/${id}`, token, sealed(10))).status).toBe(201);
    expect((await put(`/photos/${crypto.randomUUID()}`, token, sealed(10))).status).toBe(201);
    const refused = await put(`/photos/${crypto.randomUUID()}`, token, sealed(10));
    expect(refused.status).toBe(429);
    expect(await refused.json()).toEqual({ error: "the plan's photos for today are used up" });
    expect((await put(`/photos/${id}/thumbnail`, token, sealed(10))).status).toBe(201);
    expect(await photosBytes(account)).toBe(30);
  });
});

describe("an upload that fails", () => {
  it("releases its room when R2 doesn't get as many bytes as it was sent with", async () => {
    const { account, token } = await newAccount();
    const id = crypto.randomUUID();
    const short = photoRequest(`/photos/${id}`, token, {
      method: "PUT",
      body: sealed(10),
      contentLength: 20,
    });
    await expect(exports.default.fetch(short)).rejects.toThrow();
    expect(await photoRows(account)).toEqual([]);
    expect(await photosBytes(account)).toBe(0);
    expect(await keysOf(account)).toEqual([]);
    expect((await put(`/photos/${id}`, token, sealed(10))).status).toBe(201);
  });

  it("releases its room when R2 fails, and lets the photo be sent again", async () => {
    const { account, token } = await newAccount();
    const id = crypto.randomUUID();
    const failing = bucketWith(() => Promise.reject(new Error("R2 is unreachable")));
    const request = photoRequest(`/photos/${id}`, token, { method: "PUT", body: sealed(10) });
    await expect(serveWith(request, failing)).rejects.toThrow("R2 is unreachable");
    expect(await photoRows(account)).toEqual([]);
    expect(await photosBytes(account)).toBe(0);
    expect((await put(`/photos/${id}`, token, sealed(10))).status).toBe(201);
  });

  it("answers 408 and keeps nothing when its room was released while R2 took it", async () => {
    const { account, token } = await newAccount();
    const id = crypto.randomUUID();
    const slow = bucketWith(async (key, value) => {
      const object = await env.PHOTOS.put(key, value);
      if (object === null) throw new Error("a put without onlyIf always stores");
      // The cron trigger releasing it as stale, as R2 finishes.
      await store.releaseUploads([uploadOf(key, 10)]);
      return object;
    });
    const request = photoRequest(`/photos/${id}`, token, { method: "PUT", body: sealed(10) });
    const answer = await serveWith(request, slow);
    expect(answer.status).toBe(408);
    expect(await photoRows(account)).toEqual([]);
    expect(await photosBytes(account)).toBe(0);
    expect(await keysOf(account)).toEqual([]);
  });
});

describe("the cron trigger", () => {
  it("releases an upload that never finished, and what R2 holds of it, an hour on", async () => {
    const { account, caller } = await newAccount();
    const id = parsePhotoId(crypto.randomUUID());
    if (id === undefined) throw new Error("crypto.randomUUID gives a UUID");
    const now = Date.now();
    const stale = await store.reservePhoto(caller, id, "photo", 10, now - uploadLifetime);
    const fresh = await store.reservePhoto(caller, id, "thumbnail", 5, now - uploadLifetime + 1000);
    if (!stale.ok || !stale.value.reserved || !fresh.ok || !fresh.value.reserved) {
      throw new Error("a new account reserves room for a photo");
    }
    // A Worker that stopped after R2 took the bytes, before it marked them stored.
    const key = `${account}/${id}/photo/${stale.value.upload.upload}`;
    await env.PHOTOS.put(key, sealed(10));
    expect(await photosBytes(account)).toBe(15);

    await worker.scheduled(createScheduledController({ scheduledTime: now }), env);

    expect(await photoRows(account)).toEqual([{ id, part: "thumbnail", size: 5, stored: 0 }]);
    expect(await photosBytes(account)).toBe(5);
    expect(await keysOf(account)).toEqual([]);
  });

  it("leaves stored photos as they are", async () => {
    const { account, token } = await newAccount();
    const id = crypto.randomUUID();
    await put(`/photos/${id}`, token, sealed(10));
    await database.execute({
      sql: "UPDATE photos SET reserved = reserved - ? WHERE account_id = ?",
      args: [day, account],
    });
    await worker.scheduled(createScheduledController({ scheduledTime: Date.now() }), env);
    expect(await photosBytes(account)).toBe(10);
    expect((await call(`/photos/${id}`, token)).status).toBe(200);
  });
});

describe("a lapsed account", () => {
  it("reads its photos but can't send any", async () => {
    const { account, token } = await newAccount(products.basic);
    const id = crypto.randomUUID();
    await put(`/photos/${id}`, token, sealed(10));
    await put(`/photos/${id}/thumbnail`, token, sealed(5));
    await database.execute({
      sql: "UPDATE accounts SET paid_until = ? WHERE id = ?",
      args: [Date.now() - 1000, account],
    });

    expect(await bytesOf(await call(`/photos/${id}`, token))).toEqual(sealed(10));
    expect(await bytesOf(await call(`/photos/${id}/thumbnail`, token))).toEqual(sealed(5));
    const other = crypto.randomUUID();
    for (const path of [`/photos/${other}`, `/photos/${other}/thumbnail`]) {
      const refused = await put(path, token, sealed(10));
      expect(refused.status).toBe(402);
    }
    expect(await photosBytes(account)).toBe(15);
    expect(await keysOf(account)).toHaveLength(2);
    expect(await usageOf(token)).toMatchObject({ photos: { used: 1 } });
  });
});

describe("a photo request not of the one shape", () => {
  const id = "6f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f";

  it.each([
    ["another Content-Type", { contentType: "image/jpeg" }, 415],
    ["no Content-Type", { contentType: null }, 415],
    ["a Content-Length that isn't a number", { contentLength: "ten" }, 411],
    ["no bytes", { body: sealed(0) }, 400],
  ] as const)("is refused for %s", async (_, init, status) => {
    const { account, token } = await newAccount();
    const answer = await call(`/photos/${id}`, token, {
      method: "PUT",
      body: sealed(10),
      ...init,
    });
    expect(answer.status).toBe(status);
    expect(await photoRows(account)).toEqual([]);
  });

  it.each([
    ["photo", `/photos/${id}`],
    ["thumbnail", `/photos/${id}/thumbnail`],
  ] as const)("is refused with 413 for a %s past its largest", async (part, path) => {
    const { account, token } = await newAccount();
    const answer = await call(path, token, {
      method: "PUT",
      body: sealed(10),
      contentLength: largestPart[part] + 1,
    });
    expect(answer.status).toBe(413);
    expect(await photoRows(account)).toEqual([]);
  });

  it.each([
    ["/photos", 404],
    ["/photos/not-a-uuid", 404],
    [`/photos/${id}/original`, 404],
    [`/photos/${id}/thumbnail/more`, 404],
  ] as const)("is refused at %s", async (path, status) => {
    const { token } = await newAccount();
    expect((await call(path, token)).status).toBe(status);
  });

  it("is refused for a method other than GET and PUT", async () => {
    const { token } = await newAccount();
    expect((await call(`/photos/${id}`, token, { method: "DELETE" })).status).toBe(405);
  });

  it("is refused with 411 when sent without its length", async () => {
    const { account, token } = await newAccount();
    const chunked = new ReadableStream({
      start(controller) {
        controller.enqueue(sealed(10));
        controller.close();
      },
    });
    const answer = await exports.default.fetch(
      new Request(`https://mai.test/photos/${id}`, {
        method: "PUT",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/octet-stream" },
        body: chunked,
      }),
    );
    expect(answer.status).toBe(411);
    expect(await photoRows(account)).toEqual([]);
  });
});
