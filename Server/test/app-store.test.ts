import { beforeAll, describe, expect, it } from "vitest";
import { appleRootCaG3 } from "../src/apple-root";
import {
  appleOids,
  verifyNotification,
  verifyRenewalInfo,
  verifyTransaction,
  type ExpectedSigner,
} from "../src/app-store";
import { readCompactJws, type Json } from "../src/jws";
import {
  base64url,
  certificateOf,
  makeCertificate,
  makeChain,
  signAppStore,
  type Chain,
} from "./apple-fakes";

const bundleId = "dev.mai.app";
const accountId = "6f1c2b9e-3d4a-4b5c-8d6e-7f8091a2b3c4";
const signedDate = Date.now();
const day = 24 * 60 * 60 * 1000;

let chain: Chain;
let expected: ExpectedSigner;

beforeAll(async () => {
  chain = await makeChain();
  expected = { root: certificateOf(chain.root), bundleId };
});

function transaction(changes: Record<string, unknown> = {}) {
  return {
    transactionId: "2000000812345678",
    originalTransactionId: "2000000800000001",
    webOrderLineItemId: "2000000012345678",
    bundleId,
    productId: "dev.mai.plan.basic.monthly",
    subscriptionGroupIdentifier: "21500000",
    purchaseDate: signedDate - 1000,
    originalPurchaseDate: signedDate - 30 * day,
    expiresDate: signedDate + 30 * day,
    quantity: 1,
    type: "Auto-Renewable Subscription",
    appAccountToken: accountId.toUpperCase(),
    inAppOwnershipType: "PURCHASED",
    signedDate,
    environment: "Sandbox",
    transactionReason: "PURCHASE",
    storefront: "JPN",
    storefrontId: "143462",
    price: 480000,
    currency: "JPY",
    ...changes,
  };
}

function renewalInfo(changes: Record<string, unknown> = {}) {
  return {
    originalTransactionId: "2000000800000001",
    autoRenewProductId: "dev.mai.plan.basic.monthly",
    productId: "dev.mai.plan.basic.monthly",
    autoRenewStatus: 1,
    signedDate,
    environment: "Sandbox",
    recentSubscriptionStartDate: signedDate - 30 * day,
    renewalDate: signedDate + 30 * day,
    appAccountToken: accountId,
    ...changes,
  };
}

async function notification(
  changes: Record<string, unknown> = {},
  data: Record<string, unknown> = {},
) {
  return {
    notificationType: "DID_RENEW",
    notificationUUID: "a3b2c1d0-1111-4222-8333-944455556666",
    data: {
      appAppleId: 1234567890,
      bundleId,
      bundleVersion: "1",
      environment: "Sandbox",
      signedTransactionInfo: await signAppStore(transaction(), chain),
      signedRenewalInfo: await signAppStore(renewalInfo(), chain),
      status: 1,
      ...data,
    },
    version: "2.0",
    signedDate,
    ...changes,
  };
}

const decodedTransaction = {
  transactionId: "2000000812345678",
  originalTransactionId: "2000000800000001",
  productId: "dev.mai.plan.basic.monthly",
  appAccountToken: accountId,
  type: "Auto-Renewable Subscription",
  purchaseDate: signedDate - 1000,
  expiresDate: signedDate + 30 * day,
  revocationDate: undefined,
  environment: "Sandbox",
  signedDate,
};

const decodedRenewalInfo = {
  originalTransactionId: "2000000800000001",
  productId: "dev.mai.plan.basic.monthly",
  autoRenewProductId: "dev.mai.plan.basic.monthly",
  autoRenewStatus: true,
  expirationIntent: undefined,
  gracePeriodExpiresDate: undefined,
  isInBillingRetryPeriod: undefined,
  renewalDate: signedDate + 30 * day,
  appAccountToken: accountId,
  environment: "Sandbox",
  signedDate,
};

/** The JWS with its payload swapped for another, the signature kept. */
function withPayload(jws: string, payload: unknown): string {
  const [header, , signature] = jws.split(".");
  return `${header}.${base64url(new TextEncoder().encode(JSON.stringify(payload)))}.${signature}`;
}

function withHeader(jws: string, header: unknown): string {
  const [, payload, signature] = jws.split(".");
  return `${base64url(new TextEncoder().encode(JSON.stringify(header)))}.${payload}.${signature}`;
}

function headerOf(jws: string): Json {
  const read = readCompactJws(jws);
  if (read === undefined) {
    throw new Error("a JWS the test signed reads back");
  }
  return read.header;
}

describe("a signed transaction", () => {
  it("is accepted and decoded when signed under the expected root", async () => {
    expect(await verifyTransaction(await signAppStore(transaction(), chain), expected)).toEqual({
      ok: true,
      value: decodedTransaction,
    });
  });

  it("is decoded with what it leaves out as undefined", async () => {
    const jws = await signAppStore(
      transaction({ appAccountToken: undefined, expiresDate: undefined, type: "Non-Consumable" }),
      chain,
    );
    expect(await verifyTransaction(jws, expected)).toEqual({
      ok: true,
      value: {
        ...decodedTransaction,
        appAccountToken: undefined,
        expiresDate: undefined,
        type: "Non-Consumable",
      },
    });
  });

  it("is decoded with its revocation", async () => {
    const jws = await signAppStore(transaction({ revocationDate: signedDate - 10 }), chain);
    const verified = await verifyTransaction(jws, expected);
    expect(verified.ok && verified.value.revocationDate).toBe(signedDate - 10);
  });

  it("is turned down when its payload was changed after signing", async () => {
    const jws = await signAppStore(transaction(), chain);
    const changed = withPayload(jws, transaction({ expiresDate: signedDate + 3650 * day }));
    expect(await verifyTransaction(changed, expected)).toEqual({ ok: false, failure: "signature" });
  });

  it("is turned down when signed by a key that isn't the leaf certificate's", async () => {
    const stranger = await makeChain({ root: chain.root });
    const jws = await signAppStore(transaction(), {
      ...chain,
      leaf: { ...chain.leaf, keys: stranger.leaf.keys },
    });
    expect(await verifyTransaction(jws, expected)).toEqual({ ok: false, failure: "signature" });
  });

  it("is turned down when its chain ends at another root, even with that root in x5c", async () => {
    const other = await makeChain();
    expect(await verifyTransaction(await signAppStore(transaction(), other), expected)).toEqual({
      ok: false,
      failure: "chain",
    });
  });

  it("is turned down when x5c names the expected root but the intermediate isn't its", async () => {
    const other = await makeChain();
    const jws = await signAppStore(transaction(), { ...other, root: chain.root });
    expect(await verifyTransaction(jws, expected)).toEqual({ ok: false, failure: "chain" });
  });

  it("made with the test root is turned down under Apple Root CA - G3", async () => {
    const jws = await signAppStore(transaction(), chain);
    expect(await verifyTransaction(jws, { root: appleRootCaG3, bundleId })).toEqual({
      ok: false,
      failure: "chain",
    });
  });

  it.each([
    ["an intermediate without Apple's mark", { intermediate: { extensions: [] } }],
    ["a leaf without Apple's mark", { leaf: { extensions: [] } }],
    ["an intermediate that isn't a certificate authority", { intermediate: { authority: false } }],
    ["a P-384 leaf", { leaf: { curve: "P-384" as const } }],
    [
      "a leaf whose validity ended before it was signed",
      { leaf: { notAfter: signedDate - 2 * 60_000 } },
    ],
    ["a leaf not yet valid when it was signed", { leaf: { notBefore: signedDate + 2 * 60_000 } }],
    ["a leaf valid from a day no calendar has", { leaf: { notBeforeText: "991399999999Z" } }],
    [
      "an intermediate whose validity ended before it was signed",
      { intermediate: { notAfter: signedDate - 2 * 60_000 } },
    ],
  ])("is turned down with %s", async (_, changes) => {
    const other = await makeChain({ root: chain.root, ...changes });
    expect(await verifyTransaction(await signAppStore(transaction(), other), expected)).toEqual({
      ok: false,
      failure: "chain",
    });
  });

  it("is turned down when its leaf is signed directly by the root", async () => {
    const leaf = await makeCertificate({
      name: "Test Signer",
      curve: "P-256",
      issuer: chain.root,
      extensions: [appleOids.leaf],
    });
    const jws = await signAppStore(transaction(), { ...chain, leaf });
    expect(await verifyTransaction(jws, expected)).toEqual({ ok: false, failure: "chain" });
  });

  it.each([
    ["two certificates", (x5c: unknown[]) => x5c.slice(0, 2)],
    ["four certificates", (x5c: unknown[]) => [...x5c, x5c[2]]],
    ["no x5c", () => undefined],
    ["a certificate that isn't base64", (x5c: unknown[]) => ["%%%", ...x5c.slice(1)]],
    ["a certificate cut short", (x5c: unknown[]) => [String(x5c[0]).slice(0, 40), ...x5c.slice(1)]],
  ])("is turned down with %s in x5c", async (_, change) => {
    const jws = await signAppStore(transaction(), chain);
    const header = headerOf(jws);
    const changed = withHeader(jws, {
      ...header,
      x5c: change(Array.isArray(header["x5c"]) ? header["x5c"] : []),
    });
    expect(await verifyTransaction(changed, expected)).toEqual({ ok: false, failure: "chain" });
  });

  it.each([["RS256"], ["none"], ["ES384"]])(
    "is turned down when its header names %s",
    async (alg) => {
      const jws = await signAppStore(transaction(), chain, { alg });
      expect(await verifyTransaction(jws, expected)).toEqual({ ok: false, failure: "algorithm" });
    },
  );

  it("is turned down when it is for another app", async () => {
    const jws = await signAppStore(transaction({ bundleId: "dev.mai.other" }), chain);
    expect(await verifyTransaction(jws, expected)).toEqual({ ok: false, failure: "bundle" });
  });

  it.each([
    ["no signedDate", { signedDate: undefined }],
    ["no originalTransactionId", { originalTransactionId: undefined }],
    ["an appAccountToken that isn't a UUID", { appAccountToken: "account-1" }],
    ["an expiresDate that isn't a number", { expiresDate: "2027-01-01" }],
    ["an environment Apple doesn't sign in", { environment: "Xcode" }],
  ])("is turned down with %s", async (_, change) => {
    const jws = await signAppStore(transaction(change), chain);
    expect(await verifyTransaction(jws, expected)).toEqual({ ok: false, failure: "malformed" });
  });
});

describe("signed renewal info", () => {
  it("is accepted and decoded when signed under the expected root", async () => {
    expect(await verifyRenewalInfo(await signAppStore(renewalInfo(), chain), expected)).toEqual({
      ok: true,
      value: decodedRenewalInfo,
    });
  });

  it("is decoded with a billing retry and grace period", async () => {
    const jws = await signAppStore(
      renewalInfo({
        autoRenewStatus: 0,
        expirationIntent: 2,
        isInBillingRetryPeriod: true,
        gracePeriodExpiresDate: signedDate + 6 * day,
      }),
      chain,
    );
    expect(await verifyRenewalInfo(jws, expected)).toEqual({
      ok: true,
      value: {
        ...decodedRenewalInfo,
        autoRenewStatus: false,
        expirationIntent: 2,
        isInBillingRetryPeriod: true,
        gracePeriodExpiresDate: signedDate + 6 * day,
      },
    });
  });

  it("is turned down when its payload was changed after signing", async () => {
    const jws = await signAppStore(renewalInfo(), chain);
    const changed = withPayload(jws, renewalInfo({ autoRenewStatus: 0 }));
    expect(await verifyRenewalInfo(changed, expected)).toEqual({ ok: false, failure: "signature" });
  });

  it("is turned down when its chain ends at another root", async () => {
    const jws = await signAppStore(renewalInfo(), await makeChain());
    expect(await verifyRenewalInfo(jws, expected)).toEqual({ ok: false, failure: "chain" });
  });

  it("is turned down with an autoRenewStatus that isn't 0 or 1", async () => {
    const jws = await signAppStore(renewalInfo({ autoRenewStatus: 2 }), chain);
    expect(await verifyRenewalInfo(jws, expected)).toEqual({ ok: false, failure: "malformed" });
  });
});

describe("an App Store Server Notification", () => {
  it("is accepted with the transaction and renewal info inside it decoded", async () => {
    const jws = await signAppStore(await notification(), chain);
    expect(await verifyNotification(jws, expected)).toEqual({
      ok: true,
      value: {
        notificationType: "DID_RENEW",
        subtype: undefined,
        notificationUUID: "a3b2c1d0-1111-4222-8333-944455556666",
        version: "2.0",
        signedDate,
        data: {
          environment: "Sandbox",
          transaction: decodedTransaction,
          renewalInfo: decodedRenewalInfo,
        },
      },
    });
  });

  it("is accepted without renewal info, as for a one-time purchase", async () => {
    const jws = await signAppStore(
      await notification({ notificationType: "REFUND" }, { signedRenewalInfo: undefined }),
      chain,
    );
    const verified = await verifyNotification(jws, expected);
    expect(verified.ok && verified.value.data).toEqual({
      environment: "Sandbox",
      transaction: decodedTransaction,
      renewalInfo: undefined,
    });
  });

  it("is accepted with a subtype", async () => {
    const jws = await signAppStore(
      await notification({ notificationType: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD" }),
      chain,
    );
    const verified = await verifyNotification(jws, expected);
    expect(verified.ok && verified.value.subtype).toBe("GRACE_PERIOD");
  });

  it("is accepted with a summary in place of data", async () => {
    const payload = await notification({
      notificationType: "RENEWAL_EXTENSION",
      subtype: "SUMMARY",
      data: undefined,
      summary: { bundleId, environment: "Sandbox", requestIdentifier: "r1", succeededCount: 3 },
    });
    const verified = await verifyNotification(await signAppStore(payload, chain), expected);
    expect(verified.ok && verified.value.data).toBeUndefined();
  });

  it("is turned down when its payload was changed after signing", async () => {
    const jws = await signAppStore(await notification(), chain);
    const changed = withPayload(jws, await notification({ notificationType: "SUBSCRIBED" }));
    expect(await verifyNotification(changed, expected)).toEqual({
      ok: false,
      failure: "signature",
    });
  });

  it("is turned down when its chain ends at another root", async () => {
    const jws = await signAppStore(await notification(), await makeChain());
    expect(await verifyNotification(jws, expected)).toEqual({ ok: false, failure: "chain" });
  });

  it("is turned down when the transaction inside it was signed under another root", async () => {
    const stranger = await makeChain();
    const jws = await signAppStore(
      await notification(
        {},
        { signedTransactionInfo: await signAppStore(transaction(), stranger) },
      ),
      chain,
    );
    expect(await verifyNotification(jws, expected)).toEqual({ ok: false, failure: "chain" });
  });

  it("is turned down when the renewal info inside it was changed after signing", async () => {
    const inner = await signAppStore(renewalInfo(), chain);
    const jws = await signAppStore(
      await notification(
        {},
        { signedRenewalInfo: withPayload(inner, renewalInfo({ productId: "x" })) },
      ),
      chain,
    );
    expect(await verifyNotification(jws, expected)).toEqual({ ok: false, failure: "signature" });
  });

  it("is turned down when it is for another app", async () => {
    const jws = await signAppStore(await notification({}, { bundleId: "dev.mai.other" }), chain);
    expect(await verifyNotification(jws, expected)).toEqual({ ok: false, failure: "bundle" });
  });

  it("is turned down when the transaction inside it is for another app", async () => {
    const inner = await signAppStore(transaction({ bundleId: "dev.mai.other" }), chain);
    const jws = await signAppStore(await notification({}, { signedTransactionInfo: inner }), chain);
    expect(await verifyNotification(jws, expected)).toEqual({ ok: false, failure: "bundle" });
  });

  it.each([
    ["no notificationType", { notificationType: undefined }],
    ["no data or summary", { data: undefined }],
    ["no signedDate", { signedDate: undefined }],
  ])("is turned down with %s", async (_, change) => {
    const jws = await signAppStore(await notification(change), chain);
    expect(await verifyNotification(jws, expected)).toEqual({ ok: false, failure: "malformed" });
  });
});
