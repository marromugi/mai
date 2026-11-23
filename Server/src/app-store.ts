import { isLowercaseUuid } from "./envelope";
import { equalBytes, rawSignature, readCertificate, type Certificate } from "./der";
import { base64Bytes, isJson, readCompactJws, text, whole, type Checked, type Json } from "./jws";

/**
 * Checks what the App Store signs — a StoreKit 2 transaction, its renewal info, and an App Store
 * Server Notification V2 — the way Apple's App Store Server Library does without online checks
 * (`jws_verification.ts` in apple/app-store-server-library-node): an ES256 JWS whose `x5c` is
 * leaf, intermediate, root; the intermediate signed by the pinned root and the leaf by the
 * intermediate, each carrying Apple's marker extension; every certificate valid at the payload's
 * `signedDate`. The `x5c` root itself is never trusted: only `expected.root` is.
 */

export type AppStoreFailure = "malformed" | "algorithm" | "chain" | "signature" | "bundle";

export type ExpectedSigner = {
  /** `appleRootCaG3` outside the tests. */
  readonly root: Certificate;
  readonly bundleId: string;
};

export type Environment = "Sandbox" | "Production";

export type Transaction = {
  readonly transactionId: string;
  readonly originalTransactionId: string;
  readonly productId: string;
  /** The UUID the app set at purchase, in lowercase; the account ID in this server. */
  readonly appAccountToken: string | undefined;
  readonly type: string;
  /** Times are milliseconds since 1970. */
  readonly purchaseDate: number;
  readonly expiresDate: number | undefined;
  readonly revocationDate: number | undefined;
  readonly environment: Environment;
  readonly signedDate: number;
};

export type RenewalInfo = {
  readonly originalTransactionId: string;
  readonly productId: string;
  readonly autoRenewProductId: string | undefined;
  readonly autoRenewStatus: boolean;
  readonly expirationIntent: number | undefined;
  readonly gracePeriodExpiresDate: number | undefined;
  readonly isInBillingRetryPeriod: boolean | undefined;
  readonly renewalDate: number | undefined;
  readonly appAccountToken: string | undefined;
  readonly environment: Environment;
  readonly signedDate: number;
};

export type Notification = {
  readonly notificationType: string;
  readonly subtype: string | undefined;
  readonly notificationUUID: string;
  readonly version: string;
  readonly signedDate: number;
  /** What `data` holds, for notifications about a transaction; undefined for the others. */
  readonly data:
    | {
        readonly environment: Environment;
        readonly transaction: Transaction | undefined;
        readonly renewalInfo: RenewalInfo | undefined;
      }
    | undefined;
};

/** Marks Apple puts on the certificates that sign App Store data. */
export const appleOids = {
  intermediate: "1.2.840.113635.100.6.2.1",
  leaf: "1.2.840.113635.100.6.11.1",
} as const;

/** How far a certificate's validity may miss `signedDate`, as Apple's library allows. */
const allowedSkew = 60 * 1000;

export async function verifyTransaction(
  jws: string,
  expected: ExpectedSigner,
): Promise<Checked<Transaction, AppStoreFailure>> {
  const payload = await verifySignedData(jws, expected.root);
  if (!payload.ok) {
    return payload;
  }
  const transaction = transactionOf(payload.value);
  if (transaction === undefined) {
    return { ok: false, failure: "malformed" };
  }
  if (transaction.bundleId !== expected.bundleId) {
    return { ok: false, failure: "bundle" };
  }
  return { ok: true, value: transaction.value };
}

/**
 * Renewal info names no app: a caller ties it to a verified transaction of this app by
 * `originalTransactionId`, as `verifyNotification` does by its outer `bundleId`.
 */
export async function verifyRenewalInfo(
  jws: string,
  expected: ExpectedSigner,
): Promise<Checked<RenewalInfo, AppStoreFailure>> {
  const payload = await verifySignedData(jws, expected.root);
  if (!payload.ok) {
    return payload;
  }
  const renewalInfo = renewalInfoOf(payload.value);
  return renewalInfo === undefined
    ? { ok: false, failure: "malformed" }
    : { ok: true, value: renewalInfo };
}

/** The `signedPayload` of a notification, and the transaction and renewal info inside it. */
export async function verifyNotification(
  signedPayload: string,
  expected: ExpectedSigner,
): Promise<Checked<Notification, AppStoreFailure>> {
  const payload = await verifySignedData(signedPayload, expected.root);
  if (!payload.ok) {
    return payload;
  }
  const outer = payload.value;
  const notificationType = text(outer["notificationType"]);
  const notificationUUID = text(outer["notificationUUID"]);
  const version = text(outer["version"]);
  const signedDate = whole(outer["signedDate"]);
  const subtype = optional(outer["subtype"], text);
  if (
    notificationType === undefined ||
    notificationUUID === undefined ||
    version === undefined ||
    signedDate === undefined ||
    subtype === null
  ) {
    return { ok: false, failure: "malformed" };
  }
  // A notification carries one of these, each naming the app it is for.
  const about = ["data", "summary", "externalPurchaseToken", "appData"]
    .map((field) => outer[field])
    .find(isJson);
  if (about === undefined) {
    return { ok: false, failure: "malformed" };
  }
  if (about["bundleId"] !== expected.bundleId) {
    return { ok: false, failure: "bundle" };
  }

  const notification = { notificationType, subtype, notificationUUID, version, signedDate };
  if (!isJson(outer["data"])) {
    return { ok: true, value: { ...notification, data: undefined } };
  }
  const data = outer["data"];
  const environment = environmentOf(data["environment"]);
  if (environment === undefined) {
    return { ok: false, failure: "malformed" };
  }
  const transaction = await insideOptional(data["signedTransactionInfo"], (jws) =>
    verifyTransaction(jws, expected),
  );
  if (!transaction.ok) {
    return transaction;
  }
  const renewalInfo = await insideOptional(data["signedRenewalInfo"], (jws) =>
    verifyRenewalInfo(jws, expected),
  );
  if (!renewalInfo.ok) {
    return renewalInfo;
  }
  return {
    ok: true,
    value: {
      ...notification,
      data: { environment, transaction: transaction.value, renewalInfo: renewalInfo.value },
    },
  };
}

async function insideOptional<T>(
  value: unknown,
  verify: (jws: string) => Promise<Checked<T, AppStoreFailure>>,
): Promise<Checked<T | undefined, AppStoreFailure>> {
  if (value === undefined) {
    return { ok: true, value: undefined };
  }
  return typeof value === "string" ? verify(value) : { ok: false, failure: "malformed" };
}

/** The payload of an App Store JWS whose chain and signature check out. */
async function verifySignedData(
  jwsText: string,
  root: Certificate,
): Promise<Checked<Json, AppStoreFailure>> {
  const jws = readCompactJws(jwsText);
  if (jws === undefined) {
    return { ok: false, failure: "malformed" };
  }
  if (jws.header["alg"] !== "ES256") {
    return { ok: false, failure: "algorithm" };
  }
  const x5c = jws.header["x5c"];
  if (!Array.isArray(x5c) || x5c.length !== 3) {
    return { ok: false, failure: "chain" };
  }
  const [leaf, intermediate] = x5c
    .slice(0, 2)
    .map((entry) =>
      typeof entry === "string"
        ? readCertificate(base64Bytes(entry) ?? new Uint8Array())
        : undefined,
    );
  const signedDate = whole(jws.payload["signedDate"]);
  if (leaf === undefined || intermediate === undefined) {
    return { ok: false, failure: "chain" };
  }
  if (signedDate === undefined) {
    return { ok: false, failure: "malformed" };
  }
  if (!(await chainHolds(leaf, intermediate, root, signedDate))) {
    return { ok: false, failure: "chain" };
  }
  const signature = jws.signature.length === 64 ? jws.signature : undefined;
  const key = await crypto.subtle.importKey(
    "spki",
    leaf.publicKey,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const signed =
    signature !== undefined &&
    (await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      signature,
      jws.signingInput,
    ));
  return signed ? { ok: true, value: jws.payload } : { ok: false, failure: "signature" };
}

async function chainHolds(
  leaf: Certificate,
  intermediate: Certificate,
  root: Certificate,
  at: number,
): Promise<boolean> {
  return (
    leaf.curve === "P-256" &&
    leaf.extensions.has(appleOids.leaf) &&
    intermediate.authority &&
    intermediate.extensions.has(appleOids.intermediate) &&
    [leaf, intermediate, root].every(
      (certificate) =>
        certificate.notBefore <= at + allowedSkew && at - allowedSkew <= certificate.notAfter,
    ) &&
    // The intermediate's key is only imported once the root has vouched for it.
    (await issued(intermediate, root)) &&
    (await issued(leaf, intermediate))
  );
}

/** Whether `issuer` signed `subject`: the names match and the signature verifies. */
export async function issued(subject: Certificate, issuer: Certificate): Promise<boolean> {
  const signature = rawSignature(subject.signature, issuer.curve);
  if (!equalBytes(subject.issuer, issuer.subject) || signature === undefined) {
    return false;
  }
  const key = await crypto.subtle.importKey(
    "spki",
    issuer.publicKey,
    { name: "ECDSA", namedCurve: issuer.curve },
    false,
    ["verify"],
  );
  return crypto.subtle.verify(
    { name: "ECDSA", hash: subject.signatureHash },
    key,
    signature,
    subject.signed,
  );
}

function transactionOf(
  payload: Json,
): { value: Transaction; bundleId: string | undefined } | undefined {
  const transactionId = text(payload["transactionId"]);
  const originalTransactionId = text(payload["originalTransactionId"]);
  const productId = text(payload["productId"]);
  const type = text(payload["type"]);
  const purchaseDate = whole(payload["purchaseDate"]);
  const signedDate = whole(payload["signedDate"]);
  const environment = environmentOf(payload["environment"]);
  const appAccountToken = optional(payload["appAccountToken"], uuid);
  const expiresDate = optional(payload["expiresDate"], whole);
  const revocationDate = optional(payload["revocationDate"], whole);
  if (
    transactionId === undefined ||
    originalTransactionId === undefined ||
    productId === undefined ||
    type === undefined ||
    purchaseDate === undefined ||
    signedDate === undefined ||
    environment === undefined ||
    appAccountToken === null ||
    expiresDate === null ||
    revocationDate === null
  ) {
    return undefined;
  }
  return {
    bundleId: text(payload["bundleId"]),
    value: {
      transactionId,
      originalTransactionId,
      productId,
      appAccountToken,
      type,
      purchaseDate,
      expiresDate,
      revocationDate,
      environment,
      signedDate,
    },
  };
}

function renewalInfoOf(payload: Json): RenewalInfo | undefined {
  const originalTransactionId = text(payload["originalTransactionId"]);
  const productId = text(payload["productId"]);
  const autoRenewStatus = whole(payload["autoRenewStatus"]);
  const signedDate = whole(payload["signedDate"]);
  const environment = environmentOf(payload["environment"]);
  const autoRenewProductId = optional(payload["autoRenewProductId"], text);
  const expirationIntent = optional(payload["expirationIntent"], whole);
  const gracePeriodExpiresDate = optional(payload["gracePeriodExpiresDate"], whole);
  const isInBillingRetryPeriod = optional(payload["isInBillingRetryPeriod"], flag);
  const renewalDate = optional(payload["renewalDate"], whole);
  const appAccountToken = optional(payload["appAccountToken"], uuid);
  if (
    originalTransactionId === undefined ||
    productId === undefined ||
    (autoRenewStatus !== 0 && autoRenewStatus !== 1) ||
    signedDate === undefined ||
    environment === undefined ||
    autoRenewProductId === null ||
    expirationIntent === null ||
    gracePeriodExpiresDate === null ||
    isInBillingRetryPeriod === null ||
    renewalDate === null ||
    appAccountToken === null
  ) {
    return undefined;
  }
  return {
    originalTransactionId,
    productId,
    autoRenewProductId,
    autoRenewStatus: autoRenewStatus === 1,
    expirationIntent,
    gracePeriodExpiresDate,
    isInBillingRetryPeriod,
    renewalDate,
    appAccountToken,
    environment,
    signedDate,
  };
}

/** A field that may be left out: undefined when it is, null when it is there but malformed. */
function optional<T>(
  value: unknown,
  read: (value: unknown) => T | undefined,
): T | undefined | null {
  return value === undefined ? undefined : (read(value) ?? null);
}

function environmentOf(value: unknown): Environment | undefined {
  return value === "Sandbox" || value === "Production" ? value : undefined;
}

function flag(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function uuid(value: unknown): string | undefined {
  const lowered = typeof value === "string" ? value.toLowerCase() : undefined;
  return lowered !== undefined && isLowercaseUuid(lowered) ? lowered : undefined;
}
