import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { createClient } from "@libsql/client/web";
import { beforeAll, describe, expect, it } from "vitest";
import { serve, signInOf } from "../src/index";
import type { SignIn } from "../src/sign-in";
import { parseEnvironments } from "../src/subscriptions";
import { newAccount, photos, products, store } from "./accounts";
import { makeChain, signAppStore } from "./apple-fakes";
import {
  appStoreRoot,
  day,
  signedNotification,
  signedRenewalInfo,
  signedTransaction,
} from "./purchases";

const database = createClient({ url: env.TURSO_URL });

let signIn: SignIn;
/** A Worker that takes Production purchases only. */
let productionOnly: SignIn;

function send(url: string): Promise<Response> {
  throw new Error(`the subscription routes reached ${url}; they reach nothing outside`);
}

beforeAll(async () => {
  signIn = signInOf(env, send, await caches.open(crypto.randomUUID()), await appStoreRoot());
  productionOnly = signInOf(
    { ...env, APP_STORE_ENVIRONMENTS: "Production" },
    send,
    await caches.open(crypto.randomUUID()),
    await appStoreRoot(),
  );
});

function call(path: string, body: unknown, token?: string, on = signIn): Promise<Response> {
  const headers = new Headers({ "Content-Type": "application/json" });
  if (token !== undefined) {
    headers.set("Authorization", `Bearer ${token}`);
  }
  return serve(
    new Request(`https://mai.test${path}`, {
      method: path === "/account/subscription" ? "PUT" : "POST",
      headers,
      body: JSON.stringify(body),
    }),
    on,
    photos,
  );
}

async function accountOf(account: string): Promise<{ tier: string; paidUntil: number }> {
  const { rows } = await database.execute({
    sql: "SELECT tier, paid_until FROM accounts WHERE id = ?",
    args: [account],
  });
  const tier = rows[0]?.["tier"];
  if (typeof tier !== "string") {
    throw new Error(`there is no account ${account}`);
  }
  return { tier, paidUntil: Number(rows[0]?.["paid_until"]) };
}

async function subscriptionsOf(account: string): Promise<number> {
  const { rows } = await database.execute({
    sql: "SELECT count(*) AS count FROM subscriptions WHERE account_id = ?",
    args: [account],
  });
  return Number(rows[0]?.["count"]);
}

async function subscriptionRow(original: string): Promise<unknown> {
  const { rows } = await database.execute({
    sql: "SELECT * FROM subscriptions WHERE original_transaction_id = ?",
    args: [original],
  });
  return { ...rows[0] };
}

/** Counts today's 4 requests, all a `test-daily` account may make. */
async function useUpRequests(account: string): Promise<void> {
  await database.execute({
    sql: "INSERT INTO usage (account_id, day, requests) VALUES (?, ?, 4)",
    args: [account, Math.floor(Date.now() / day)],
  });
}

const writing = "6f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f";

/** A sealed writing laid out as `Server/README.md` says. */
function envelope(): Uint8Array<ArrayBuffer> {
  const bytes = new Uint8Array(4 + 16 + 8 + 60 + 12 + 10 + 16);
  bytes.set([0x6d, 0x61, 0x69, 0x01], 0);
  bytes.set(
    Array.from(writing.replaceAll("-", "").match(/../g) ?? [], (pair) => parseInt(pair, 16)),
    4,
  );
  new DataView(bytes.buffer).setBigUint64(20, 1_790_000_000_123n);
  bytes.fill(0xab, 28);
  return bytes;
}

/** Saves the writing as new; answers the status. */
async function save(token: string): Promise<number> {
  const answer = await exports.default.fetch(
    new Request(`https://mai.test/writings/${writing}`, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/octet-stream",
        "Mai-Base-Revision": "none",
      },
      body: envelope(),
    }),
  );
  return answer.status;
}

async function list(token: string): Promise<Response> {
  return exports.default.fetch(
    new Request("https://mai.test/writings", { headers: { Authorization: `Bearer ${token}` } }),
  );
}

/** Tells the Worker of the account's subscription as Apple's notification would. */
async function notify(
  type: string,
  subtype: string | undefined,
  transaction: string,
  renewalInfo?: string,
  signedDate = Date.now() + 1000,
): Promise<Response> {
  return call("/app-store/notifications", {
    signedPayload: await signedNotification(
      type,
      subtype,
      { transaction, ...(renewalInfo === undefined ? {} : { renewalInfo }) },
      signedDate,
    ),
  });
}

describe("the subscription the app resends", () => {
  it("extends the paid-until time on a renewal", async () => {
    const { account, token, original } = await newAccount();
    const expires = Date.now() + 60 * day;
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(account, {
          originalTransactionId: original,
          expiresDate: expires,
          signedDate: Date.now() + 1000,
        }),
        renewalInfo: await signedRenewalInfo(original),
      },
      token,
    );
    expect(answer.status).toBe(200);
    expect(await answer.json()).toEqual({ plan: "basic", paidUntil: expires });
    expect(await accountOf(account)).toEqual({ tier: "basic", paidUntil: expires });
    expect(await subscriptionsOf(account)).toBe(1);
  });

  it("changes the plan to the product of the transaction", async () => {
    const { account, token, original } = await newAccount();
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(account, {
          originalTransactionId: original,
          productId: products.pro,
          signedDate: Date.now() + 1000,
        }),
        renewalInfo: await signedRenewalInfo(original, { productId: products.pro }),
      },
      token,
    );
    expect(answer.status).toBe(200);
    expect(await answer.json()).toMatchObject({ plan: "pro" });
    expect((await accountOf(account)).tier).toBe("pro");
  });

  it("changes nothing when it is older than what is kept", async () => {
    const { account, token, original } = await newAccount();
    const before = await accountOf(account);
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(account, {
          originalTransactionId: original,
          productId: products.pro,
          expiresDate: Date.now() + 90 * day,
          signedDate: Date.now() - 60_000,
        }),
        renewalInfo: await signedRenewalInfo(original),
      },
      token,
    );
    expect(answer.status).toBe(200);
    expect(await answer.json()).toEqual({ plan: before.tier, paidUntil: before.paidUntil });
    expect(await accountOf(account)).toEqual(before);
  });

  it("keeps the account paid through its billing grace period", async () => {
    const ended = Date.now() - day;
    const { account, token, original } = await newAccount(products.basic, Date.now(), ended);
    const graceEnds = Date.now() + 6 * day;
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(account, {
          originalTransactionId: original,
          expiresDate: ended,
          signedDate: Date.now() + 1000,
        }),
        renewalInfo: await signedRenewalInfo(original, {
          isInBillingRetryPeriod: true,
          gracePeriodExpiresDate: graceEnds,
        }),
      },
      token,
    );
    expect(answer.status).toBe(200);
    expect((await accountOf(account)).paidUntil).toBe(graceEnds);
    expect(await save(token)).toBe(200);
  });

  it("renews a lapsed account, which then writes again", async () => {
    const { account, token, original } = await lapsed();
    expect(await save(token)).toBe(402);

    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(account, {
          originalTransactionId: original,
          signedDate: Date.now() + 2000,
        }),
        renewalInfo: await signedRenewalInfo(original),
      },
      token,
    );
    expect(answer.status).toBe(200);
    // Let through to the revision check: the writing lapsed() saved is there, so "none" is 409.
    expect(await save(token)).toBe(409);
  });

  it.each([
    ["another account's appAccountToken", async () => (await newAccount()).account],
    ["no appAccountToken", () => Promise.resolve(undefined)],
  ])("refuses a purchase with %s, keeping it for no account", async (_, token) => {
    const caller = await newAccount();
    const before = await accountOf(caller.account);
    const named = await token();
    const original = crypto.randomUUID();
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(named, {
          originalTransactionId: original,
          productId: products.pro,
        }),
        renewalInfo: await signedRenewalInfo(original),
      },
      caller.token,
    );
    expect(answer.status).toBe(409);
    expect(await accountOf(caller.account)).toEqual(before);
    expect(await subscriptionsOf(caller.account)).toBe(1);
    if (named !== undefined) {
      expect(await subscriptionsOf(named)).toBe(1);
    }
  });

  it("refuses a subscription another account has, named for this one about the same period", async () => {
    const ends = Date.now() + 30 * day;
    const owner = await newAccount(products.basic, Date.now(), ends);
    const before = await accountOf(owner.account);
    const kept = await subscriptionRow(owner.original);
    const caller = await newAccount();
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(caller.account, {
          originalTransactionId: owner.original,
          productId: products.pro,
          signedDate: Date.now() + 1000,
          expiresDate: ends,
        }),
        renewalInfo: await signedRenewalInfo(owner.original),
      },
      caller.token,
    );
    expect(answer.status).toBe(409);
    expect(await subscriptionsOf(caller.account)).toBe(1);
    expect(await accountOf(owner.account)).toEqual(before);
    expect(await subscriptionRow(owner.original)).toEqual(kept);
  });

  it("answers 409 for a purchase that is another account's and of no plan", async () => {
    const caller = await newAccount();
    const other = await newAccount();
    const original = crypto.randomUUID();
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(other.account, {
          originalTransactionId: original,
          productId: "com.marromugi.mai.something.else",
        }),
        renewalInfo: await signedRenewalInfo(original),
      },
      caller.token,
    );
    expect(answer.status).toBe(409);
  });

  it.each([
    [
      "a session token with another secret",
      (token: string) => `${token.slice(0, -1)}${token.endsWith("A") ? "B" : "A"}`,
    ],
  ])("writes nothing for %s", async (_, alter) => {
    const { account, token, original } = await newAccount();
    const before = await accountOf(account);
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(account, {
          originalTransactionId: original,
          productId: products.pro,
          expiresDate: Date.now() + 90 * day,
          signedDate: Date.now() + 1000,
        }),
        renewalInfo: await signedRenewalInfo(original),
      },
      alter(token),
    );
    expect(answer.status).toBe(401);
    expect(await accountOf(account)).toEqual(before);
  });

  it("writes nothing once the plan's requests for the day are used up", async () => {
    const { account, token, original } = await newAccount("test-daily");
    await useUpRequests(account);
    const before = await accountOf(account);
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(account, {
          originalTransactionId: original,
          productId: "test-storage",
          expiresDate: Date.now() + 90 * day,
          signedDate: Date.now() + 1000,
        }),
        renewalInfo: await signedRenewalInfo(original),
      },
      token,
    );
    expect(answer.status).toBe(429);
    expect(await accountOf(account)).toEqual(before);
  });

  it("refuses a purchase from an environment the server doesn't take", async () => {
    const { account, token, original } = await newAccount();
    const before = await accountOf(account);
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(account, {
          originalTransactionId: original,
          environment: "Sandbox",
          expiresDate: Date.now() - day,
          signedDate: Date.now() + 1000,
        }),
        renewalInfo: await signedRenewalInfo(original, { environment: "Sandbox" }),
      },
      token,
      productionOnly,
    );
    expect(answer.status).toBe(403);
    expect(await accountOf(account)).toEqual(before);
  });

  it("refuses renewal info of another subscription", async () => {
    const { account, token, original } = await newAccount();
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(account, {
          originalTransactionId: original,
          expiresDate: Date.now() - day,
          signedDate: Date.now() + 1000,
        }),
        renewalInfo: await signedRenewalInfo(crypto.randomUUID(), {
          gracePeriodExpiresDate: Date.now() + 6 * day,
        }),
      },
      token,
    );
    expect(answer.status).toBe(400);
    expect(await save(token)).toBe(200);
  });

  it("refuses a product no plan is sold as, keeping nothing of it", async () => {
    const { account, token, original } = await newAccount();
    const before = await accountOf(account);
    for (const subscription of [original, crypto.randomUUID()]) {
      const answer = await call(
        "/account/subscription",
        {
          transaction: await signedTransaction(account, {
            originalTransactionId: subscription,
            productId: "com.marromugi.mai.something.else",
            expiresDate: Date.now() + 90 * day,
            signedDate: Date.now() + 1000,
          }),
          renewalInfo: await signedRenewalInfo(subscription),
        },
        token,
      );
      expect(answer.status).toBe(400);
    }
    expect(await accountOf(account)).toEqual(before);
    expect(await subscriptionsOf(account)).toBe(1);
  });

  it.each([
    [
      "no renewal info",
      async (account: string) => ({ transaction: await signedTransaction(account) }),
    ],
    ["no transaction", async () => ({ renewalInfo: await signedRenewalInfo("1") })],
  ])("refuses a body with %s", async (_, body) => {
    const { account, token } = await newAccount();
    expect((await call("/account/subscription", await body(account), token)).status).toBe(400);
  });

  it("needs a session", async () => {
    const { account, original } = await newAccount();
    const answer = await call("/account/subscription", {
      transaction: await signedTransaction(account, { originalTransactionId: original }),
      renewalInfo: await signedRenewalInfo(original),
    });
    expect(answer.status).toBe(401);
  });
});

describe("an App Store notification", () => {
  it.each([
    ["SUBSCRIBED", "RESUBSCRIBE"],
    ["DID_RENEW", undefined],
    ["DID_RENEW", "BILLING_RECOVERY"],
  ])("%s %s extends the paid-until time", async (type, subtype) => {
    const { account, original } = await newAccount();
    const expires = Date.now() + 60 * day;
    const answer = await notify(
      type,
      subtype,
      await signedTransaction(account, { originalTransactionId: original, expiresDate: expires }),
      await signedRenewalInfo(original),
    );
    expect(answer.status).toBe(200);
    expect(await accountOf(account)).toEqual({ tier: "basic", paidUntil: expires });
  });

  it("DID_FAIL_TO_RENEW GRACE_PERIOD keeps the account writing until the grace period ends", async () => {
    const ended = Date.now() - 1000;
    const { account, token, original } = await newAccount(products.basic, Date.now(), ended);
    const graceEnds = Date.now() + 6 * day;
    await notify(
      "DID_FAIL_TO_RENEW",
      "GRACE_PERIOD",
      await signedTransaction(account, { originalTransactionId: original, expiresDate: ended }),
      await signedRenewalInfo(original, {
        isInBillingRetryPeriod: true,
        gracePeriodExpiresDate: graceEnds,
      }),
    );
    expect((await accountOf(account)).paidUntil).toBe(graceEnds);
    expect(await save(token)).toBe(200);
  });

  // The account's kept period ends at `ends`, which the notification's transaction is about.
  it.each([
    ["DID_FAIL_TO_RENEW", undefined, -1000, {}, { isInBillingRetryPeriod: true }],
    ["EXPIRED", "VOLUNTARY", -1000, {}, { autoRenewStatus: 0 }],
    ["EXPIRED", "BILLING_RETRY", -1000, {}, {}],
    ["GRACE_PERIOD_EXPIRED", undefined, -day, {}, { gracePeriodExpiresDate: Date.now() - 1000 }],
    ["REFUND", undefined, 20 * day, { revocationDate: Date.now() - 1000 }, {}],
    ["REVOKE", undefined, 20 * day, { revocationDate: Date.now() - 1000 }, {}],
  ])("%s %s lapses the account", async (type, subtype, ends, transaction, renewalInfo) => {
    const ended = Date.now() + ends;
    const { account, token, original } = await newAccount(products.basic, Date.now(), ended);
    await save(token);
    const answer = await notify(
      type,
      subtype,
      await signedTransaction(account, {
        originalTransactionId: original,
        expiresDate: ended,
        ...transaction,
      }),
      await signedRenewalInfo(original, renewalInfo),
    );
    expect(answer.status).toBe(200);
    expect((await accountOf(account)).paidUntil).toBeLessThan(Date.now());
    expect(await save(token)).toBe(402);
  });

  it("REFUND_REVERSED pays for the account again", async () => {
    const expires = Date.now() + 20 * day;
    const { account, token, original } = await newAccount(products.basic, Date.now(), expires);
    await notify(
      "REFUND",
      undefined,
      await signedTransaction(account, {
        originalTransactionId: original,
        expiresDate: expires,
        revocationDate: Date.now() - 1000,
      }),
    );
    expect(await save(token)).toBe(402);
    await notify(
      "REFUND_REVERSED",
      undefined,
      await signedTransaction(account, { originalTransactionId: original, expiresDate: expires }),
      undefined,
      Date.now() + 2000,
    );
    expect((await accountOf(account)).paidUntil).toBe(expires);
    expect(await save(token)).toBe(200);
  });

  it.each([
    ["REFUND", { revocationDate: Date.now() - 1000 }],
    ["REFUND_DECLINED", {}],
    ["CONSUMPTION_REQUEST", {}],
  ])("%s about an earlier billing period leaves the current one paid", async (type, change) => {
    const { account, token, original } = await newAccount();
    const before = await accountOf(account);
    const answer = await notify(
      type,
      undefined,
      await signedTransaction(account, {
        originalTransactionId: original,
        purchaseDate: Date.now() - 35 * day,
        expiresDate: Date.now() - 5 * day,
        ...change,
      }),
      await signedRenewalInfo(original),
      Date.now() + 2000,
    );
    expect(answer.status).toBe(200);
    expect(await accountOf(account)).toEqual(before);
    expect(await save(token)).toBe(200);
  });

  it("puts an account with two subscriptions paid to the same time on the larger plan", async () => {
    const expires = Date.now() + 10 * day;
    const { account } = await newAccount(products.basic, Date.now(), expires);
    await database.execute({
      sql: "UPDATE subscriptions SET paid_until = ? WHERE account_id = ?",
      args: [expires, account],
    });
    for (const product of [products.pro, products.plus]) {
      await notify(
        "SUBSCRIBED",
        "INITIAL_BUY",
        await signedTransaction(account, { productId: product, expiresDate: expires }),
      );
    }
    expect(await accountOf(account)).toEqual({ tier: "pro", paidUntil: expires });
  });

  it("DID_CHANGE_RENEWAL_PREF UPGRADE moves the account to the new plan at once", async () => {
    const { account, original } = await newAccount();
    await notify(
      "DID_CHANGE_RENEWAL_PREF",
      "UPGRADE",
      await signedTransaction(account, {
        originalTransactionId: original,
        productId: products.pro,
        transactionReason: "PURCHASE",
      }),
      await signedRenewalInfo(original, {
        productId: products.pro,
        autoRenewProductId: products.pro,
      }),
    );
    expect((await accountOf(account)).tier).toBe("pro");
  });

  it("DID_CHANGE_RENEWAL_PREF DOWNGRADE keeps the plan until the renewal on the new one", async () => {
    const expires = Date.now() + 10 * day;
    const { account, original } = await newAccount(products.pro, Date.now(), expires);
    await notify(
      "DID_CHANGE_RENEWAL_PREF",
      "DOWNGRADE",
      await signedTransaction(account, {
        originalTransactionId: original,
        productId: products.pro,
        expiresDate: expires,
      }),
      await signedRenewalInfo(original, {
        productId: products.pro,
        autoRenewProductId: products.plus,
      }),
    );
    expect(await accountOf(account)).toEqual({ tier: "pro", paidUntil: expires });

    const renewed = expires + 30 * day;
    await notify(
      "DID_RENEW",
      undefined,
      await signedTransaction(account, {
        originalTransactionId: original,
        productId: products.plus,
        expiresDate: renewed,
      }),
      await signedRenewalInfo(original, { productId: products.plus }),
      Date.now() + 2000,
    );
    expect(await accountOf(account)).toEqual({ tier: "plus", paidUntil: renewed });
  });

  it("older than one already taken changes nothing", async () => {
    const { account, original } = await newAccount();
    const renewed = Date.now() + 60 * day;
    const later = Date.now() + 5000;
    await notify(
      "DID_RENEW",
      undefined,
      await signedTransaction(account, { originalTransactionId: original, expiresDate: renewed }),
      undefined,
      later,
    );
    const answer = await notify(
      "EXPIRED",
      "VOLUNTARY",
      await signedTransaction(account, {
        originalTransactionId: original,
        expiresDate: Date.now() - day,
      }),
      undefined,
      later - 1,
    );
    expect(answer.status).toBe(200);
    expect(await accountOf(account)).toEqual({ tier: "basic", paidUntil: renewed });

    const again = await notify(
      "EXPIRED",
      "VOLUNTARY",
      await signedTransaction(account, {
        originalTransactionId: original,
        expiresDate: Date.now() - day,
      }),
      undefined,
      later,
    );
    expect(again.status).toBe(200);
    expect((await accountOf(account)).paidUntil).toBe(renewed);
  });

  it("keeps a subscription it doesn't know for the account its appAccountToken names", async () => {
    const { account } = await newAccount();
    const original = crypto.randomUUID();
    const expires = Date.now() + 90 * day;
    await notify(
      "SUBSCRIBED",
      "INITIAL_BUY",
      await signedTransaction(account, {
        originalTransactionId: original,
        productId: products.plus,
        expiresDate: expires,
      }),
    );
    expect(await subscriptionsOf(account)).toBe(2);
    expect(await accountOf(account)).toEqual({ tier: "plus", paidUntil: expires });
  });

  it("is answered 200 and keeps nothing for an account that isn't made yet", async () => {
    const account = crypto.randomUUID();
    const answer = await notify("SUBSCRIBED", "INITIAL_BUY", await signedTransaction(account));
    expect(answer.status).toBe(200);
    expect(await subscriptionsOf(account)).toBe(0);
  });

  it("is answered 200 when it is about no transaction, as TEST is", async () => {
    const answer = await call("/app-store/notifications", {
      signedPayload: await signedNotification("TEST", undefined, {}),
    });
    expect(answer.status).toBe(200);
  });

  it("from an environment the server doesn't take is refused and changes nothing", async () => {
    const { account, original } = await newAccount();
    const before = await accountOf(account);
    const answer = await call(
      "/app-store/notifications",
      {
        signedPayload: await signedNotification("EXPIRED", "VOLUNTARY", {
          environment: "Sandbox",
          transaction: await signedTransaction(account, {
            originalTransactionId: original,
            environment: "Sandbox",
            expiresDate: Date.now() - day,
          }),
        }),
      },
      undefined,
      productionOnly,
    );
    expect(answer.status).toBe(403);
    expect(await accountOf(account)).toEqual(before);
  });

  it("signed under another root is refused and changes nothing", async () => {
    const { account, original } = await newAccount();
    const before = await accountOf(account);
    const chain = await makeChain();
    const transaction = await signAppStore(
      {
        transactionId: "1",
        originalTransactionId: original,
        bundleId: env.APPLE_CLIENT_ID,
        productId: products.basic,
        purchaseDate: Date.now() - day,
        expiresDate: Date.now() - 1000,
        type: "Auto-Renewable Subscription",
        appAccountToken: account,
        signedDate: Date.now() + 1000,
        environment: "Production",
      },
      chain,
    );
    const forged = await signAppStore(
      {
        notificationType: "EXPIRED",
        notificationUUID: crypto.randomUUID(),
        data: {
          bundleId: env.APPLE_CLIENT_ID,
          environment: "Production",
          signedTransactionInfo: transaction,
        },
        version: "2.0",
        signedDate: Date.now() + 1000,
      },
      chain,
    );
    const answer = await call("/app-store/notifications", { signedPayload: forged });
    expect(answer.status).toBe(400);
    expect(await accountOf(account)).toEqual(before);
  });

  it("reaches the deployed Worker, which takes only what Apple Root CA - G3 signed", async () => {
    const { account, original } = await newAccount();
    const before = await accountOf(account);
    const answer = await exports.default.fetch(
      new Request("https://mai.test/app-store/notifications", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          signedPayload: await signedNotification("EXPIRED", "VOLUNTARY", {
            transaction: await signedTransaction(account, {
              originalTransactionId: original,
              expiresDate: Date.now() - day,
            }),
          }),
        }),
      }),
    );
    expect(answer.status).toBe(400);
    expect(await accountOf(account)).toEqual(before);
  });

  it("is refused when its own environment isn't taken, whatever its transaction says", async () => {
    const { account, original } = await newAccount();
    const before = await accountOf(account);
    const answer = await call(
      "/app-store/notifications",
      {
        signedPayload: await signedNotification("DID_RENEW", undefined, {
          environment: "Sandbox",
          transaction: await signedTransaction(account, {
            originalTransactionId: original,
            expiresDate: Date.now() + 90 * day,
          }),
        }),
      },
      undefined,
      productionOnly,
    );
    expect(answer.status).toBe(403);
    expect(await accountOf(account)).toEqual(before);
  });

  it("is ordered by its own signedDate, not its transaction's", async () => {
    const { account, original } = await newAccount();
    const expires = Date.now() + 90 * day;
    await notify(
      "DID_RENEW",
      undefined,
      await signedTransaction(account, {
        originalTransactionId: original,
        expiresDate: expires,
        signedDate: Date.now() - 60_000,
      }),
    );
    expect((await accountOf(account)).paidUntil).toBe(expires);
  });

  it("with renewal info of another subscription is refused and changes nothing", async () => {
    const { account, original } = await newAccount();
    const before = await accountOf(account);
    const answer = await notify(
      "DID_RENEW",
      undefined,
      await signedTransaction(account, {
        originalTransactionId: original,
        expiresDate: Date.now() + 90 * day,
      }),
      await signedRenewalInfo(crypto.randomUUID()),
    );
    expect(answer.status).toBe(400);
    expect(await accountOf(account)).toEqual(before);
  });

  it("about a purchase that isn't a subscription is answered 200 and changes nothing", async () => {
    const { account } = await newAccount();
    const before = await accountOf(account);
    const answer = await notify(
      "ONE_TIME_CHARGE",
      undefined,
      await signedTransaction(account, { expiresDate: undefined, type: "Non-Consumable" }),
    );
    expect(answer.status).toBe(200);
    expect(await accountOf(account)).toEqual(before);
    expect(await subscriptionsOf(account)).toBe(1);
  });

  it("of a product no plan is sold as keeps nothing of it", async () => {
    const { account, original } = await newAccount();
    const before = await accountOf(account);
    for (const subscription of [original, crypto.randomUUID()]) {
      const answer = await notify(
        "DID_CHANGE_RENEWAL_PREF",
        "UPGRADE",
        await signedTransaction(account, {
          originalTransactionId: subscription,
          productId: "com.marromugi.mai.something.else",
          expiresDate: Date.now() + 90 * day,
        }),
      );
      expect(answer.status).toBe(200);
    }
    expect(await accountOf(account)).toEqual(before);
    expect(await subscriptionsOf(account)).toBe(1);
  });

  it("puts an account on the plan of the subscription paid for longest, though smaller", async () => {
    const expires = Date.now() + 60 * day;
    const { account } = await newAccount(products.basic, Date.now(), expires);
    await database.execute({
      sql: "UPDATE subscriptions SET paid_until = ? WHERE account_id = ?",
      args: [expires, account],
    });
    await notify(
      "SUBSCRIBED",
      "INITIAL_BUY",
      await signedTransaction(account, {
        productId: products.pro,
        expiresDate: Date.now() + 10 * day,
      }),
    );
    expect(await accountOf(account)).toEqual({ tier: "basic", paidUntil: expires });
  });

  it("about a kept subscription without an appAccountToken still updates its account", async () => {
    const { account, original } = await newAccount();
    const expires = Date.now() + 60 * day;
    await notify(
      "DID_RENEW",
      undefined,
      await signedTransaction(undefined, { originalTransactionId: original, expiresDate: expires }),
    );
    expect((await accountOf(account)).paidUntil).toBe(expires);
  });

  it("refuses a body without a signedPayload", async () => {
    expect((await call("/app-store/notifications", {})).status).toBe(400);
  });
});

/** A new account holding the writing, whose subscription then expired. */
async function lapsed() {
  const ended = Date.now() - 1000;
  const made = await newAccount(products.basic, Date.now(), ended);
  expect(await save(made.token)).toBe(200);
  await notify(
    "EXPIRED",
    "VOLUNTARY",
    await signedTransaction(made.account, {
      originalTransactionId: made.original,
      expiresDate: ended,
    }),
  );
  return made;
}

/** An account whose subscription lapsed a month ago, and another account. */
async function lapsedOwner() {
  const owner = await newAccount(products.basic, Date.now() - 60 * day);
  const caller = await newAccount();
  return { owner, caller, before: await accountOf(owner.account) };
}

/** The account the subscription `original` is kept for. */
async function keptFor(original: string): Promise<unknown> {
  const { rows } = await database.execute({
    sql: "SELECT account_id FROM subscriptions WHERE original_transaction_id = ?",
    args: [original],
  });
  return rows[0]?.["account_id"];
}

describe("a subscription bought again for another account", () => {
  it("moves to the account a resubscription's notification names", async () => {
    const { owner, caller, before } = await lapsedOwner();
    const expires = Date.now() + 30 * day;

    const answer = await notify(
      "SUBSCRIBED",
      "RESUBSCRIBE",
      await signedTransaction(caller.account, {
        originalTransactionId: owner.original,
        productId: products.plus,
        expiresDate: expires,
      }),
    );

    expect(answer.status).toBe(200);
    expect(await keptFor(owner.original)).toBe(caller.account);
    expect(await accountOf(caller.account)).toEqual({ tier: "plus", paidUntil: expires });
    expect(await accountOf(owner.account)).toEqual(before);
  });

  it("moves to the account that resends it, which the old account is then refused", async () => {
    const { owner, caller, before } = await lapsedOwner();
    const expires = Date.now() + 30 * day;

    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(caller.account, {
          originalTransactionId: owner.original,
          expiresDate: expires,
        }),
        renewalInfo: await signedRenewalInfo(owner.original),
      },
      caller.token,
    );

    expect(answer.status).toBe(200);
    expect(await answer.json()).toEqual({ plan: "basic", paidUntil: expires });
    expect(await keptFor(owner.original)).toBe(caller.account);
    expect(await accountOf(owner.account)).toEqual(before);
    const old = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(owner.account, {
          originalTransactionId: owner.original,
          expiresDate: before.paidUntil,
          signedDate: Date.now() + 2000,
        }),
        renewalInfo: await signedRenewalInfo(owner.original),
      },
      owner.token,
    );
    expect(old.status).toBe(409);
    expect(await keptFor(owner.original)).toBe(caller.account);
  });

  it("stays with the account it moved to when a renewal names the account it left", async () => {
    const { owner, caller, before } = await lapsedOwner();
    await notify(
      "SUBSCRIBED",
      "RESUBSCRIBE",
      await signedTransaction(caller.account, {
        originalTransactionId: owner.original,
        expiresDate: Date.now() + 30 * day,
      }),
    );
    const renewed = Date.now() + 60 * day;

    // Apple keeps the token of the purchase before an upgrade on the renewals after it.
    await notify(
      "DID_RENEW",
      undefined,
      await signedTransaction(owner.account, {
        originalTransactionId: owner.original,
        expiresDate: renewed,
        transactionReason: "RENEWAL",
      }),
      undefined,
      Date.now() + 5000,
    );

    expect(await keptFor(owner.original)).toBe(caller.account);
    expect(await accountOf(caller.account)).toEqual({ tier: "basic", paidUntil: renewed });
    expect(await accountOf(owner.account)).toEqual(before);
  });

  it("moves for no transaction without transactionReason, as one signed before Apple wrote it", async () => {
    const { owner, caller, before } = await lapsedOwner();

    await notify(
      "SUBSCRIBED",
      "RESUBSCRIBE",
      await signedTransaction(caller.account, {
        originalTransactionId: owner.original,
        expiresDate: Date.now() + 30 * day,
        transactionReason: undefined,
      }),
    );

    expect(await keptFor(owner.original)).toBe(owner.account);
    expect((await accountOf(owner.account)).paidUntil).toBeGreaterThan(before.paidUntil);
  });

  it("cuts an account still paid for to the time of the purchase that moved it away", async () => {
    const owner = await newAccount();
    const other = await newAccount(products.pro);
    const otherPaid = Date.now() + 10 * day;
    await database.execute({
      sql: "UPDATE subscriptions SET paid_until = ? WHERE original_transaction_id = ?",
      args: [otherPaid, other.original],
    });
    const caller = await newAccount();
    // A Pro subscription of the owner's own still counts after the move.
    await database.execute({
      sql: "UPDATE subscriptions SET account_id = ? WHERE original_transaction_id = ?",
      args: [owner.account, other.original],
    });
    const moved = Date.now() + 1000;

    await notify(
      "DID_CHANGE_RENEWAL_PREF",
      "UPGRADE",
      await signedTransaction(caller.account, {
        originalTransactionId: owner.original,
        productId: products.plus,
        expiresDate: Date.now() + 31 * day,
      }),
      undefined,
      moved,
    );

    expect(await keptFor(owner.original)).toBe(caller.account);
    expect(await accountOf(owner.account)).toEqual({ tier: "pro", paidUntil: otherPaid });
  });

  it("cuts an account with no other subscription to the time of the purchase that moved it", async () => {
    const owner = await newAccount(products.plus);
    const caller = await newAccount();
    const moved = Date.now() + 1000;

    await notify(
      "DID_CHANGE_RENEWAL_PREF",
      "UPGRADE",
      await signedTransaction(caller.account, {
        originalTransactionId: owner.original,
        productId: products.plus,
        expiresDate: Date.now() + 31 * day,
      }),
      undefined,
      moved,
    );

    expect(await accountOf(owner.account)).toEqual({ tier: "plus", paidUntil: moved });
  });

  it("lets the account it moved to resend a renewal that names the account it left", async () => {
    const { owner, caller } = await lapsedOwner();
    await notify(
      "SUBSCRIBED",
      "RESUBSCRIBE",
      await signedTransaction(caller.account, {
        originalTransactionId: owner.original,
        expiresDate: Date.now() + 30 * day,
      }),
    );
    const renewed = Date.now() + 60 * day;

    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(owner.account, {
          originalTransactionId: owner.original,
          expiresDate: renewed,
          transactionReason: "RENEWAL",
          signedDate: Date.now() + 5000,
        }),
        renewalInfo: await signedRenewalInfo(owner.original),
      },
      caller.token,
    );

    expect(answer.status).toBe(200);
    expect(await answer.json()).toEqual({ plan: "basic", paidUntil: renewed });
    expect(await keptFor(owner.original)).toBe(caller.account);
  });

  it("cuts no account marked for deletion it moves from", async () => {
    const owner = await newAccount();
    const caller = await newAccount();
    await store.markForDeletionNow(owner.account);
    const before = await accountOf(owner.account);

    await notify(
      "DID_CHANGE_RENEWAL_PREF",
      "UPGRADE",
      await signedTransaction(caller.account, {
        originalTransactionId: owner.original,
        expiresDate: Date.now() + 31 * day,
      }),
    );

    expect(await keptFor(owner.original)).toBe(caller.account);
    expect(await accountOf(owner.account)).toEqual(before);
    // The cron tests pick marked accounts from the same database.
    await store.deleteAccount(owner.account);
  });

  it("is refused, cutting nothing, to a third account resending a purchase for another", async () => {
    const { owner, caller, before } = await lapsedOwner();
    const active = await newAccount();
    const third = await newAccount();
    const kept = await subscriptionRow(active.original);
    const activeBefore = await accountOf(active.account);

    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(caller.account, {
          originalTransactionId: active.original,
          expiresDate: Date.now() + 31 * day,
        }),
        renewalInfo: await signedRenewalInfo(active.original),
      },
      third.token,
    );

    expect(answer.status).toBe(409);
    expect(await subscriptionRow(active.original)).toEqual(kept);
    expect(await accountOf(active.account)).toEqual(activeBefore);
    expect(await accountOf(owner.account)).toEqual(before);
  });

  it("is refused a later period signed no later than what is kept, cutting nothing", async () => {
    const owner = await newAccount();
    const caller = await newAccount();
    const kept = await subscriptionRow(owner.original);
    const before = await accountOf(owner.account);
    const { rows } = await database.execute({
      sql: "SELECT signed_date FROM subscriptions WHERE original_transaction_id = ?",
      args: [owner.original],
    });

    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(caller.account, {
          originalTransactionId: owner.original,
          expiresDate: Date.now() + 31 * day,
          signedDate: Number(rows[0]?.["signed_date"]),
        }),
        renewalInfo: await signedRenewalInfo(owner.original),
      },
      caller.token,
    );

    expect(answer.status).toBe(409);
    expect(await subscriptionRow(owner.original)).toEqual(kept);
    expect(await accountOf(owner.account)).toEqual(before);
  });

  it("is refused to an account that resends a renewal naming it", async () => {
    const { owner, caller, before } = await lapsedOwner();
    const kept = await subscriptionRow(owner.original);

    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(caller.account, {
          originalTransactionId: owner.original,
          expiresDate: Date.now() + 30 * day,
          transactionReason: "RENEWAL",
        }),
        renewalInfo: await signedRenewalInfo(owner.original),
      },
      caller.token,
    );

    expect(answer.status).toBe(409);
    expect(await subscriptionRow(owner.original)).toEqual(kept);
    expect(await accountOf(owner.account)).toEqual(before);
  });

  it("changes nothing when it names an account that isn't made yet", async () => {
    const { owner, before } = await lapsedOwner();
    const kept = await subscriptionRow(owner.original);

    const answer = await notify(
      "SUBSCRIBED",
      "RESUBSCRIBE",
      await signedTransaction(crypto.randomUUID(), {
        originalTransactionId: owner.original,
        expiresDate: Date.now() + 30 * day,
      }),
    );

    expect(answer.status).toBe(200);
    expect(await subscriptionRow(owner.original)).toEqual(kept);
    expect(await accountOf(owner.account)).toEqual(before);
  });

  it("changes nothing when it names an account marked for deletion", async () => {
    const { owner, caller, before } = await lapsedOwner();
    const kept = await subscriptionRow(owner.original);
    await store.markForDeletionNow(caller.account);

    await notify(
      "SUBSCRIBED",
      "RESUBSCRIBE",
      await signedTransaction(caller.account, {
        originalTransactionId: owner.original,
        expiresDate: Date.now() + 30 * day,
      }),
    );

    expect(await subscriptionRow(owner.original)).toEqual(kept);
    expect(await accountOf(owner.account)).toEqual(before);
    // The cron tests pick marked accounts from the same database.
    await store.deleteAccount(caller.account);
  });

  it("changes nothing when it names another account about the same period", async () => {
    const { owner, caller, before } = await lapsedOwner();
    const kept = await subscriptionRow(owner.original);
    const callerBefore = await accountOf(caller.account);

    await notify(
      "DID_CHANGE_RENEWAL_STATUS",
      undefined,
      await signedTransaction(caller.account, {
        originalTransactionId: owner.original,
        expiresDate: before.paidUntil,
      }),
    );

    expect(await subscriptionRow(owner.original)).toEqual(kept);
    expect(await accountOf(caller.account)).toEqual(callerBefore);
    expect(await accountOf(owner.account)).toEqual(before);
  });
});

describe("a lapsed account", () => {
  it("reads its writings", async () => {
    const { token } = await lapsed();
    const listed = await list(token);
    expect(listed.status).toBe(200);
    expect(await listed.json()).toMatchObject({ writings: [{ id: writing }] });
    const read = await exports.default.fetch(
      new Request(`https://mai.test/writings/${writing}`, {
        headers: { Authorization: `Bearer ${token}` },
      }),
    );
    expect(read.status).toBe(200);
  });

  it("is refused a save with 402, which isn't counted", async () => {
    const { account, token } = await lapsed();
    const answer = await exports.default.fetch(
      new Request(`https://mai.test/writings/${writing}`, {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/octet-stream",
          "Mai-Base-Revision": "none",
        },
        body: envelope(),
      }),
    );
    expect(answer.status).toBe(402);
    expect(await answer.json()).toEqual({
      error: "the account's subscription has lapsed; it is read but not written",
    });
    const { rows } = await database.execute({
      sql: "SELECT saves FROM usage WHERE account_id = ?",
      args: [account],
    });
    expect(Number(rows[0]?.["saves"])).toBe(1);
  });

  it("is lapsed from the very time it is paid until", async () => {
    const { account, caller } = await newAccount();
    const { rows } = await database.execute({
      sql: "SELECT paid_until FROM accounts WHERE id = ?",
      args: [account],
    });
    const paidUntil = Number(rows[0]?.["paid_until"]);
    const check = new Uint8Array(32).fill(3);
    expect(await store.keepOwnKeyCheck(caller, check, paidUntil)).toEqual({
      ok: false,
      refusal: "lapsed",
    });
    expect(await store.keepOwnKeyCheck(caller, check, paidUntil - 1)).toEqual({
      ok: true,
      value: true,
    });
  });

  it("hears 402 before 429 when its requests for the day are used up too", async () => {
    const { account, token } = await newAccount("test-daily");
    await database.execute({
      sql: "UPDATE accounts SET paid_until = ? WHERE id = ?",
      args: [Date.now() - 1000, account],
    });
    await useUpRequests(account);
    expect(await save(token)).toBe(402);
  });

  it("keeps when it lapsed, for its deletion 90 days on", async () => {
    const lapsedAt = Date.now() - 3 * day;
    const { account, original } = await newAccount(products.basic, Date.now(), lapsedAt);
    await notify(
      "EXPIRED",
      "VOLUNTARY",
      await signedTransaction(account, { originalTransactionId: original, expiresDate: lapsedAt }),
    );
    expect((await accountOf(account)).paidUntil).toBe(lapsedAt);
  });

  it("is refused keeping its own key check with 402, and keeps none", async () => {
    const { account, token } = await lapsed();
    const answer = await exports.default.fetch(
      new Request("https://mai.test/account/own-key-check", {
        method: "PUT",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/octet-stream" },
        body: new Uint8Array(32).fill(7),
      }),
    );
    expect(answer.status).toBe(402);
    const { rows } = await database.execute({
      sql: "SELECT own_key_check FROM accounts WHERE id = ?",
      args: [account],
    });
    expect(rows[0]?.["own_key_check"]).toBeNull();
  });
});

describe("APP_STORE_ENVIRONMENTS", () => {
  it.each([
    ["Production", ["Production"]],
    ["Sandbox", ["Sandbox"]],
    ["Production,Sandbox", ["Production", "Sandbox"]],
    ["Production, Sandbox", ["Production", "Sandbox"]],
  ])("%s takes %j", (value, environments) => {
    expect([...parseEnvironments(value)].toSorted()).toEqual(environments);
  });

  it.each(["", "production", "Xcode", "Production,"])("stops the Worker on %j", (value) => {
    expect(() => parseEnvironments(value)).toThrow(/APP_STORE_ENVIRONMENTS/);
  });

  it("takes a Sandbox purchase on the production Worker, as App Review buys with one", async () => {
    const { account, token, original } = await newAccount();
    const answer = await serve(
      new Request("https://mai.test/account/subscription", {
        method: "PUT",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({
          transaction: await signedTransaction(account, {
            originalTransactionId: original,
            environment: "Sandbox",
            signedDate: Date.now() + 1000,
          }),
          renewalInfo: await signedRenewalInfo(original, { environment: "Sandbox" }),
        }),
      }),
      signIn,
      photos,
    );
    expect(answer.status).toBe(200);
    const { rows } = await database.execute({
      sql: "SELECT environment FROM subscriptions WHERE original_transaction_id = ?",
      args: [original],
    });
    expect(rows[0]?.["environment"]).toBe("Sandbox");
  });
});
