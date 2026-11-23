import { parseAccountId } from "./account-id";
import {
  verifyNotification,
  verifyRenewalInfo,
  verifyTransaction,
  type AppStoreFailure,
  type Environment,
  type ExpectedSigner,
  type RenewalInfo,
  type Transaction,
} from "./app-store";
import { text, type Checked } from "./jws";
import { jsonBody, problem } from "./http";
import type { Kept, Purchase, Store } from "./store";

/**
 * Takes what the App Store signs about the account's subscription — from the app at account
 * creation and at each launch, and from App Store Server Notifications V2 — and keeps it in
 * `subscriptions`. What an account may do follows from it: see `accounts.paid_until` in
 * `Server/schema.sql`. Which notification it came in does not matter: the transaction and renewal
 * info say all of it.
 */

export type AppStore = {
  readonly signer: ExpectedSigner;
  /** `APP_STORE_ENVIRONMENTS`: whose purchases this server takes. */
  readonly environments: ReadonlySet<Environment>;
};

export type PurchaseFailure = AppStoreFailure | "environment" | "not-subscription" | "renewal-info";

/** `APP_STORE_ENVIRONMENTS`, `Production`, `Sandbox`, or both separated by a comma. */
export function parseEnvironments(value: string): ReadonlySet<Environment> {
  const environments = new Set<Environment>();
  for (const name of value.split(",").map((part) => part.trim())) {
    if (name !== "Production" && name !== "Sandbox") {
      throw new Error(
        `APP_STORE_ENVIRONMENTS holds "${name}"; it is Production, Sandbox, or both separated by a comma`,
      );
    }
    environments.add(name);
  }
  return environments;
}

/** A transaction the app sent, with its renewal info when the app sent that too. */
export async function readPurchase(
  transactionJws: string,
  renewalInfoJws: string | undefined,
  appStore: AppStore,
): Promise<Checked<Purchase, PurchaseFailure>> {
  const transaction = await verifyTransaction(transactionJws, appStore.signer);
  if (!transaction.ok) {
    return transaction;
  }
  let renewalInfo: RenewalInfo | undefined;
  if (renewalInfoJws !== undefined) {
    const checked = await verifyRenewalInfo(renewalInfoJws, appStore.signer);
    if (!checked.ok) {
      return checked;
    }
    renewalInfo = checked.value;
  }
  return purchaseOf(transaction.value, renewalInfo, transaction.value.signedDate, appStore);
}

/**
 * The subscription a notification is about; undefined for one about no subscription, such as
 * `TEST`.
 */
async function readNotification(
  signedPayload: string,
  appStore: AppStore,
): Promise<Checked<Purchase | undefined, PurchaseFailure>> {
  const notification = await verifyNotification(signedPayload, appStore.signer);
  if (!notification.ok) {
    return notification;
  }
  const data = notification.value.data;
  if (data?.transaction === undefined) {
    return { ok: true, value: undefined };
  }
  if (!appStore.environments.has(data.environment)) {
    return { ok: false, failure: "environment" };
  }
  const purchase = purchaseOf(
    data.transaction,
    data.renewalInfo,
    notification.value.signedDate,
    appStore,
  );
  if (!purchase.ok && purchase.failure === "not-subscription") {
    return { ok: true, value: undefined };
  }
  return purchase;
}

function purchaseOf(
  transaction: Transaction,
  renewalInfo: RenewalInfo | undefined,
  signedDate: number,
  appStore: AppStore,
): Checked<Purchase, PurchaseFailure> {
  if (!appStore.environments.has(transaction.environment)) {
    return { ok: false, failure: "environment" };
  }
  if (transaction.expiresDate === undefined) {
    return { ok: false, failure: "not-subscription" };
  }
  // Renewal info names no app; it counts only for the verified transaction it names.
  if (
    renewalInfo !== undefined &&
    (renewalInfo.originalTransactionId !== transaction.originalTransactionId ||
      renewalInfo.environment !== transaction.environment)
  ) {
    return { ok: false, failure: "renewal-info" };
  }
  return {
    ok: true,
    value: {
      originalTransactionId: transaction.originalTransactionId,
      account: parseAccountId(transaction.appAccountToken ?? ""),
      productId: transaction.productId,
      periodEnds: transaction.expiresDate,
      paidUntil:
        transaction.revocationDate ??
        Math.max(transaction.expiresDate, renewalInfo?.gracePeriodExpiresDate ?? 0),
      revoked: transaction.revocationDate !== undefined,
      environment: transaction.environment,
      signedDate,
    },
  };
}

const purchaseFailures: Record<PurchaseFailure, { status: number; reason: string }> = {
  malformed: { status: 400, reason: "the App Store data isn't a JWS of the shape Apple signs" },
  algorithm: { status: 400, reason: "the App Store data isn't signed with ES256" },
  chain: { status: 400, reason: "the App Store data isn't signed under Apple Root CA - G3" },
  signature: { status: 400, reason: "the App Store data's signature doesn't hold" },
  bundle: { status: 400, reason: "the App Store data is for another app" },
  environment: { status: 403, reason: "this server doesn't take purchases from that environment" },
  "not-subscription": {
    status: 400,
    reason: "the transaction isn't an auto-renewable subscription",
  },
  "renewal-info": { status: 400, reason: "the renewal info is for another subscription" },
};

export function purchaseRefused(failure: PurchaseFailure): Response {
  const { status, reason } = purchaseFailures[failure];
  return problem(status, reason);
}

/**
 * The body of `PUT /account/subscription`: `{"transaction", "renewalInfo"}`, the app's current
 * transaction and renewal info for its subscription, sent at each launch.
 */
export async function sentSubscription(
  request: Request,
  appStore: AppStore,
): Promise<{ ok: true; purchase: Purchase } | { ok: false; status: number; reason: string }> {
  const body = await jsonBody(request);
  const transaction = text(body?.["transaction"]);
  const renewalInfo = text(body?.["renewalInfo"]);
  if (transaction === undefined || renewalInfo === undefined) {
    return {
      ok: false,
      status: 400,
      reason: "a subscription is sent as its transaction and renewal info, as JSON",
    };
  }
  const purchase = await readPurchase(transaction, renewalInfo, appStore);
  return purchase.ok
    ? { ok: true, purchase: purchase.value }
    : { ok: false, ...purchaseFailures[purchase.failure] };
}

export function subscriptionKept(kept: Kept): Response {
  return kept.kept === "kept"
    ? Response.json({ plan: kept.tier, paidUntil: kept.paidUntil })
    : notKept(kept.kept);
}

/** A verified purchase this server won't keep for the account it was sent for. */
export function notKept(reason: "another-account" | "no-plan"): Response {
  return reason === "another-account"
    ? problem(409, "the purchase is another account's")
    : problem(400, "the purchase is of a product no plan is sold as");
}

/**
 * `POST /app-store/notifications`: `{"signedPayload"}`, an App Store Server Notification V2. Apple
 * sends it again until it is answered 200.
 */
export async function receiveNotification(
  request: Request,
  appStore: AppStore,
  store: Store,
): Promise<Response> {
  const signedPayload = text((await jsonBody(request))?.["signedPayload"]);
  if (signedPayload === undefined) {
    return problem(400, "a notification is sent as its signedPayload, as JSON");
  }
  const purchase = await readNotification(signedPayload, appStore);
  if (!purchase.ok) {
    return purchaseRefused(purchase.failure);
  }
  if (purchase.value !== undefined) {
    await store.keepNotified(purchase.value);
  }
  return new Response(null, { status: 200 });
}
