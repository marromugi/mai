import { reset } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { afterEach, expect, it } from "vitest";
import fixture from "./fixtures/sealed-writing.json";

afterEach(async () => {
  await reset();
});

function bytes(hex: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(hex.match(/../g) ?? [], (pair) => parseInt(pair, 16));
}

const envelope = bytes(fixture.envelope);

it("opens, by the layout in Server/README.md, a writing the app sealed", async () => {
  const header = envelope.slice(0, 28);
  const aes = { name: "AES-GCM", additionalData: header, tagLength: 128 };
  const ownKey = await crypto.subtle.importKey("raw", bytes(fixture.ownKey), "AES-GCM", false, [
    "decrypt",
  ]);
  const writingKey = await crypto.subtle.decrypt(
    { ...aes, iv: envelope.slice(28, 40) },
    ownKey,
    envelope.slice(40, 88),
  );
  const key = await crypto.subtle.importKey("raw", writingKey, "AES-GCM", false, ["decrypt"]);
  const contents = await crypto.subtle.decrypt(
    { ...aes, iv: envelope.slice(88, 100) },
    key,
    envelope.slice(100),
  );

  expect(new TextDecoder().decode(contents)).toBe(fixture.contents);
  expect(Array.from(envelope.slice(0, 4))).toEqual([0x6d, 0x61, 0x69, 0x01]);
  expect(new DataView(envelope.buffer).getBigUint64(20)).toBe(BigInt(fixture.updated));
});

it("keeps a writing the app sealed", async () => {
  const saved = await exports.default.fetch(
    new Request(`https://mai.test/writings/${fixture.id}`, {
      method: "PUT",
      headers: {
        Authorization: "Bearer test-token",
        "Content-Type": "application/octet-stream",
        "Mai-Base-Version": "0",
      },
      body: envelope,
    }),
  );
  expect(saved.status).toBe(200);

  const listed = await exports.default.fetch(
    new Request("https://mai.test/writings", { headers: { Authorization: "Bearer test-token" } }),
  );
  expect(await listed.json()).toEqual({
    writings: [{ id: fixture.id, version: 1, updated: fixture.updated, size: envelope.length }],
  });
});
