import { env } from "cloudflare:test";
import { parseAccountId } from "../src/account-id";
import { challengeLifetime } from "../src/challenges";
import { newSessionToken, type Caller } from "../src/sessions";
import { Store } from "../src/store";

export const store = Store.open(env.TURSO_URL, env.TURSO_TOKEN);

/**
 * A new account on `tier` (a row of `plans`; `test/sqld.ts` adds the tests' own), with one session
 * started at `now`, written without Apple: `test/sign-in.test.ts` makes accounts through Apple.
 * Each test makes its own, so tests share the database and nothing else.
 */
export async function newAccount(
  tier = "basic",
  now = Date.now(),
): Promise<{ account: string; token: string; caller: Caller }> {
  const account = parseAccountId(crypto.randomUUID());
  if (account === undefined) {
    throw new Error("crypto.randomUUID gives a lowercase UUID");
  }
  const { token, caller } = await newSessionToken();
  const made = await store.makeAccount(
    { id: account, appleSub: `test.${account}`, sealedRefreshToken: new Uint8Array(), tier },
    { value: crypto.randomUUID(), expires: now + challengeLifetime, nonce: "" },
    caller,
    now,
  );
  if (made !== "made") {
    throw new Error(`a new test account on ${tier} was ${made}; is ${tier} a row of plans?`);
  }
  return { account, token, caller };
}
