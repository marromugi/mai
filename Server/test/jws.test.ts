import { describe, expect, it } from "vitest";
import { base64Bytes, readCompactJws, text, whole } from "../src/jws";
import { base64url, concat } from "./apple-fakes";

const part = (value: string) => base64url(new TextEncoder().encode(value));
const header = part('{"alg":"ES256"}');
const payload = part('{"sub":"a"}');
const signature = part("signature");

describe("reading a compact JWS", () => {
  it("reads its header, payload, signature, and what the signature covers", () => {
    expect(readCompactJws(`${header}.${payload}.${signature}`)).toEqual({
      header: { alg: "ES256" },
      payload: { sub: "a" },
      signingInput: new TextEncoder().encode(`${header}.${payload}`),
      signature: new TextEncoder().encode("signature"),
    });
  });

  it("reads a header that starts with a byte order mark", () => {
    expect(readCompactJws(`${part('﻿{"alg":"ES256"}')}.${payload}.${signature}`)?.header).toEqual({
      alg: "ES256",
    });
  });

  it.each([
    ["four parts", `${header}.${payload}.${signature}.${signature}`],
    ["a header that isn't JSON", `${part("{alg")}.${payload}.${signature}`],
    ["a header that is a JSON array", `${part("[1]")}.${payload}.${signature}`],
    ["a header that is null", `${part("null")}.${payload}.${signature}`],
    ["a payload that is a JSON string", `${header}.${part('"a"')}.${signature}`],
    ["a payload that is a number", `${header}.${part("1")}.${signature}`],
    [
      "a header that isn't UTF-8",
      `${base64url(concat(new TextEncoder().encode('{"a":"'), Uint8Array.of(0xff), new TextEncoder().encode('"}')))}.${payload}.${signature}`,
    ],
    ["a header with a character outside base64url", `${header}+.${payload}.${signature}`],
    ["a payload with padding", `${header}.${payload}=.${signature}`],
    ["a signature with a character outside base64url", `${header}.${payload}.${signature}/`],
    ["a signature of impossible length", `${header}.${payload}.AAAAA`],
  ])("gives nothing with %s", (_, compact) => {
    expect(readCompactJws(compact)).toBeUndefined();
  });
});

describe("reading base64", () => {
  it.each([["!AAAA"], ["AAAA!"], ["AAA"], ["AA=A"]])("gives nothing for %j", (encoded) => {
    expect(base64Bytes(encoded)).toBeUndefined();
  });

  it("reads padded base64", () => {
    expect(base64Bytes("AAE=")).toEqual(Uint8Array.of(0, 1));
  });
});

describe("reading fields", () => {
  it.each([[""], [1], [null]])("reads %j as no text", (value) => {
    expect(text(value)).toBeUndefined();
  });

  it.each([[1.5], [2 ** 53], ["1"], [Number.NaN]])("reads %j as no whole number", (value) => {
    expect(whole(value)).toBeUndefined();
  });

  it("reads a whole number", () => {
    expect(whole(1_700_000_000_000)).toBe(1_700_000_000_000);
  });
});
