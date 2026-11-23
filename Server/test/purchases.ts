import { env } from "cloudflare:test";
import type { Certificate } from "../src/der";
import { products } from "./accounts";
import { certificateOf, makeChain, signAppStore, type Chain } from "./apple-fakes";

/**
 * What the App Store signs, made in the tests and signed by a chain under the tests' own root,
 * which the Worker is given in place of Apple Root CA - G3 (`signInOf`).
 */

export const day = 24 * 60 * 60 * 1000;

let chain: Promise<Chain> | undefined;

function appStoreChain(): Promise<Chain> {
  chain ??= makeChain();
  return chain;
}

/** The root the tests' App Store data is signed under. */
export async function appStoreRoot(): Promise<Certificate> {
  return certificateOf((await appStoreChain()).root);
}

/** A StoreKit 2 transaction of a month of Basic, bought now for `account` in Production. */
export async function signedTransaction(
  account: string | undefined,
  changes: Record<string, unknown> = {},
): Promise<string> {
  const now = Date.now();
  return signAppStore(
    {
      transactionId: crypto.randomUUID(),
      originalTransactionId: crypto.randomUUID(),
      webOrderLineItemId: crypto.randomUUID(),
      bundleId: env.APPLE_CLIENT_ID,
      productId: products.basic,
      subscriptionGroupIdentifier: "21500000",
      purchaseDate: now - 1000,
      originalPurchaseDate: now - 1000,
      expiresDate: now + 30 * day,
      quantity: 1,
      type: "Auto-Renewable Subscription",
      appAccountToken: account,
      inAppOwnershipType: "PURCHASED",
      signedDate: now,
      environment: "Production",
      transactionReason: "PURCHASE",
      storefront: "JPN",
      storefrontId: "143462",
      price: 150000,
      currency: "JPY",
      ...changes,
    },
    await appStoreChain(),
  );
}

/** The renewal info of the subscription `originalTransactionId`, renewing as Basic. */
export async function signedRenewalInfo(
  originalTransactionId: string,
  changes: Record<string, unknown> = {},
): Promise<string> {
  const now = Date.now();
  return signAppStore(
    {
      originalTransactionId,
      autoRenewProductId: products.basic,
      productId: products.basic,
      autoRenewStatus: 1,
      signedDate: now,
      environment: "Production",
      recentSubscriptionStartDate: now - 1000,
      renewalDate: now + 30 * day,
      ...changes,
    },
    await appStoreChain(),
  );
}

/** An App Store Server Notification V2's `signedPayload`. */
export async function signedNotification(
  notificationType: string,
  subtype: string | undefined,
  data: { transaction?: string; renewalInfo?: string; environment?: string },
  signedDate = Date.now(),
): Promise<string> {
  return signAppStore(
    {
      notificationType,
      subtype,
      notificationUUID: crypto.randomUUID(),
      data: {
        appAppleId: 1234567890,
        bundleId: env.APPLE_CLIENT_ID,
        bundleVersion: "1",
        environment: data.environment ?? "Production",
        signedTransactionInfo: data.transaction,
        signedRenewalInfo: data.renewalInfo,
        status: 1,
      },
      version: "2.0",
      signedDate,
    },
    await appStoreChain(),
  );
}
