/**
 * Reads the parts of an X.509 certificate (RFC 5280) that checking an x5c chain needs, from DER.
 * Every read is bounds-checked; anything that isn't DER of the expected shape reads as undefined.
 */

/** One DER element: its tag, its contents, and the whole element as it was encoded. */
type Element = {
  readonly tag: number;
  readonly contents: Uint8Array;
  readonly encoded: Uint8Array;
};

const tags = {
  boolean: 0x01,
  integer: 0x02,
  bitString: 0x03,
  octetString: 0x04,
  oid: 0x06,
  utcTime: 0x17,
  generalizedTime: 0x18,
  sequence: 0x30,
  explicit0: 0xa0,
  explicit3: 0xa3,
} as const;

function readElement(bytes: Uint8Array, offset: number): Element | undefined {
  const tag = bytes[offset];
  const first = bytes[offset + 1];
  if (tag === undefined || first === undefined || (tag & 0x1f) === 0x1f) {
    return undefined;
  }
  let length = first;
  let start = offset + 2;
  if (first & 0x80) {
    const count = first & 0x7f;
    if (count === 0 || count > 3) {
      return undefined;
    }
    length = 0;
    for (let index = 0; index < count; index += 1) {
      const byte = bytes[start + index];
      if (byte === undefined) {
        return undefined;
      }
      length = length * 256 + byte;
    }
    start += count;
  }
  const end = start + length;
  if (end > bytes.length) {
    return undefined;
  }
  return { tag, contents: bytes.subarray(start, end), encoded: bytes.subarray(offset, end) };
}

/** The elements inside a constructed element's contents, in order. */
function children(contents: Uint8Array): Element[] | undefined {
  const found: Element[] = [];
  let offset = 0;
  while (offset < contents.length) {
    const element = readElement(contents, offset);
    if (element === undefined) {
      return undefined;
    }
    found.push(element);
    offset += element.encoded.length;
  }
  return found;
}

function whole(bytes: Uint8Array, tag: number): Element | undefined {
  const element = readElement(bytes, 0);
  return element?.tag === tag && element.encoded.length === bytes.length ? element : undefined;
}

function oidText(element: Element | undefined): string | undefined {
  if (element?.tag !== tags.oid || element.contents.length === 0) {
    return undefined;
  }
  const arcs: number[] = [];
  let value = 0;
  for (const byte of element.contents) {
    value = value * 128 + (byte & 0x7f);
    if (!(byte & 0x80)) {
      arcs.push(value);
      value = 0;
    }
  }
  const first = arcs.shift();
  if (first === undefined) {
    return undefined;
  }
  const top = Math.min(Math.floor(first / 40), 2);
  return [top, first - top * 40, ...arcs].join(".");
}

function timeOf(element: Element | undefined): number | undefined {
  if (element === undefined) {
    return undefined;
  }
  const text = new TextDecoder().decode(element.contents);
  const match =
    element.tag === tags.utcTime
      ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text)
      : element.tag === tags.generalizedTime
        ? /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text)
        : null;
  if (match === null) {
    return undefined;
  }
  const [year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0] = match
    .slice(1)
    .map(Number);
  const fullYear = element.tag === tags.utcTime ? (year < 50 ? 2000 : 1900) + year : year;
  const time = Date.UTC(fullYear, month - 1, day, hour, minute, second);
  const read = new Date(time);
  // Date.UTC rolls an impossible date such as month 13 over into a real one.
  return read.getUTCFullYear() === fullYear &&
    read.getUTCMonth() === month - 1 &&
    read.getUTCDate() === day &&
    read.getUTCHours() === hour &&
    read.getUTCMinutes() === minute &&
    read.getUTCSeconds() === second
    ? time
    : undefined;
}

export const oids = {
  ecPublicKey: "1.2.840.10045.2.1",
  p256: "1.2.840.10045.3.1.7",
  p384: "1.3.132.0.34",
  ecdsaWithSha256: "1.2.840.10045.4.3.2",
  ecdsaWithSha384: "1.2.840.10045.4.3.3",
  basicConstraints: "2.5.29.19",
} as const;

export type Curve = "P-256" | "P-384";

export type Certificate = {
  /** The signed part, as it was encoded: what the issuer's signature covers. */
  readonly signed: Uint8Array;
  readonly signatureHash: "SHA-256" | "SHA-384";
  /** The issuer's ECDSA signature, as the DER `SEQUENCE { r, s }` the certificate holds. */
  readonly signature: Uint8Array;
  /** The issuer's and subject's names, as encoded, compared byte for byte. */
  readonly issuer: Uint8Array;
  readonly subject: Uint8Array;
  readonly notBefore: number;
  readonly notAfter: number;
  /** The subject's SubjectPublicKeyInfo, as encoded, for `importKey("spki")`. */
  readonly publicKey: Uint8Array;
  readonly curve: Curve;
  /** Whether basicConstraints says the subject is a certificate authority. */
  readonly authority: boolean;
  readonly extensions: ReadonlySet<string>;
};

/** An ECDSA certificate on P-256 or P-384, signed with ECDSA; anything else reads as undefined. */
export function readCertificate(der: Uint8Array): Certificate | undefined {
  const certificate = children(whole(der, tags.sequence)?.contents ?? new Uint8Array());
  const [tbs, algorithm, signatureBits] = certificate ?? [];
  if (
    certificate?.length !== 3 ||
    tbs?.tag !== tags.sequence ||
    algorithm?.tag !== tags.sequence ||
    signatureBits?.tag !== tags.bitString ||
    signatureBits.contents[0] !== 0
  ) {
    return undefined;
  }
  const signatureHash = hashOf(oidText(children(algorithm.contents)?.[0]));
  const fields = children(tbs.contents);
  if (signatureHash === undefined || fields === undefined) {
    return undefined;
  }
  // version [0], serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo, then
  // the optional unique IDs [1] [2] and extensions [3].
  const [version, serial, innerAlgorithm, issuer, validity, subject, keyInfo, ...rest] = fields;
  if (
    version?.tag !== tags.explicit0 ||
    serial?.tag !== tags.integer ||
    innerAlgorithm === undefined ||
    !equalBytes(innerAlgorithm.encoded, algorithm.encoded) ||
    issuer?.tag !== tags.sequence ||
    validity?.tag !== tags.sequence ||
    subject?.tag !== tags.sequence ||
    keyInfo?.tag !== tags.sequence
  ) {
    return undefined;
  }
  const [notBefore, notAfter] = (children(validity.contents) ?? []).map(timeOf);
  const curve = curveOf(keyInfo);
  const extensions = extensionsOf(rest.find((element) => element.tag === tags.explicit3));
  if (
    notBefore === undefined ||
    notAfter === undefined ||
    curve === undefined ||
    extensions === undefined
  ) {
    return undefined;
  }
  return {
    signed: tbs.encoded,
    signatureHash,
    signature: signatureBits.contents.subarray(1),
    issuer: issuer.encoded,
    subject: subject.encoded,
    notBefore,
    notAfter,
    publicKey: keyInfo.encoded,
    curve,
    authority: extensions.authority,
    extensions: extensions.ids,
  };
}

function hashOf(oid: string | undefined): Certificate["signatureHash"] | undefined {
  return oid === oids.ecdsaWithSha256
    ? "SHA-256"
    : oid === oids.ecdsaWithSha384
      ? "SHA-384"
      : undefined;
}

function curveOf(keyInfo: Element): Curve | undefined {
  const [algorithm] = children(keyInfo.contents) ?? [];
  const [kind, parameter] =
    algorithm?.tag === tags.sequence ? (children(algorithm.contents) ?? []) : [];
  if (oidText(kind) !== oids.ecPublicKey) {
    return undefined;
  }
  const curve = oidText(parameter);
  return curve === oids.p256 ? "P-256" : curve === oids.p384 ? "P-384" : undefined;
}

function extensionsOf(
  wrapper: Element | undefined,
): { ids: ReadonlySet<string>; authority: boolean } | undefined {
  if (wrapper === undefined) {
    return { ids: new Set(), authority: false };
  }
  const [list] = children(wrapper.contents) ?? [];
  const extensions = list?.tag === tags.sequence ? children(list.contents) : undefined;
  if (extensions === undefined) {
    return undefined;
  }
  const ids = new Set<string>();
  let authority = false;
  for (const extension of extensions) {
    const parts = extension.tag === tags.sequence ? children(extension.contents) : undefined;
    const id = oidText(parts?.[0]);
    const value = parts?.at(-1);
    if (id === undefined || value?.tag !== tags.octetString || ids.has(id)) {
      return undefined;
    }
    ids.add(id);
    if (id === oids.basicConstraints) {
      const constraints = whole(value.contents, tags.sequence);
      const [flag] = constraints === undefined ? [] : (children(constraints.contents) ?? []);
      authority =
        flag?.tag === tags.boolean && flag.contents.length === 1 && flag.contents[0] !== 0;
    }
  }
  return { ids, authority };
}

/**
 * The raw `r || s` WebCrypto verifies, from the DER `SEQUENCE { r, s }` a certificate holds, each
 * number left-padded to the curve's size.
 */
export function rawSignature(der: Uint8Array, curve: Curve): Uint8Array | undefined {
  const size = curve === "P-256" ? 32 : 48;
  const parts = children(whole(der, tags.sequence)?.contents ?? new Uint8Array());
  if (parts?.length !== 2) {
    return undefined;
  }
  const raw = new Uint8Array(size * 2);
  for (const [index, part] of parts.entries()) {
    if (part.tag !== tags.integer || ((part.contents[0] ?? 0x80) & 0x80) !== 0) {
      return undefined;
    }
    let number = part.contents;
    while (number.length > 1 && number[0] === 0) {
      number = number.subarray(1);
    }
    if (number.length > size) {
      return undefined;
    }
    raw.set(number, size * (index + 1) - number.length);
  }
  return raw;
}

export function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  return left.length === right.length && left.every((byte, index) => byte === right[index]);
}
