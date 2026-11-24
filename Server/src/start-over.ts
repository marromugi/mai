import { deleteRowlessPhotosOf } from "./account-deletion";
import { problem } from "./http";
import type { Photos } from "./photos";
import type { Caller } from "./sessions";
import type { Answer, Store } from "./store";

/**
 * `DELETE /account/own-key-check`, with the check the device read in `Mai-Own-Key-Check`: starts
 * the account over without its own key (`Store.startOver`), then deletes from R2, past the
 * response, the photos whose rows went.
 */
export async function startOver(
  caller: Caller,
  check: Uint8Array,
  store: Store,
  photos: Photos,
  now: number,
): Promise<Answer<Response>> {
  const started = await store.startOver(caller, check, now);
  if (!started.ok) {
    return started;
  }
  const account = started.value;
  if (account === undefined) {
    return {
      ok: true,
      value: problem(409, "the account's own key check isn't the one sent; nothing was deleted"),
    };
  }
  photos.keepAlive(
    deleteRowlessPhotosOf(account, photos.bucket, store).catch((error: unknown) => {
      // Rowless objects are never served nor counted against the plan.
      console.error(`R2's photos of the account ${account}, started over, weren't deleted`, error);
    }),
  );
  return { ok: true, value: new Response(null, { status: 204 }) };
}
