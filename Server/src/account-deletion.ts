import type { AccountId } from "./account-id";
import { problem } from "./http";
import { uploadOfKey, type Photos } from "./photos";
import type { Caller } from "./sessions";
import type { SignIn } from "./sign-in";
import type { Answer, Store } from "./store";

/**
 * `DELETE /account`: Apple's refresh token is revoked, then R2 is emptied of the account, then its
 * rows are deleted. Until the rows go, the session still works, so a call that fails partway is
 * called again from the start: revoking and emptying R2 twice do no harm. Once they go, nothing on
 * the server names the account, so R2 is swept once more after them, for a photo put that stored
 * its bytes while this ran.
 */
export async function deleteAccount(
  caller: Caller,
  signIn: SignIn,
  photos: Photos,
  now: number,
): Promise<Answer<Response>> {
  const found = await signIn.store.accountToDelete(caller, now);
  if (found === undefined) {
    return { ok: false, refusal: "session" };
  }
  const { account, sealedRefreshToken } = found;
  const refreshToken = await signIn.refreshTokens.open(sealedRefreshToken, account);
  const revoked = await signIn.tokens.revoke(refreshToken, now);
  if (!revoked.ok) {
    return {
      ok: true,
      value: problem(502, "Apple's revoke endpoint didn't answer; nothing was deleted, try again"),
    };
  }
  await deletePhotosOf(account, photos.bucket);
  if (!(await signIn.store.deleteAccount(caller, account, now))) {
    return { ok: false, refusal: "session" };
  }
  photos.keepAlive(deleteRowlessPhotosOf(account, photos.bucket, signIn.store));
  return { ok: true, value: new Response(null, { status: 204 }) };
}

/** Deletes every object R2 holds under `<account>/`. */
async function deletePhotosOf(account: AccountId, bucket: R2Bucket): Promise<void> {
  let listed: R2Objects;
  do {
    // Each list starts over, since what the last one listed is gone.
    listed = await bucket.list({ prefix: `${account}/` });
    if (listed.objects.length > 0) {
      await bucket.delete(listed.objects.map((object) => object.key));
    }
  } while (listed.truncated);
}

/**
 * Deletes the objects under `<account>/` whose upload has no row in `photos`. An account made
 * again with the same ID (the same purchase's `appAccountToken`) keeps the photos it stored since.
 */
async function deleteRowlessPhotosOf(
  account: AccountId,
  bucket: R2Bucket,
  store: Store,
): Promise<void> {
  let cursor: string | undefined;
  let listed: R2Objects;
  do {
    listed = await bucket.list({
      prefix: `${account}/`,
      ...(cursor === undefined ? {} : { cursor }),
    });
    const keys = listed.objects.map((object) => object.key);
    const held = await store.heldUploads(keys.map(uploadOfKey));
    const rowless = keys.filter((key) => !held.has(uploadOfKey(key)));
    if (rowless.length > 0) {
      await bucket.delete(rowless);
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor !== undefined);
}
