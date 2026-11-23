import { exports } from "cloudflare:workers";
import { expect, it } from "vitest";
import { newAccount } from "./accounts";
import fixture from "./fixtures/sealed-writing.json";

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
  const { token } = await newAccount();
  const saved = await exports.default.fetch(
    new Request(`https://mai.test/writings/${fixture.id}`, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/octet-stream",
        "Mai-Base-Revision": "none",
      },
      body: envelope,
    }),
  );
  expect(saved.status).toBe(200);
  // SHA-256 of the envelope, worked out apart from the Worker.
  const revision = "59bb0024959d03a650a7c875607e20a8e04fa059384fec0d60314b563d20fc00";
  expect(await saved.json()).toEqual({ revision });

  const listed = await exports.default.fetch(
    new Request("https://mai.test/writings", { headers: { Authorization: `Bearer ${token}` } }),
  );
  expect(await listed.json()).toEqual({
    writings: [{ id: fixture.id, revision, updated: fixture.updated, size: envelope.length }],
  });
});
