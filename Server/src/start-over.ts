import { deleteRowlessPhotosOf } from "./account-deletion";
import { problem } from "./http";
import type { Photos } from "./photos";
import type { Caller } from "./sessions";
import type { Answer, Store } from "./store";

/**
 * `PUT /account/own-key-check` with `Mai-Replaces-Own-Key-Check`: starts the account over with the
 * check sent, in place of the one the device read (`Store.startOver`), then deletes from R2, past
 * the response, the photos whose rows went. Sent again once done, it answers 204 and does nothing.
 */
export async function startOver(
  caller: Caller,
  replaced: Uint8Array,
  check: Uint8Array,
  store: Store,
  photos: Photos,
  now: number,
): Promise<Answer<Response>> {
  const started = await store.startOver(caller, replaced, check, now);
  if (!started.ok) {
    return started;
  }
  if (!started.value.started) {
    return {
      ok: true,
      value: started.value.kept
        ? new Response(null, { status: 204 })
        : problem(
            409,
            "the account's own key check is neither the one replaced nor the one sent; nothing was deleted",
          ),
    };
  }
  const { account } = started.value;
  photos.keepAlive(
    deleteRowlessPhotosOf(account, photos.bucket, store).catch((error: unknown) => {
      // Rowless objects are never served nor counted against the plan.
      console.error(`R2's photos of the account ${account}, started over, weren't deleted`, error);
    }),
  );
  return { ok: true, value: new Response(null, { status: 204 }) };
}
