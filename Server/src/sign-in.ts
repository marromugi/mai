import { verifyIdentityToken, type AppleSignInKeys, type SignInFailure } from "./apple-sign-in";
import type { AppleTokens } from "./apple-tokens";
import type { Challenge, Challenges } from "./challenges";
import { parseAccountId } from "./account-id";
import { jsonBody, problem } from "./http";
import { text, type Json } from "./jws";
import type { RefreshTokens } from "./refresh-tokens";
import { newSessionToken } from "./sessions";
import type { Made, Store } from "./store";
import { notKept, purchaseRefused, readPurchase, type AppStore } from "./subscriptions";

/**
 * The routes that need no session: `POST /challenges`, `POST /account` and `POST /sessions`.
 * Listed in `Server/README.md`.
 */

export type SignIn = {
  readonly store: Store;
  readonly challenges: Challenges;
  /** The app's bundle ID, which Apple puts in an ID token's and a notification's `aud`. */
  readonly clientId: string;
  readonly keys: AppleSignInKeys;
  readonly tokens: AppleTokens;
  readonly refreshTokens: RefreshTokens;
  readonly appStore: AppStore;
};

export async function issueChallenge(signIn: SignIn, now: number): Promise<Response> {
  return Response.json({ challenge: await signIn.challenges.issue(now) }, { status: 201 });
}

/**
 * `{"account", "challenge", "identityToken", "authorizationCode", "transaction"}`: the UUID the
 * app made for the account, a challenge from `POST /challenges`, what Sign in with Apple gave the
 * app for it, and the StoreKit 2 transaction of the subscription bought for the account.
 */
export async function makeAccount(
  request: Request,
  signIn: SignIn,
  now: number,
): Promise<Response> {
  const body = await jsonBody(request);
  const account = parseAccountId(text(body?.["account"]) ?? "");
  const code = text(body?.["authorizationCode"]);
  const transaction = text(body?.["transaction"]);
  if (account === undefined || code === undefined || transaction === undefined) {
    return problem(
      400,
      "an account is made from its UUID, a challenge, an ID token, a code and a transaction",
    );
  }
  const user = await signedInUser(body, signIn, now);
  if (!user.ok) {
    return user.response;
  }
  const purchase = await readPurchase(transaction, undefined, signIn.appStore);
  if (!purchase.ok) {
    return purchaseRefused(purchase.failure);
  }
  if (purchase.value.account !== account) {
    return notKept("another-account");
  }
  if (purchase.value.paidUntil <= now) {
    return problem(
      402,
      purchase.value.revoked
        ? "the purchase was refunded or revoked"
        : "the purchase has expired; buy the plan again",
    );
  }
  const exchanged = await signIn.tokens.exchange(code, now);
  if (!exchanged.ok) {
    return exchanged.failure === "refused"
      ? problem(401, "Apple refused the authorization code")
      : problem(502, "Apple's token endpoint didn't answer");
  }
  if (exchanged.value.sub !== user.sub) {
    return problem(401, "the authorization code is another Apple user's");
  }
  const { token, caller } = await newSessionToken();
  const made = await signIn.store.makeAccount(
    {
      id: account,
      appleSub: user.sub,
      sealedRefreshToken: await signIn.refreshTokens.seal(exchanged.value.refreshToken, account),
      purchase: purchase.value,
    },
    user.challenge,
    caller,
    Date.now(),
  );
  return made === "made" ? Response.json({ token }, { status: 201 }) : notMade[made]();
}

const notMade: Record<Exclude<Made, "made">, () => Response> = {
  "challenge-used": () => problem(401, challengeUsed),
  taken: () => problem(409, "this Apple user or this account ID has an account; sign in instead"),
  "purchase-taken": () => notKept("another-account"),
  "no-plan": () => notKept("no-plan"),
};

/** `{"challenge", "identityToken"}`: a challenge from `POST /challenges`, and Apple's ID token. */
export async function startSession(
  request: Request,
  signIn: SignIn,
  now: number,
): Promise<Response> {
  const user = await signedInUser(await jsonBody(request), signIn, now);
  if (!user.ok) {
    return user.response;
  }
  const { token, caller } = await newSessionToken();
  const signedIn = await signIn.store.signIn(user.sub, user.challenge, caller, Date.now());
  if (!signedIn.signedIn) {
    return signedIn.reason === "challenge-used"
      ? problem(401, challengeUsed)
      : problem(404, "this Apple user has no account");
  }
  return Response.json({ account: signedIn.account, token });
}

const challengeUsed = "the challenge was used already, or expired; ask for another";

const signInFailures: Record<SignInFailure, { status: number; reason: string }> = {
  malformed: { status: 401, reason: "the ID token isn't a JWS" },
  algorithm: { status: 401, reason: "the ID token isn't signed with RS256" },
  "unknown-key": { status: 401, reason: "the ID token is signed with a key Apple doesn't publish" },
  "keys-unavailable": { status: 502, reason: "Apple's keys couldn't be fetched" },
  signature: { status: 401, reason: "the ID token's signature doesn't hold" },
  issuer: { status: 401, reason: "the ID token isn't Apple's" },
  audience: { status: 401, reason: "the ID token is for another app" },
  expired: { status: 401, reason: "the ID token has expired" },
  nonce: { status: 401, reason: "the ID token wasn't made for this challenge" },
};

type User = { ok: true; sub: string; challenge: Challenge } | { ok: false; response: Response };

/** The Apple user the body's ID token names, made for the body's challenge. */
async function signedInUser(body: Json | undefined, signIn: SignIn, now: number): Promise<User> {
  const sent = text(body?.["challenge"]);
  const token = text(body?.["identityToken"]);
  if (sent === undefined || token === undefined) {
    return { ok: false, response: problem(400, "a challenge and an ID token are sent as JSON") };
  }
  const challenge = await signIn.challenges.check(sent, now);
  if (challenge === undefined) {
    return {
      ok: false,
      response: problem(401, "the challenge isn't one this server gave, or it has expired"),
    };
  }
  const checked = await verifyIdentityToken(
    token,
    { bundleId: signIn.clientId, nonce: challenge.nonce },
    signIn.keys,
    now,
  );
  if (!checked.ok) {
    const { status, reason } = signInFailures[checked.failure];
    return { ok: false, response: problem(status, reason) };
  }
  return { ok: true, sub: checked.value.sub, challenge };
}
