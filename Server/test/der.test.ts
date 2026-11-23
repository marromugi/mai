import { describe, expect, it } from "vitest";
import { appleRootCaG3Der } from "../src/apple-root";
import { appleOids } from "../src/app-store";
import { equalBytes, rawSignature, readCertificate } from "../src/der";
import { certificateOf, concat, integer, makeCertificate, sequence, tlv } from "./apple-fakes";

/** Where the element at `path` starts in `der`: each number picks a child of the one before. */
function locate(der: Uint8Array, path: readonly number[]): number {
  let offset = 0;
  for (const index of path) {
    let child = offset + headerLength(der, offset);
    for (let skipped = 0; skipped < index; skipped += 1) {
      child += headerLength(der, child) + contentLength(der, child);
    }
    offset = child;
  }
  return offset;
}

function headerLength(der: Uint8Array, offset: number): number {
  const first = der[offset + 1] ?? 0;
  return first & 0x80 ? 2 + (first & 0x7f) : 2;
}

function contentLength(der: Uint8Array, offset: number): number {
  const first = der[offset + 1] ?? 0;
  if (!(first & 0x80)) {
    return first;
  }
  let length = 0;
  for (let index = 0; index < (first & 0x7f); index += 1) {
    length = length * 256 + (der[offset + 2 + index] ?? 0);
  }
  return length;
}

/** G3 with the byte at `path`, plus `step`, set to `value`. */
function changed(path: readonly number[], step: number, value: number): Uint8Array {
  const bytes = appleRootCaG3Der.slice();
  bytes[locate(bytes, path) + step] = value;
  return bytes;
}

/** The last byte of the element at `path`. */
function lastByte(path: readonly number[]): number {
  const offset = locate(appleRootCaG3Der, path);
  return headerLength(appleRootCaG3Der, offset) + contentLength(appleRootCaG3Der, offset) - 1;
}

describe("reading a certificate", () => {
  it("reads Apple Root CA - G3's dates", () => {
    const root = readCertificate(appleRootCaG3Der);
    expect(root?.notBefore).toBe(Date.UTC(2014, 3, 30, 18, 19, 6));
    expect(root?.notAfter).toBe(Date.UTC(2039, 3, 30, 18, 19, 6));
  });

  it.each([
    ["the certificate isn't a SEQUENCE", [], 0, 0x31],
    ["the signed part isn't a SEQUENCE", [0], 0, 0x31],
    ["the algorithm isn't a SEQUENCE", [1], 0, 0x31],
    ["the signature isn't a BIT STRING", [2], 0, 0x04],
    ["the signature's BIT STRING has unused bits", [2], 2, 0x01],
    ["the version isn't [0]", [0, 0], 0, 0xa1],
    ["the serial number isn't an INTEGER", [0, 1], 0, 0x0a],
    ["the issuer isn't a SEQUENCE", [0, 3], 0, 0x31],
    ["the validity isn't a SEQUENCE", [0, 4], 0, 0x31],
    ["notBefore isn't a time", [0, 4, 0], 0, 0x13],
    ["the subject isn't a SEQUENCE", [0, 5], 0, 0x31],
    ["the key isn't a SEQUENCE", [0, 6], 0, 0x31],
    ["the key isn't an EC key", [0, 6, 0, 0], lastByte([0, 6, 0, 0]), 0x02],
    ["the key's curve isn't P-256 or P-384", [0, 6, 0, 1], lastByte([0, 6, 0, 1]), 0x23],
    ["the key's algorithm isn't a SEQUENCE", [0, 6, 0], 0, 0x31],
    ["the extension list isn't a SEQUENCE", [0, 7, 0], 0, 0x31],
    ["an extension isn't a SEQUENCE", [0, 7, 0, 0], 0, 0x31],
    ["an extension's value isn't an OCTET STRING", [0, 7, 0, 0, 1], 0, 0x13],
    ["an extension's ID isn't an OID", [0, 7, 0, 0, 0], 0, 0x13],
    ["the signed algorithm differs from the outer one", [0, 2, 0], lastByte([0, 2, 0]), 0x02],
  ])("gives nothing when %s", (_, path, step, value) => {
    expect(readCertificate(changed(path, step, value))).toBeUndefined();
  });

  it("gives nothing when both algorithms are ECDSA with SHA-512", () => {
    const bytes = appleRootCaG3Der.slice();
    for (const path of [
      [0, 2, 0],
      [1, 0],
    ]) {
      bytes[locate(bytes, path) + lastByte(path)] = 0x04;
    }
    expect(readCertificate(bytes)).toBeUndefined();
  });

  it("reads basicConstraints' cA only from a BOOLEAN", () => {
    // G3's second extension is basicConstraints: OID, critical, OCTET STRING { SEQUENCE { cA } }.
    const octet = locate(appleRootCaG3Der, [0, 7, 0, 1, 2]);
    const bytes = appleRootCaG3Der.slice();
    bytes[octet + 4] = 0x02;
    expect(readCertificate(bytes)?.authority).toBe(false);
  });

  it("gives nothing with a byte after the certificate", () => {
    expect(readCertificate(concat(appleRootCaG3Der, Uint8Array.of(0)))).toBeUndefined();
  });

  it("gives nothing when cut short", () => {
    expect(readCertificate(appleRootCaG3Der.subarray(0, -1))).toBeUndefined();
  });

  it("gives nothing with a length in the indefinite form", () => {
    const bytes = appleRootCaG3Der.slice();
    bytes[locate(bytes, [0]) + 1] = 0x80;
    expect(readCertificate(bytes)).toBeUndefined();
  });

  it("gives nothing with a fourth part", () => {
    const parts = [0, 1, 2].map((index) => {
      const offset = locate(appleRootCaG3Der, [index]);
      return appleRootCaG3Der.subarray(
        offset,
        offset + headerLength(appleRootCaG3Der, offset) + contentLength(appleRootCaG3Der, offset),
      );
    });
    expect(readCertificate(sequence(...parts))).toBeDefined();
    expect(readCertificate(sequence(...parts, Uint8Array.of(0x05, 0x00)))).toBeUndefined();
  });

  it("reads a certificate with no extensions as no authority", async () => {
    const plain = await makeCertificate({ name: "Plain", curve: "P-256" });
    expect(certificateOf(plain).authority).toBe(false);
    expect(certificateOf(plain).extensions.size).toBe(0);
  });

  it("reads cA stated as FALSE as no authority", async () => {
    const stated = await makeCertificate({
      name: "Stated",
      curve: "P-256",
      authority: "stated-false",
    });
    expect(certificateOf(stated).authority).toBe(false);
  });

  it("gives nothing when an extension appears twice", async () => {
    const twice = await makeCertificate({
      name: "Twice",
      curve: "P-256",
      extensions: [appleOids.leaf, appleOids.leaf],
    });
    expect(readCertificate(twice.der)).toBeUndefined();
  });

  it("reads ECDSA with SHA-256", async () => {
    const signed = await makeCertificate({ name: "Short hash", curve: "P-256", hash: "SHA-256" });
    expect(certificateOf(signed).signatureHash).toBe("SHA-256");
  });
});

async function notBefore(tag: number, text: string): Promise<number | undefined> {
  const made = await makeCertificate({
    name: "Dated",
    curve: "P-256",
    notBeforeTime: { tag, text },
  });
  return readCertificate(made.der)?.notBefore;
}

describe("reading a certificate's time", () => {
  it.each([
    [0x17, "491231235959Z", Date.UTC(2049, 11, 31, 23, 59, 59)],
    [0x17, "500101000000Z", Date.UTC(1950, 0, 1)],
    [0x18, "20501231235959Z", Date.UTC(2050, 11, 31, 23, 59, 59)],
  ])("reads %#: %s", async (tag, text, time) => {
    expect(await notBefore(tag, text)).toBe(time);
  });

  it.each([
    [0x17, "990230000000Z"],
    [0x17, "991301000000Z"],
    [0x17, "990101240000Z"],
    [0x17, "990101006000Z"],
    [0x17, "990101000060Z"],
    [0x17, "x991231235959Z"],
    [0x17, "991231235959Zx"],
    [0x17, "991231235959+0000"],
    [0x18, "x20991231235959Z"],
    [0x18, "20991231235959Zx"],
    [0x04, "991231235959Z"],
  ])("gives nothing for tag %i and %s", async (tag, text) => {
    expect(await notBefore(tag, text)).toBeUndefined();
  });
});

const bytes = (count: number, fill: number) => new Uint8Array(count).fill(fill);

describe("an ECDSA signature from DER", () => {
  it("pads short numbers and strips the sign byte", () => {
    const raw = rawSignature(sequence(integer(bytes(31, 0x11)), integer(bytes(32, 0x80))), "P-256");
    expect(raw).toEqual(concat(Uint8Array.of(0), bytes(31, 0x11), bytes(32, 0x80)));
  });

  it("reads a P-384 signature as 96 bytes", () => {
    expect(
      rawSignature(sequence(integer(bytes(48, 0x22)), integer(bytes(48, 0x33))), "P-384"),
    ).toEqual(concat(bytes(48, 0x22), bytes(48, 0x33)));
  });

  it.each([
    ["three numbers", sequence(integer(bytes(32, 1)), integer(bytes(32, 1)), integer(bytes(1, 1)))],
    ["a number that isn't an INTEGER", sequence(tlv(0x04, bytes(32, 1)), integer(bytes(32, 1)))],
    ["a negative number", sequence(tlv(0x02, bytes(32, 0xff)), integer(bytes(32, 1)))],
    ["a number too long for the curve", sequence(integer(bytes(33, 1)), integer(bytes(32, 1)))],
    ["something that isn't a SEQUENCE", tlv(0x31, integer(bytes(32, 1)), integer(bytes(32, 1)))],
  ])("gives nothing with %s", (_, der) => {
    expect(rawSignature(der, "P-256")).toBeUndefined();
  });
});

describe("comparing bytes", () => {
  it.each([
    [[1, 2], [1, 2], true],
    [[1, 2], [1, 3], false],
    [[1, 2], [1, 2, 3], false],
    [[1, 2, 3], [1, 2], false],
  ])("%j and %j are equal: %s", (left, right, equal) => {
    expect(equalBytes(Uint8Array.from(left), Uint8Array.from(right))).toBe(equal);
  });
});
