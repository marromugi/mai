import { verifyIdentityToken, type AppleSignInKeys, type SignInFailure } from "./apple-sign-in";
import type { AppleTokens } from "./apple-tokens";
import type { Challenge, Challenges } from "./challenges";
import { parseWritingId } from "./envelope";
import { isJson, text, type Json } from "./jws";
import type { RefreshTokens } from "./refresh-tokens";
import { newSessionToken } from "./sessions";
import type { Store } from "./store";

/**
 * The routes that need no session: `POST /challenges`, `POST /account` and `POST /sessions`.
 * Listed in `Server/README.md`.
 */

export type SignIn = {
  readonly store: Store;
  readonly challenges: Challenges;
  /** The app's bundle ID, which Apple puts in an ID token's `aud`. */
  readonly clientId: string;
  readonly keys: AppleSignInKeys;
  readonly tokens: AppleTokens;
  readonly refreshTokens: RefreshTokens;
};

/** The plan an account is made on until S4 (#22) sets it from the verified purchase. */
const firstTier = "basic";

export async function issueChallenge(signIn: SignIn, now: number): Promise<Response> {
  return Response.json({ challenge: await signIn.challenges.issue(now) }, { status: 201 });
}

/**
 * `{"account", "challenge", "identityToken", "authorizationCode"}`: the UUID the app made for the
 * account, a challenge from `POST /challenges`, and what Sign in with Apple gave the app for it.
 */
export async function makeAccount(
  request: Request,
  signIn: SignIn,
  now: number,
): Promise<Response> {
  const body = await jsonBody(request);
  const account = parseWritingId(text(body?.["account"]) ?? "");
  const code = text(body?.["authorizationCode"]);
  if (account === undefined || code === undefined) {
    return problem(400, "an account is made from its UUID, a challenge, an ID token and a code");
  }
  const user = await signedInUser(body, signIn, now);
  if (!user.ok) {
    return user.response;
  }
  // S4 (#22) checks here that the purchase sent with the account names it, and picks the plan.
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
      tier: firstTier,
    },
    user.challenge,
    caller,
    now,
  );
  if (made === "made") {
    return Response.json({ token }, { status: 201 });
  }
  return made === "challenge-used"
    ? problem(401, challengeUsed)
    : problem(409, "this Apple user or this account ID has an account; sign in instead");
}

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
  const signedIn = await signIn.store.signIn(user.sub, user.challenge, caller, now);
  if (!signedIn.signedIn) {
    return signedIn.reason === "challenge-used"
      ? problem(401, challengeUsed)
      : problem(404, "this Apple user has no account");
  }
  return Response.json({ account: signedIn.account, token });
}

const challengeUsed = "the challenge was used already; ask for another";

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

async function jsonBody(request: Request): Promise<Json | undefined> {
  if (request.headers.get("Content-Type")?.split(";")[0]?.trim() !== "application/json") {
    return undefined;
  }
  try {
    const body: unknown = await request.json();
    return isJson(body) ? body : undefined;
  } catch (error) {
    if (error instanceof SyntaxError) {
      return undefined;
    }
    throw error;
  }
}

export function problem(status: number, reason: string): Response {
  return Response.json({ error: reason }, { status });
}
