import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";

const bytes = new Uint8Array([0x00, 0x01, 0x00, 0x00, 0xab, 0xcd]);

beforeAll(async () => {
  await env.FONTS.put("fonts/Some-Regular.ttf", bytes);
  await env.FONTS.put("secret.ttf", bytes);
});

function get(path: string, method = "GET"): Promise<Response> {
  return exports.default.fetch(new Request(`https://mai.test${path}`, { method }));
}

describe("GET /fonts/<file>", () => {
  it("answers a file in the bucket with no session, cached for good", async () => {
    const response = await get("/fonts/Some-Regular.ttf");
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("font/ttf");
    expect(response.headers.get("Cache-Control")).toBe("public, max-age=31536000, immutable");
    expect(response.headers.get("ETag")).not.toBeNull();
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(bytes);
  });

  it("answers 404 for a file not in the bucket", async () => {
    expect((await get("/fonts/Other-Regular.ttf")).status).toBe(404);
  });

  it.each([
    "/fonts/%2E%2E%2Fsecret.ttf",
    "/fonts/a/b.ttf",
    "/fonts/x.txt",
    `/fonts/${"a".repeat(1019)}.ttf`,
  ])("answers 404 for %s, which isn't a font file's name", async (path) => {
    expect((await get(path)).status).toBe(404);
  });

  it("answers 405 to anything but GET", async () => {
    const response = await get("/fonts/Some-Regular.ttf", "PUT");
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("GET");
  });
});
