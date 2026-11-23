import { reset } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { afterEach, describe, expect, it } from "vitest";

afterEach(async () => {
  await reset();
});

const token = "test-token";
const id = "6f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f";
const otherId = "00000000-0000-0000-0000-000000000001";

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
    base = "0",
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
    if (base !== null) headers.set("Mai-Base-Version", base);
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
    ["no Authorization header", null],
    ["another token", "Bearer another-token"],
    ["the token without Bearer", token],
  ])("refuses %s", async (_, authorization) => {
    const response = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope(),
      authorization,
    });
    expect(response.status).toBe(401);
    expect(await listed()).toEqual({ writings: [] });
  });
});

describe("saving", () => {
  it("keeps a sealed writing and lists only its ID, version, updated time and size", async () => {
    const body = envelope();
    const saved = await request(`/writings/${id}`, { method: "PUT", body });
    expect(saved.status).toBe(200);
    expect(await saved.json()).toEqual({ version: 1 });

    expect(await listed()).toEqual({
      writings: [{ id, version: 1, updated: 1_790_000_000_123, size: 126 }],
    });

    const read = await request(`/writings/${id}`);
    expect(read.status).toBe(200);
    expect(read.headers.get("Mai-Version")).toBe("1");
    expect(read.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(body);
  });

  it("saves over the version last read, and refuses a save over an older one", async () => {
    await request(`/writings/${id}`, { method: "PUT", body: envelope() });

    const stale = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ updated: 1_790_000_000_999n }),
      base: "0",
    });
    expect(stale.status).toBe(409);
    expect(await stale.json()).toEqual({ version: 1 });

    const next = envelope({ updated: 1_790_000_001_000n, contentsLength: 20 });
    const saved = await request(`/writings/${id}`, { method: "PUT", body: next, base: "1" });
    expect(saved.status).toBe(200);
    expect(await saved.json()).toEqual({ version: 2 });
    expect(await listed()).toEqual({
      writings: [{ id, version: 2, updated: 1_790_000_001_000, size: 136 }],
    });
  });

  it("refuses a first save that claims a version", async () => {
    const response = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope(),
      base: "1",
    });
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ version: 0 });
    expect(await listed()).toEqual({ writings: [] });
  });

  it("names a writing by its lowercase ID whatever case the path uses", async () => {
    const response = await request(`/writings/${id.toUpperCase()}`, {
      method: "PUT",
      body: envelope(),
    });
    expect(response.status).toBe(200);
    expect(await listed()).toEqual({
      writings: [{ id, version: 1, updated: 1_790_000_000_123, size: 126 }],
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
    ["has no base version", 400, { body: envelope(), base: null }],
    ["has a negative base version", 400, { body: envelope(), base: "-1" }],
    ["has a base version with a leading zero", 400, { body: envelope(), base: "01" }],
    ["has a base version that isn't a number", 400, { body: envelope(), base: "one" }],
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

  it.each(["/", "/writings/a/b", "/copies"])("is refused at %s", async (path) => {
    const response = await request(path);
    expect(response.status).toBe(404);
  });

  it("is accepted at exactly 1,900,000 bytes", async () => {
    const response = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ contentsLength: 1_899_884 }),
    });
    expect(response.status).toBe(200);
  });

  it("is accepted with no contents", async () => {
    const response = await request(`/writings/${id}`, {
      method: "PUT",
      body: envelope({ contentsLength: 0 }),
    });
    expect(response.status).toBe(200);
  });
});
