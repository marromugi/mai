import { appleOids } from "../src/app-store";
import { oids, readCertificate, type Certificate, type Curve } from "../src/der";
import { base64url } from "../src/jws";

export { base64url };

/**
 * Stand-ins for Apple made in the tests: a certificate authority standing in for Apple Root CA -
 * G3, App Store chains under it, and Sign in with Apple keys served as a JWKS.
 */

function length(count: number): number[] {
  if (count < 0x80) {
    return [count];
  }
  const bytes: number[] = [];
  for (let rest = count; rest > 0; rest = Math.floor(rest / 256)) {
    bytes.unshift(rest % 256);
  }
  return [0x80 | bytes.length, ...bytes];
}

export function tlv(tag: number, ...parts: Uint8Array[]): Uint8Array {
  const contents = concat(...parts);
  return concat(Uint8Array.of(tag, ...length(contents.length)), contents);
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const joined = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    joined.set(part, offset);
    offset += part.length;
  }
  return joined;
}

export const sequence = (...parts: Uint8Array[]) => tlv(0x30, ...parts);

function oid(text: string): Uint8Array {
  const [first = 0, second = 0, ...rest] = text.split(".").map(Number);
  const bytes = [first * 40 + second];
  for (const arc of rest) {
    const groups = [arc % 128];
    for (let high = Math.floor(arc / 128); high > 0; high = Math.floor(high / 128)) {
      groups.unshift(0x80 | (high % 128));
    }
    bytes.push(...groups);
  }
  return tlv(0x06, Uint8Array.from(bytes));
}

export function integer(bytes: Uint8Array): Uint8Array {
  let start = 0;
  while (start < bytes.length - 1 && bytes[start] === 0) {
    start += 1;
  }
  const trimmed = bytes.subarray(start);
  return tlv(0x02, (trimmed[0] ?? 0) & 0x80 ? concat(Uint8Array.of(0), trimmed) : trimmed);
}

function name(commonName: string): Uint8Array {
  const attribute = sequence(oid("2.5.4.3"), tlv(0x0c, new TextEncoder().encode(commonName)));
  return sequence(tlv(0x31, attribute));
}

function time(milliseconds: number): Uint8Array {
  const iso = new Date(milliseconds).toISOString().replace(/[-:T]/g, "").slice(0, 14);
  const year = new Date(milliseconds).getUTCFullYear();
  return year < 2050
    ? tlv(0x17, new TextEncoder().encode(`${iso.slice(2)}Z`))
    : tlv(0x18, new TextEncoder().encode(`${iso}Z`));
}

function extension(id: string, value: Uint8Array): Uint8Array {
  return sequence(oid(id), tlv(0x04, value));
}

const keyParameters = (curve: Curve) => ({ name: "ECDSA", namedCurve: curve });

function keyPair(made: CryptoKey | CryptoKeyPair): CryptoKeyPair {
  if (!("privateKey" in made)) {
    throw new Error("an asymmetric algorithm makes a key pair");
  }
  return made;
}

function buffer(exported: ArrayBuffer | JsonWebKey): ArrayBuffer {
  if (!(exported instanceof ArrayBuffer)) {
    throw new Error("a key exported as SPKI is bytes");
  }
  return exported;
}

export type Issued = {
  readonly der: Uint8Array;
  readonly name: string;
  readonly keys: CryptoKeyPair;
  readonly curve: Curve;
};

export type CertificateOptions = {
  readonly name: string;
  readonly curve: Curve;
  /** Signs the certificate; the certificate signs itself when left out. */
  readonly issuer?: Issued;
  /** `"stated-false"` writes basicConstraints with `cA` set to FALSE, rather than leaving it out. */
  readonly authority?: boolean | "stated-false";
  readonly extensions?: readonly string[];
  readonly notBefore?: number;
  readonly notAfter?: number;
  /** A time written as is in place of `notBefore`: its tag (UTCTime 0x17) and its text. */
  readonly notBeforeTime?: { readonly tag: number; readonly text: string };
  /** The issuer's name as the certificate writes it, when it isn't the issuer's own. */
  readonly issuerName?: string;
  /** What the issuer hashes as it signs; SHA-384 when left out. */
  readonly hash?: "SHA-256" | "SHA-384";
};

const year = 365 * 24 * 60 * 60 * 1000;

export async function makeCertificate(options: CertificateOptions): Promise<Issued> {
  const keys = keyPair(
    await crypto.subtle.generateKey(keyParameters(options.curve), true, ["sign", "verify"]),
  );
  const issuerName = options.issuerName ?? options.issuer?.name ?? options.name;
  const hash = options.hash ?? "SHA-384";
  const signingKey = options.issuer?.keys.privateKey ?? keys.privateKey;
  const signingCurve = options.issuer?.curve ?? options.curve;
  const now = Date.now();
  const algorithm = sequence(oid(hash === "SHA-256" ? oids.ecdsaWithSha256 : oids.ecdsaWithSha384));
  const extensions = [
    ...(options.authority === true || options.authority === "stated-false"
      ? [
          extension(
            oids.basicConstraints,
            sequence(tlv(0x01, Uint8Array.of(options.authority === true ? 0xff : 0x00))),
          ),
        ]
      : []),
    ...(options.extensions ?? []).map((id) => extension(id, Uint8Array.of(0x05, 0x00))),
  ];
  const signed = sequence(
    tlv(0xa0, integer(Uint8Array.of(2))),
    integer(crypto.getRandomValues(new Uint8Array(8))),
    algorithm,
    name(issuerName),
    sequence(
      options.notBeforeTime === undefined
        ? time(options.notBefore ?? now - year)
        : tlv(options.notBeforeTime.tag, new TextEncoder().encode(options.notBeforeTime.text)),
      time(options.notAfter ?? now + year),
    ),
    name(options.name),
    new Uint8Array(buffer(await crypto.subtle.exportKey("spki", keys.publicKey))),
    ...(extensions.length > 0 ? [tlv(0xa3, sequence(...extensions))] : []),
  );
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash }, signingKey, signed));
  const half = signingCurve === "P-256" ? 32 : 48;
  const signature = sequence(integer(raw.subarray(0, half)), integer(raw.subarray(half)));
  const der = sequence(signed, algorithm, tlv(0x03, Uint8Array.of(0), signature));
  return { der, name: options.name, keys, curve: options.curve };
}

/** The certificate as the server reads it, for a test certificate made to be readable. */
export function certificateOf(issued: Issued): Certificate {
  const certificate = readCertificate(issued.der);
  if (certificate === undefined) {
    throw new Error(`the test certificate ${issued.name} reads back`);
  }
  return certificate;
}

export type Chain = { readonly root: Issued; readonly intermediate: Issued; readonly leaf: Issued };

/** A chain shaped like Apple's: a P-384 root and intermediate, and a P-256 leaf. */
export async function makeChain(
  changes: {
    root?: Issued;
    intermediate?: Partial<CertificateOptions>;
    leaf?: Partial<CertificateOptions>;
  } = {},
): Promise<Chain> {
  const root =
    changes.root ??
    (await makeCertificate({ name: "Test Root CA", curve: "P-384", authority: true }));
  const intermediate = await makeCertificate({
    name: "Test Intermediate CA",
    curve: "P-384",
    issuer: root,
    authority: true,
    extensions: [appleOids.intermediate],
    ...changes.intermediate,
  });
  const leaf = await makeCertificate({
    name: "Test Signer",
    curve: "P-256",
    issuer: intermediate,
    extensions: [appleOids.leaf],
    ...changes.leaf,
  });
  return { root, intermediate, leaf };
}

function base64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}

function jsonPart(value: unknown): string {
  return base64url(new TextEncoder().encode(JSON.stringify(value)));
}

/** An App Store JWS signed by the chain's leaf, with the chain in `x5c`. */
export async function signAppStore(
  payload: unknown,
  chain: Chain,
  header: Record<string, unknown> = {},
): Promise<string> {
  const input = `${jsonPart({
    alg: "ES256",
    x5c: [chain.leaf.der, chain.intermediate.der, chain.root.der].map(base64),
    ...header,
  })}.${jsonPart(payload)}`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    chain.leaf.keys.privateKey,
    new TextEncoder().encode(input),
  );
  return `${input}.${base64url(new Uint8Array(signature))}`;
}

export type SignInKey = { readonly kid: string; readonly keys: CryptoKeyPair };

export async function makeSignInKey(kid: string): Promise<SignInKey> {
  const keys = keyPair(
    await crypto.subtle.generateKey(
      {
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 2048,
        publicExponent: Uint8Array.of(1, 0, 1),
        hash: "SHA-256",
      },
      true,
      ["sign", "verify"],
    ),
  );
  return { kid, keys };
}

/** A JWKS body as https://appleid.apple.com/auth/keys answers. */
export async function jwks(keys: readonly SignInKey[]): Promise<string> {
  const entries = await Promise.all(
    keys.map(async ({ kid, keys: pair }) => {
      const exported = await crypto.subtle.exportKey("jwk", pair.publicKey);
      if (exported instanceof ArrayBuffer) {
        throw new Error("a key exported as a JWK is a JWK");
      }
      const { n, e } = exported;
      return { kty: "RSA", kid, use: "sig", alg: "RS256", n, e };
    }),
  );
  return JSON.stringify({ keys: entries });
}

export async function signIdentityToken(
  claims: Record<string, unknown>,
  key: SignInKey,
  header: Record<string, unknown> = {},
): Promise<string> {
  const input = `${jsonPart({ kid: key.kid, alg: "RS256", ...header })}.${jsonPart(claims)}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key.keys.privateKey,
    new TextEncoder().encode(input),
  );
  return `${input}.${base64url(new Uint8Array(signature))}`;
}
