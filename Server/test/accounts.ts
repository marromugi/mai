import { env } from "cloudflare:test";
import { newSessionToken, type Caller } from "../src/sessions";
import { Store } from "../src/store";

export const store = Store.open(env.TURSO_URL, env.TURSO_TOKEN);

/**
 * A new account on `tier` (a row of `plans`; `test/sqld.ts` adds the tests' own), with one session
 * started at `now`. Each test makes its own, so tests share the database and nothing else.
 */
export async function newAccount(
  tier = "basic",
  now = Date.now(),
): Promise<{ account: string; token: string; caller: Caller }> {
  const account = crypto.randomUUID();
  await store.makeAccount(account, tier, now);
  const { token, caller } = await newSessionToken();
  await store.startSession(account, caller, now);
  return { account, token, caller };
}
