import type { AccountId } from "./account-id";
import { problem } from "./http";
import { uploadOfKey, type Photos } from "./photos";
import type { Caller } from "./sessions";
import type { SignIn } from "./sign-in";
import type { Answer, Store, ToDelete } from "./store";

/**
 * `DELETE /account`: Apple's refresh token is revoked, then the account is marked while the
 * caller's session is live, then R2 is emptied of it, then its rows are deleted. Once marked, its
 * sessions ending (Apple's `consent-revoked` for this very revoke) no longer stops it. Until the
 * rows go, the session still works, so a call that fails partway is called again from the start:
 * revoking, marking and emptying R2 twice do no harm; one that fails once marked is also finished by
 * the cron trigger. Once they go, nothing on the server names the
 * account, so R2 is swept once more after them, for a photo put that stored its bytes while this
 * ran.
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
  const deleted = await deleteFound(found, signIn, photos, now, {
    mark: () => signIn.store.markForDeletionByCaller(caller, found.account, now),
    // Once this call marked the account, its rows go: here, or already by the cron trigger or
    // another call that found it marked.
    deleteRows: async () => {
      await signIn.store.deleteAccount(found.account);
      return true;
    },
  });
  if (deleted === "unrevoked") {
    return {
      ok: true,
      value: problem(502, "Apple's revoke endpoint didn't answer; nothing was deleted, try again"),
    };
  }
  return deleted === "kept"
    ? { ok: false, refusal: "session" }
    : { ok: true, value: new Response(null, { status: 204 }) };
}

/** At most this many accounts are deleted each time the cron trigger runs. */
export const lapsedDeletedAtOnce = 10;

/**
 * Deletes the accounts lapsed `lapsedKept` or longer, and those a `DELETE /account` marked and
 * didn't finish, at most `lapsedDeletedAtOnce` picked at random, as `deleteAccount` does; run by
 * the cron trigger. Each is marked once Apple has revoked its token and before R2 is touched: a
 * resubscription before then keeps a lapsed account whole, and one after it no longer keeps it, so
 * an account that fails partway is finished by a later run. One that fails is logged and left for
 * the next run, and the others go on.
 */
export async function deleteLapsedAccounts(
  signIn: SignIn,
  photos: Photos,
  now: number,
): Promise<void> {
  const lapsed = await signIn.store.dueForDeletion(now, lapsedDeletedAtOnce);
  await Promise.all(
    lapsed.map(async (found) => {
      try {
        const deleted = await deleteFound(found, signIn, photos, now, {
          mark: () => signIn.store.markForDeletion(found.account, now),
          deleteRows: () => signIn.store.deleteAccount(found.account),
        });
        if (deleted === "unrevoked") {
          console.warn(
            `the account ${found.account} due for deletion wasn't deleted: Apple's revoke endpoint didn't answer; the next run tries again`,
          );
        }
      } catch (error) {
        // Each account's deletion is an entrance of its own, so one account's failure stops no other.
        console.error(
          `deleting the account ${found.account} failed; the next run tries again`,
          error,
        );
      }
    }),
  );
}

/** `unrevoked`: Apple didn't answer, and nothing was deleted. `kept`: no row was deleted. */
type Deleted = "deleted" | "unrevoked" | "kept";

/**
 * Whether the account is still to be deleted: `mark` asks before R2 is touched, and `deleteRows`
 * deletes its rows. Each answers false when it isn't, and nothing more is done.
 */
type Held = { mark: () => Promise<boolean>; deleteRows: () => Promise<boolean> };

/**
 * Revokes the account's Apple token, empties R2 of it, then deletes its rows, as `held` lets it;
 * once the rows went, R2 is swept again, kept alive past the return.
 */
async function deleteFound(
  found: ToDelete,
  signIn: SignIn,
  photos: Photos,
  now: number,
  held: Held,
): Promise<Deleted> {
  const { account, sealedRefreshToken } = found;
  const refreshToken = await signIn.refreshTokens.open(sealedRefreshToken, account);
  const revoked = await signIn.tokens.revoke(refreshToken, now);
  if (!revoked.ok) {
    return "unrevoked";
  }
  if (!(await held.mark())) {
    return "kept";
  }
  await deletePhotosOf(account, photos.bucket);
  if (!(await held.deleteRows())) {
    return "kept";
  }
  photos.keepAlive(deleteRowlessPhotosOf(account, photos.bucket, signIn.store));
  return "deleted";
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
