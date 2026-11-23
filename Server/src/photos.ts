import { problem } from "./http";
import type { Caller } from "./sessions";
import type { PhotoId, PhotoPart } from "./photo-id";
import type { Answer, Store, Upload } from "./store";

/**
 * Sealed photos and thumbnails in R2. The server sees their bytes but can't open them: the app
 * seals each with a key of its own, which the user's own key seals.
 */

/** The most bytes each part takes, sealed. */
export const largestPart: Record<PhotoPart, number> = {
  photo: 50_000_000,
  thumbnail: 1_000_000,
};

/** At most this many stale uploads are released each time the cron trigger runs. */
const sweptAtOnce = 1000;

/**
 * Where R2 keeps an upload's bytes. Every key of an account starts with `<account ID>/`; the
 * upload's own ID ends it, so no two uploads share a key.
 */
export function photoKey(upload: Upload): string {
  return `${upload.account}/${upload.id}/${upload.part}/${upload.upload}`;
}

/** The upload's own ID, from a key `photoKey` made. */
export function uploadOfKey(key: string): string {
  return key.slice(key.lastIndexOf("/") + 1);
}

export type Sized =
  | { ok: true; size: number; body: ReadableStream }
  | { ok: false; status: number; reason: string };

/** The body of a part of a photo and its size, when the request is one R2 can take as it is. */
export function sizeOf(request: Request, part: PhotoPart): Sized {
  if (request.headers.get("Content-Type") !== "application/octet-stream") {
    return { ok: false, status: 415, reason: "a sealed photo is sent as application/octet-stream" };
  }
  const length = request.headers.get("Content-Length");
  if (length === null || !/^[0-9]+$/.test(length)) {
    return { ok: false, status: 411, reason: "a sealed photo is sent with its Content-Length" };
  }
  const size = Number(length);
  const body = request.body;
  if (size === 0 || body === null) {
    return { ok: false, status: 400, reason: "a sealed photo has bytes" };
  }
  if (size > largestPart[part]) {
    return {
      ok: false,
      status: 413,
      reason: `a sealed ${part} is at most ${largestPart[part]} bytes`,
    };
  }
  return { ok: true, size, body };
}

/**
 * Runs work to its end even when the request it belongs to is gone, as `ctx.waitUntil` does: a
 * device that drops its connection mid-upload would otherwise leave its room reserved.
 */
export type KeepAlive = (work: Promise<unknown>) => void;

/** Where photos are kept, and how a put outlives its request. */
export type Photos = { readonly bucket: R2Bucket; readonly keepAlive: KeepAlive };

/**
 * Takes `size` bytes of a part of a photo. Room for them is reserved in the account's plan first;
 * R2 then takes exactly that many bytes, or the room is released.
 */
export async function putPhoto(
  body: ReadableStream,
  size: number,
  caller: Caller,
  id: PhotoId,
  part: PhotoPart,
  store: Store,
  bucket: R2Bucket,
  keepAlive: KeepAlive,
  now: number,
): Promise<Answer<Response>> {
  const reserved = await store.reservePhoto(caller, id, part, size, now);
  if (!reserved.ok) {
    return reserved;
  }
  if (!reserved.value.reserved) {
    return {
      ok: true,
      value: problem(409, `the server has this ${part} already, or is taking it now`),
    };
  }
  const upload = reserved.value.upload;
  const key = photoKey(upload);
  const sent = (async () => {
    try {
      await bucket.put(key, body.pipeThrough(new FixedLengthStream(size)));
    } catch (error) {
      await release(store, bucket, await store.startReleasing(upload));
      throw error;
    }
  })();
  // The failure reaches the caller through `await sent` below; the copy kept alive only finishes.
  keepAlive(sent.catch(() => undefined));
  await sent;
  if (!(await store.storePhoto(upload))) {
    await bucket.delete(key);
    return {
      ok: true,
      value: problem(408, "the upload took too long and its room was released; send it again"),
    };
  }
  return { ok: true, value: new Response(null, { status: 201 }) };
}

/** The part of the caller's photo `id` as R2 holds it, or undefined when it holds none. */
export async function getPhoto(
  caller: Caller,
  id: PhotoId,
  part: PhotoPart,
  store: Store,
  bucket: R2Bucket,
  now: number,
): Promise<Answer<Response | undefined>> {
  const read = await store.readPhoto(caller, id, part, now);
  if (!read.ok || read.value === undefined) {
    return read.ok ? { ok: true, value: undefined } : read;
  }
  const key = photoKey(read.value);
  const object = await bucket.get(key);
  if (object === null) {
    throw new Error(`photos says R2 holds ${key}, but R2 has no such object`);
  }
  return {
    ok: true,
    value: new Response(object.body, {
      headers: {
        "Content-Type": "application/octet-stream",
        "Content-Length": String(object.size),
      },
    }),
  };
}

/** Releases uploads that reserved room and never finished (`uploadLifetime`); run by the cron trigger. */
export async function sweepUploads(store: Store, bucket: R2Bucket, now: number): Promise<void> {
  await release(store, bucket, await store.releaseStale(now, sweptAtOnce));
}

/**
 * Deletes what R2 may hold of `uploads`, which are being released, then the room they reserved.
 * Where R2 can't be reached they stay releasing, for the cron trigger to finish later.
 */
async function release(store: Store, bucket: R2Bucket, uploads: Upload[]): Promise<void> {
  if (uploads.length === 0) {
    return;
  }
  await bucket.delete(uploads.map(photoKey));
  await store.forgetReleased(uploads);
}
