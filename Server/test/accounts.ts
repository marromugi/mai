import { env } from "cloudflare:test";
import { parseAccountId } from "../src/account-id";
import { challengeLifetime } from "../src/challenges";
import { newSessionToken, type Caller } from "../src/sessions";
import { Store } from "../src/store";

export const store = Store.open(env.TURSO_URL, env.TURSO_TOKEN);

/** The products `schema.sql` sells the plans as. */
export const products = {
  basic: "com.marromugi.mai.basic.monthly",
  plus: "com.marromugi.mai.plus.monthly",
  pro: "com.marromugi.mai.pro.monthly",
} as const;

const month = 30 * 24 * 60 * 60 * 1000;

/**
 * A new account on the plan sold as `product` (`test/sqld.ts` adds the tests' own plans, each
 * sold as a product of its name), paid for a month from `now`, with one session started at `now`,
 * written without Apple: `test/sign-in.test.ts` makes accounts through Apple. Each test makes its
 * own, so tests share the database and nothing else. `original` is its subscription's
 * originalTransactionId.
 */
export async function newAccount(
  product: string = products.basic,
  now = Date.now(),
): Promise<{ account: string; token: string; caller: Caller; original: string }> {
  const account = parseAccountId(crypto.randomUUID());
  if (account === undefined) {
    throw new Error("crypto.randomUUID gives a lowercase UUID");
  }
  const { token, caller } = await newSessionToken();
  const original = crypto.randomUUID();
  const made = await store.makeAccount(
    {
      id: account,
      appleSub: `test.${account}`,
      sealedRefreshToken: new Uint8Array(),
      purchase: {
        originalTransactionId: original,
        account,
        productId: product,
        paidUntil: now + month,
        revoked: false,
        environment: "Production",
        signedDate: now,
      },
    },
    { value: crypto.randomUUID(), expires: now + challengeLifetime, nonce: "" },
    caller,
    now,
  );
  if (made !== "made") {
    throw new Error(`a new test account on ${product} was ${made}; is a plan sold as ${product}?`);
  }
  return { account, token, caller, original };
}
