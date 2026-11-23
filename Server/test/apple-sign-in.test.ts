import { beforeAll, describe, expect, it } from "vitest";
import {
  AppleSignInKeys,
  appleIssuer,
  appleKeysUrl,
  keysLifetime,
  refetchGap,
  verifyIdentityToken,
} from "../src/apple-sign-in";
import { isJson } from "../src/jws";
import { base64url, jwks, makeSignInKey, signIdentityToken, type SignInKey } from "./apple-fakes";

const bundleId = "dev.mai.app";
const nonce = "4f2c0a9e1d7b6c5a8e3f2d1c0b9a8e7f6d5c4b3a2918f7e6d5c4b3a2918f7e6d";
const now = Date.UTC(2026, 10, 23, 12);

let signer: SignInKey;
let other: SignInKey;

beforeAll(async () => {
  signer = await makeSignInKey("test-key-1");
  other = await makeSignInKey("test-key-2");
});

/** Apple's keys endpoint, served from the test, counting how often it is asked. */
function fakeApple(serving: () => Promise<string>) {
  const asked: string[] = [];
  const fetchKeys = async (url: string) => {
    asked.push(url);
    return new Response(await serving(), { headers: { "Content-Type": "application/json" } });
  };
  return { asked, fetchKeys };
}

async function freshKeys(serving: () => Promise<string>) {
  const apple = fakeApple(serving);
  const keys = new AppleSignInKeys(apple.fetchKeys, await caches.open(crypto.randomUUID()));
  return { keys, asked: apple.asked };
}

function claims(changes: Record<string, unknown> = {}) {
  return {
    iss: appleIssuer,
    aud: bundleId,
    exp: Math.floor(now / 1000) + 600,
    iat: Math.floor(now / 1000),
    sub: "001234.abcdef0123456789abcdef0123456789.0123",
    nonce,
    nonce_supported: true,
    ...changes,
  };
}

describe("a Sign in with Apple ID token", () => {
  it("is accepted when signed with Apple's key and carrying what is expected", async () => {
    const { keys, asked } = await freshKeys(() => jwks([signer]));
    const token = await signIdentityToken(claims(), signer);

    expect(await verifyIdentityToken(token, { bundleId, nonce }, keys, now)).toEqual({
      ok: true,
      value: { sub: "001234.abcdef0123456789abcdef0123456789.0123" },
    });
    expect(asked).toEqual([appleKeysUrl]);
  });

  it.each([
    ["another issuer", { iss: "https://appleid.apple.com.example" }, "issuer"],
    ["another app's audience", { aud: "dev.mai.other" }, "audience"],
    ["an audience list", { aud: [bundleId] }, "audience"],
    ["a time that has passed", { exp: Math.floor(now / 1000) }, "expired"],
    ["another nonce", { nonce: nonce.replace("4f", "5f") }, "nonce"],
    ["no nonce", { nonce: undefined }, "nonce"],
    ["no subject", { sub: undefined }, "malformed"],
    ["an expiry that isn't a number", { exp: "soon" }, "malformed"],
  ])("is turned down with %s", async (_, change, failure) => {
    const { keys } = await freshKeys(() => jwks([signer]));
    const token = await signIdentityToken(claims(change), signer);

    expect(await verifyIdentityToken(token, { bundleId, nonce }, keys, now)).toEqual({
      ok: false,
      failure,
    });
  });

  it("is turned down when signed by a key that isn't the one its key ID names", async () => {
    const { keys } = await freshKeys(() => jwks([signer, other]));
    const token = await signIdentityToken(claims(), other, { kid: signer.kid });

    expect(await verifyIdentityToken(token, { bundleId, nonce }, keys, now)).toEqual({
      ok: false,
      failure: "signature",
    });
  });

  it("is turned down when its claims were changed after signing", async () => {
    const { keys } = await freshKeys(() => jwks([signer]));
    const [header, , signature] = (await signIdentityToken(claims(), signer)).split(".");
    const changed = base64url(new TextEncoder().encode(JSON.stringify(claims({ sub: "someone" }))));

    expect(
      await verifyIdentityToken(
        `${header}.${changed}.${signature}`,
        { bundleId, nonce },
        keys,
        now,
      ),
    ).toEqual({ ok: false, failure: "signature" });
  });

  it.each([
    ["ES256", { alg: "ES256" }],
    ["no algorithm", { alg: "none" }],
    ["HS256", { alg: "HS256" }],
  ])("is turned down when its header names %s", async (_, header) => {
    const { keys, asked } = await freshKeys(() => jwks([signer]));
    const token = await signIdentityToken(claims(), signer, header);

    expect(await verifyIdentityToken(token, { bundleId, nonce }, keys, now)).toEqual({
      ok: false,
      failure: "algorithm",
    });
    expect(asked).toEqual([]);
  });

  it.each([["not.a.token"], ["two.parts"], [""], ["a.b.c.d"]])(
    "is turned down when it is %j",
    async (token) => {
      const { keys } = await freshKeys(() => jwks([signer]));
      expect(await verifyIdentityToken(token, { bundleId, nonce }, keys, now)).toEqual({
        ok: false,
        failure: "malformed",
      });
    },
  );
});

describe("Apple's keys", () => {
  it("are fetched once and kept for a day", async () => {
    const { keys, asked } = await freshKeys(() => jwks([signer]));
    const token = await signIdentityToken(
      claims({ exp: Math.floor(now / 1000) + 2 * 86400 }),
      signer,
    );

    for (const at of [now, now + keysLifetime - 1]) {
      expect((await verifyIdentityToken(token, { bundleId, nonce }, keys, at)).ok).toBe(true);
    }
    expect(asked).toHaveLength(1);
    expect(
      (await verifyIdentityToken(token, { bundleId, nonce }, keys, now + keysLifetime)).ok,
    ).toBe(true);
    expect(asked).toHaveLength(2);
  });

  it("are fetched again once for a key ID the kept copy lacks, and the token is then accepted", async () => {
    let serving = [signer];
    const { keys, asked } = await freshKeys(() => jwks(serving));
    const later = now + refetchGap;
    await keys.key(signer.kid, now);
    serving = [signer, other];
    const token = await signIdentityToken(claims({ exp: Math.floor(later / 1000) + 600 }), other);

    expect((await verifyIdentityToken(token, { bundleId, nonce }, keys, later)).ok).toBe(true);
    expect(asked).toHaveLength(2);
  });

  it("are fetched again only once for a key ID Apple doesn't have", async () => {
    const { keys, asked } = await freshKeys(() => jwks([signer]));
    const later = now + refetchGap;
    await keys.key(signer.kid, now);
    const token = await signIdentityToken(claims({ exp: Math.floor(later / 1000) + 600 }), other);

    expect(await verifyIdentityToken(token, { bundleId, nonce }, keys, later)).toEqual({
      ok: false,
      failure: "unknown-key",
    });
    expect(asked).toHaveLength(2);
  });

  it("aren't fetched again for an unknown key ID sooner than the gap after the last fetch", async () => {
    const { keys, asked } = await freshKeys(() => jwks([signer]));
    await keys.key(signer.kid, now);

    for (const at of [now, now + refetchGap - 1]) {
      expect(await keys.key(other.kid, at)).toEqual({ ok: false, failure: "unknown-key" });
    }
    expect(asked).toHaveLength(1);
  });

  it("are kept for whoever reads the same cache next", async () => {
    const cache = await caches.open(crypto.randomUUID());
    const first = fakeApple(() => jwks([signer]));
    const second = fakeApple(() => jwks([signer]));
    await new AppleSignInKeys(first.fetchKeys, cache).key(signer.kid, now);

    expect((await new AppleSignInKeys(second.fetchKeys, cache).key(signer.kid, now + 1)).ok).toBe(
      true,
    );
    expect(second.asked).toEqual([]);
  });

  it.each([
    ["answers with an error", async () => new Response("down", { status: 503 })],
    ["answers with something that isn't a JWKS", async () => new Response("<html>")],
    [
      "can't be reached",
      async (): Promise<Response> => {
        throw new TypeError("Network connection lost.");
      },
    ],
  ])("are unavailable when Apple %s", async (_, fetchKeys) => {
    const keys = new AppleSignInKeys(fetchKeys, await caches.open(crypto.randomUUID()));
    expect(await keys.key(signer.kid, now)).toEqual({ ok: false, failure: "keys-unavailable" });
  });

  it("aren't fetched again sooner than the gap after a fetch that failed", async () => {
    let up = true;
    const { keys, asked } = await freshKeys(async () => {
      if (!up) {
        throw new TypeError("Network connection lost.");
      }
      return jwks([signer]);
    });
    await keys.key(signer.kid, now);
    up = false;

    for (const at of [now + refetchGap, now + refetchGap + 1, now + 2 * refetchGap - 1]) {
      expect(await keys.key(other.kid, at)).toEqual({ ok: false, failure: "unknown-key" });
    }
    expect(asked).toHaveLength(2);
    expect((await keys.key(signer.kid, now + 2 * refetchGap)).ok).toBe(true);
    await keys.key(other.kid, now + 2 * refetchGap);
    expect(asked).toHaveLength(3);
  });

  it("are unavailable when the key a token names won't import", async () => {
    const body = JSON.stringify({
      keys: [{ kty: "RSA", alg: "RS256", kid: signer.kid, n: "!!!", e: "AQAB" }],
    });
    const { keys } = await freshKeys(async () => body);
    const token = await signIdentityToken(claims(), signer);

    expect(await verifyIdentityToken(token, { bundleId, nonce }, keys, now)).toEqual({
      ok: false,
      failure: "keys-unavailable",
    });
  });

  it("leave out keys that aren't RS256", async () => {
    const body: unknown = JSON.parse(await jwks([signer]));
    const listed = isJson(body) && Array.isArray(body["keys"]) ? body["keys"] : [];
    const changed = JSON.stringify({
      keys: listed.filter(isJson).map((key) => ({ ...key, alg: "RS512" })),
    });
    const { keys } = await freshKeys(async () => changed);

    expect(await keys.key(signer.kid, now)).toEqual({ ok: false, failure: "unknown-key" });
  });
});

describe("an ID token without a key ID", () => {
  it("is malformed, and Apple isn't asked", async () => {
    const { keys, asked } = await freshKeys(() => jwks([signer]));
    const token = await signIdentityToken(claims(), signer, { kid: undefined });

    expect(await verifyIdentityToken(token, { bundleId, nonce }, keys, now)).toEqual({
      ok: false,
      failure: "malformed",
    });
    expect(asked).toEqual([]);
  });
});

/** A cache holding Apple's keys with the given headers, and keys reading it. */
async function keptWith(headers: Record<string, string>) {
  const cache = await caches.open(crypto.randomUUID());
  await cache.put(
    appleKeysUrl,
    new Response(await jwks([signer]), {
      headers: { "Cache-Control": `max-age=${keysLifetime / 1000}`, ...headers },
    }),
  );
  const apple = fakeApple(() => jwks([signer]));
  return { keys: new AppleSignInKeys(apple.fetchKeys, cache), asked: apple.asked };
}

describe("Apple's keys as kept", () => {
  it("count the gap from their fetch when no try is written", async () => {
    const { keys, asked } = await keptWith({ "Mai-Fetched": String(now) });

    expect(await keys.key(other.kid, now + 1)).toEqual({ ok: false, failure: "unknown-key" });
    expect(asked).toEqual([]);
  });

  it.each([
    ["a fetch time that isn't a number", { "Mai-Fetched": "soon" }],
    ["no fetch time", {}],
    ["a try time that isn't a number", { "Mai-Fetched": String(now), "Mai-Tried": "x" }],
  ])("are fetched again with %s", async (_, headers) => {
    const { keys, asked } = await keptWith(headers);

    expect((await keys.key(signer.kid, now)).ok).toBe(true);
    expect(asked).toHaveLength(1);
  });

  it("still last a day from their fetch after a fetch that failed", async () => {
    let up = true;
    const asked: string[] = [];
    const keys = new AppleSignInKeys(
      async (url) => {
        asked.push(url);
        return up ? new Response(await jwks([signer])) : new Response("down", { status: 503 });
      },
      await caches.open(crypto.randomUUID()),
    );
    await keys.key(signer.kid, now);
    up = false;
    await keys.key(other.kid, now + refetchGap);
    up = true;

    expect((await keys.key(signer.kid, now + keysLifetime)).ok).toBe(true);
    expect(asked).toHaveLength(3);
  });
});

async function keyFrom(body: unknown) {
  const { keys } = await freshKeys(async () => JSON.stringify(body));
  return keys.key(signer.kid, now);
}

async function signerEntry(): Promise<Record<string, unknown>> {
  const body: unknown = JSON.parse(await jwks([signer]));
  const [entry] = isJson(body) && Array.isArray(body["keys"]) ? body["keys"] : [];
  return isJson(entry) ? { ...entry } : {};
}

describe("Apple's JWKS", () => {
  it("is unavailable when Apple answers an error with a JWKS body", async () => {
    const body = await jwks([signer]);
    const keys = new AppleSignInKeys(
      async () => new Response(body, { status: 500 }),
      await caches.open(crypto.randomUUID()),
    );
    expect(await keys.key(signer.kid, now)).toEqual({ ok: false, failure: "keys-unavailable" });
  });

  it.each([
    ["keys that aren't a list", () => ({ keys: {} })],
    ["no keys", () => ({})],
    ["a list", () => []],
  ])("is unavailable with %s", async (_, body) => {
    expect(await keyFrom(body())).toEqual({ ok: false, failure: "keys-unavailable" });
  });

  it.each([
    ["another kty", { kty: "EC" }],
    ["no kid", { kid: undefined }],
    ["no n", { n: undefined }],
    ["no e", { e: undefined }],
  ])("leaves out an entry with %s", async (_, change) => {
    expect(await keyFrom({ keys: [{ ...(await signerEntry()), ...change }] })).toEqual({
      ok: false,
      failure: "unknown-key",
    });
  });

  it("reads past an entry that isn't an object", async () => {
    expect((await keyFrom({ keys: ["junk", await signerEntry()] })).ok).toBe(true);
  });
});
