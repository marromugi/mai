import { deleteAccountOfAppleUser } from "./account-deletion";
import { appleIssuer, appleSigned, type SignatureFailure } from "./apple-sign-in";
import { jsonBody, problem } from "./http";
import { isJson, text, whole } from "./jws";
import type { Photos } from "./photos";
import type { SignIn } from "./sign-in";

/**
 * `POST /apple/sign-in-notifications`: Sign in with Apple's server-to-server notifications, as
 * https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts
 * describes them. Listed in `Server/README.md`.
 */

/**
 * The events that delete the user's account, since the Apple Account is gone (#69).
 * `account-delete` is how Apple's documentation once wrote `account-deleted`.
 */
const accountDeleting = new Set(["account-deleted", "account-delete"]);

/** The events that end every session of the user's account, and its read mode. */
const sessionEnding = new Set(["consent-revoked", ...accountDeleting]);

/**
 * `{"payload"}`: a JWT Apple signed with a Sign in with Apple key, for this app, whose `events`
 * claim names the event and the user. Answers 200 for every event it reads, acted on or not, and
 * for a user with no account.
 */
export async function receiveSignInNotification(
  request: Request,
  signIn: SignIn,
  photos: Photos,
  now: number,
): Promise<Response> {
  const payload = text((await jsonBody(request))?.["payload"]);
  if (payload === undefined) {
    return problem(400, 'a Sign in with Apple notification is {"payload"} sent as JSON');
  }
  const signed = await appleSigned(payload, signIn.keys, now);
  if (!signed.ok) {
    const { status, reason } = signatureFailures[signed.failure];
    return problem(status, reason);
  }
  const claims = signed.value;
  if (claims["iss"] !== appleIssuer) {
    return problem(400, "the notification isn't Apple's");
  }
  if (claims["aud"] !== signIn.clientId) {
    return problem(400, "the notification is for another app");
  }
  const event = eventOf(claims["events"]);
  if (event === undefined) {
    return problem(400, "the notification's events claim has no type and sub");
  }
  if (sessionEnding.has(event.type)) {
    // `iat` counts seconds. A session started after its second, by signing in again, outlives the
    // same notification sent again.
    const iat = whole(claims["iat"]);
    const before = iat === undefined ? now : (iat + 1) * 1000;
    await signIn.store.signOutAppleUser(event.sub, before);
  }
  if (accountDeleting.has(event.type)) {
    await deleteAccountOfAppleUser(event.sub, signIn, photos, now);
  }
  return new Response(null, { status: 200 });
}

const signatureFailures: Record<SignatureFailure, { status: number; reason: string }> = {
  malformed: { status: 400, reason: "the payload isn't a JWS" },
  algorithm: { status: 400, reason: "the payload isn't signed with RS256" },
  "unknown-key": { status: 400, reason: "the payload is signed with a key Apple doesn't publish" },
  "keys-unavailable": { status: 502, reason: "Apple's keys couldn't be fetched" },
  signature: { status: 400, reason: "the payload's signature doesn't hold" },
};

/**
 * The `type` and `sub` of an `events` claim: an object, as Apple's documentation shows it, or that
 * object written as a JSON string.
 */
function eventOf(events: unknown): { type: string; sub: string } | undefined {
  let value = events;
  if (typeof events === "string") {
    try {
      value = JSON.parse(events);
    } catch (error) {
      if (error instanceof SyntaxError) {
        return undefined;
      }
      throw error;
    }
  }
  if (!isJson(value)) {
    return undefined;
  }
  const type = text(value["type"]);
  const sub = text(value["sub"]);
  return type === undefined || sub === undefined ? undefined : { type, sub };
}
