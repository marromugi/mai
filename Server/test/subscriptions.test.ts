import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { createClient } from "@libsql/client/web";
import { beforeAll, describe, expect, it } from "vitest";
import { serve, signInOf } from "../src/index";
import type { SignIn } from "../src/sign-in";
import { parseEnvironments } from "../src/subscriptions";
import { newAccount, products } from "./accounts";
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

function send(url: string): Promise<Response> {
  throw new Error(`the subscription routes reached ${url}; they reach nothing outside`);
}

beforeAll(async () => {
  signIn = signInOf(env, send, await caches.open(crypto.randomUUID()), await appStoreRoot());
});

function call(path: string, body: unknown, token?: string): Promise<Response> {
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
    signIn,
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
    const { account, token, original } = await newAccount();
    const graceEnds = Date.now() + 6 * day;
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(account, {
          originalTransactionId: original,
          expiresDate: Date.now() - day,
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
    const { account, token, original } = await newAccount();
    await notify(
      "EXPIRED",
      "VOLUNTARY",
      await signedTransaction(account, {
        originalTransactionId: original,
        expiresDate: Date.now() - day,
      }),
    );
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
    expect(await save(token)).toBe(200);
  });

  it.each([
    ["another account's appAccountToken", () => crypto.randomUUID()],
    ["no appAccountToken", () => undefined],
  ])("refuses a purchase with %s", async (_, token) => {
    const caller = await newAccount();
    const before = await accountOf(caller.account);
    const original = crypto.randomUUID();
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(token(), {
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
  });

  it("refuses a subscription another account has, though it names this one", async () => {
    const owner = await newAccount();
    const caller = await newAccount();
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(caller.account, {
          originalTransactionId: owner.original,
          signedDate: Date.now() + 1000,
          expiresDate: Date.now() - day,
        }),
        renewalInfo: await signedRenewalInfo(owner.original),
      },
      caller.token,
    );
    expect(answer.status).toBe(409);
    expect(await subscriptionsOf(caller.account)).toBe(1);
    expect((await accountOf(owner.account)).paidUntil).toBeGreaterThan(Date.now());
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

  it("refuses a product no plan is sold as", async () => {
    const { account, token, original } = await newAccount();
    const answer = await call(
      "/account/subscription",
      {
        transaction: await signedTransaction(account, {
          originalTransactionId: original,
          productId: "com.marromugi.mai.something.else",
          signedDate: Date.now() + 1000,
        }),
        renewalInfo: await signedRenewalInfo(original),
      },
      token,
    );
    expect(answer.status).toBe(400);
    expect((await accountOf(account)).tier).toBe("basic");
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
    const { account, token, original } = await newAccount();
    const graceEnds = Date.now() + 6 * day;
    await notify(
      "DID_FAIL_TO_RENEW",
      "GRACE_PERIOD",
      await signedTransaction(account, {
        originalTransactionId: original,
        expiresDate: Date.now() - 1000,
      }),
      await signedRenewalInfo(original, {
        isInBillingRetryPeriod: true,
        gracePeriodExpiresDate: graceEnds,
      }),
    );
    expect((await accountOf(account)).paidUntil).toBe(graceEnds);
    expect(await save(token)).toBe(200);
  });

  it.each([
    ["DID_FAIL_TO_RENEW", undefined, {}, { isInBillingRetryPeriod: true }],
    ["EXPIRED", "VOLUNTARY", {}, { autoRenewStatus: 0 }],
    ["EXPIRED", "BILLING_RETRY", {}, {}],
    ["GRACE_PERIOD_EXPIRED", undefined, {}, { gracePeriodExpiresDate: Date.now() - 1000 }],
    ["REFUND", undefined, { revocationDate: Date.now() - 1000, expiresDate: Date.now() + day }, {}],
    ["REVOKE", undefined, { revocationDate: Date.now() - 1000, expiresDate: Date.now() + day }, {}],
  ])("%s %s lapses the account", async (type, subtype, transaction, renewalInfo) => {
    const { account, token, original } = await newAccount();
    await save(token);
    const answer = await notify(
      type,
      subtype,
      await signedTransaction(account, {
        originalTransactionId: original,
        expiresDate: Date.now() - 1000,
        ...transaction,
      }),
      await signedRenewalInfo(original, renewalInfo),
    );
    expect(answer.status).toBe(200);
    expect((await accountOf(account)).paidUntil).toBeLessThan(Date.now());
    expect(await save(token)).toBe(402);
  });

  it("REFUND_REVERSED pays for the account again", async () => {
    const { account, token, original } = await newAccount();
    const expires = Date.now() + 20 * day;
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
    const { account, original } = await newAccount(products.pro);
    const expires = Date.now() + 10 * day;
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
    const answer = await call("/app-store/notifications", {
      signedPayload: await signedNotification("EXPIRED", "VOLUNTARY", {
        environment: "Sandbox",
        transaction: await signedTransaction(account, {
          originalTransactionId: original,
          environment: "Sandbox",
          expiresDate: Date.now() - day,
        }),
      }),
    });
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

  it("refuses a body without a signedPayload", async () => {
    expect((await call("/app-store/notifications", {})).status).toBe(400);
  });
});

/** A new account holding the writing, whose subscription then expired. */
async function lapsed() {
  const made = await newAccount();
  expect(await save(made.token)).toBe(200);
  await notify(
    "EXPIRED",
    "VOLUNTARY",
    await signedTransaction(made.account, {
      originalTransactionId: made.original,
      expiresDate: Date.now() - 1000,
    }),
  );
  return made;
}

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
      error: "the account's subscription has lapsed; its writings are read but not written",
    });
    const { rows } = await database.execute({
      sql: "SELECT saves FROM usage WHERE account_id = ?",
      args: [account],
    });
    expect(Number(rows[0]?.["saves"])).toBe(1);
  });

  it("keeps when it lapsed, for its deletion 90 days on", async () => {
    const { account, original } = await newAccount();
    const lapsedAt = Date.now() - 3 * day;
    await notify(
      "EXPIRED",
      "VOLUNTARY",
      await signedTransaction(account, { originalTransactionId: original, expiresDate: lapsedAt }),
    );
    expect((await accountOf(account)).paidUntil).toBe(lapsedAt);
  });

  it("may still keep its own key check", async () => {
    const { token } = await lapsed();
    const answer = await exports.default.fetch(
      new Request("https://mai.test/account/own-key-check", {
        method: "PUT",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/octet-stream" },
        body: new Uint8Array(32).fill(7),
      }),
    );
    expect(answer.status).toBe(204);
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

  it("takes a Sandbox purchase on a Worker set to Sandbox", async () => {
    const { account, token, original } = await newAccount();
    const sandbox = signInOf(
      { ...env, APP_STORE_ENVIRONMENTS: "Sandbox" },
      send,
      await caches.open(crypto.randomUUID()),
      await appStoreRoot(),
    );
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
      sandbox,
    );
    expect(answer.status).toBe(200);
  });
});
