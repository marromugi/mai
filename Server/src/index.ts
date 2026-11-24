import { deleteAccount, deleteLapsedAccounts } from "./account-deletion";
import { AppleSignInKeys } from "./apple-sign-in";
import { AppleTokens } from "./apple-tokens";
import { serveFont } from "./fonts";
import { Challenges } from "./challenges";
import { parseBase, parseEnvelope, parseWritingId } from "./envelope";
import { hex } from "./hex";
import { RefreshTokens } from "./refresh-tokens";
import { callerOf } from "./sessions";
import { appleRootCaG3 } from "./apple-root";
import type { Certificate } from "./der";
import { problem } from "./http";
import {
  parseEnvironments,
  receiveNotification,
  sentSubscription,
  subscriptionKept,
} from "./subscriptions";
import { issueChallenge, makeAccount, startSession, type SignIn } from "./sign-in";
import { receiveSignInNotification } from "./sign-in-notifications";
import { Store } from "./store";
import { answered, refused } from "./answers";
import { serveAgent, serveReadMode } from "./read-mode-routes";
import { parsePhotoId } from "./photo-id";
import { getPhoto, putPhoto, sizeOf, sweepUploads, type Photos } from "./photos";

/**
 * Of writings and photos, the server keeps only sealed ones. It knows of each writing only its ID, updated
 * time and size, and of each photo its ID and size; of each account, its Apple user, Apple's refresh
 * token (sealed), its own key check, and its App Store subscriptions (transaction ID, product,
 * expiry, environment).
 * Font files are served apart from accounts, from R2 (`src/fonts.ts`), so of a font fetched it
 * knows only which file and the request's address. Routes are listed in `Server/README.md`.
 */
export default {
  fetch(request, env, ctx): Promise<Response> {
    if (new URL(request.url).pathname.startsWith("/fonts/")) {
      return serveFont(request, env.FONTS);
    }
    return serve(
      request,
      signInOf(env, (url, init) => fetch(url, init), caches.default),
      { bucket: env.PHOTOS, keepAlive: (work) => ctx.waitUntil(work) },
    );
  },

  async scheduled(_controller, env, ctx): Promise<void> {
    const store = Store.open(env.TURSO_URL, env.TURSO_TOKEN);
    const now = Date.now();
    await store.sweep(now);
    await sweepUploads(store, env.PHOTOS, now);
    await deleteLapsedAccounts(
      signInOf(env, (url, init) => fetch(url, init), caches.default),
      { bucket: env.PHOTOS, keepAlive: (work) => ctx.waitUntil(work) },
      now,
    );
  },
} satisfies ExportedHandler<Env>;

/**
 * What the routes reach, from the Worker's secrets and vars; `send` is `fetch` and
 * `appStoreRoot` is Apple Root CA - G3 outside the tests.
 */
export function signInOf(
  env: Env,
  send: (url: string, init?: RequestInit) => Promise<Response>,
  cache: Cache,
  appStoreRoot: Certificate = appleRootCaG3,
): SignIn {
  return {
    store: Store.open(env.TURSO_URL, env.TURSO_TOKEN),
    challenges: new Challenges(env.CHALLENGE_KEY),
    clientId: env.APPLE_CLIENT_ID,
    keys: new AppleSignInKeys(send, cache),
    tokens: new AppleTokens(send, {
      clientId: env.APPLE_CLIENT_ID,
      teamId: env.APPLE_TEAM_ID,
      keyId: env.APPLE_SIGN_IN_KEY_ID,
      key: env.APPLE_SIGN_IN_KEY,
    }),
    refreshTokens: new RefreshTokens(env.REFRESH_TOKEN_KEY),
    appStore: {
      signer: { root: appStoreRoot, bundleId: env.APPLE_CLIENT_ID },
      environments: parseEnvironments(env.APP_STORE_ENVIRONMENTS),
    },
  };
}

/**
 * Answers `request` at the time `now`, with Apple and Turso reached through `signIn`, and photos
 * kept in `photos`.
 */
export async function serve(
  request: Request,
  signIn: SignIn,
  photos: Photos,
  now = Date.now(),
): Promise<Response> {
  const route = `${request.method} ${new URL(request.url).pathname}`;
  switch (route) {
    case "POST /challenges":
      return issueChallenge(signIn, now);
    case "POST /account":
      return makeAccount(request, signIn, now);
    case "POST /sessions":
      return startSession(request, signIn, now);
    case "POST /app-store/notifications":
      return receiveNotification(request, signIn.appStore, signIn.store);
    case "POST /apple/sign-in-notifications":
      return receiveSignInNotification(request, signIn, photos, now);
  }
  const path = new URL(request.url).pathname.split("/").slice(1);
  if (path[0] === "agent") {
    return serveAgent(request, signIn.store, now);
  }

  const caller = await callerOf(request.headers.get("Authorization"));
  if (caller === undefined) {
    return problem(401, "the Authorization header doesn't hold a session token");
  }

  const store = signIn.store;
  /** A request turned down for its own shape, answered so once its session is let in. */
  const turnedDown = async (status: number, reason: string): Promise<Response> =>
    answered(await store.admit(caller, now), () => problem(status, reason));

  switch (route) {
    case "DELETE /session":
      return (await store.endSession(caller, now))
        ? new Response(null, { status: 204 })
        : refused("session");
    case "DELETE /account":
      return answered(await deleteAccount(caller, signIn, photos, now), (deleted) => deleted);
    case "GET /account":
      return answered(await store.account(caller, now), (state) =>
        Response.json({
          plan: state.tier,
          paidUntil: state.paidUntil,
          lapsed: state.lapsed,
          gracePeriod: state.gracePeriod,
          deletesAt: state.deletesAt,
          usage: state.usage,
          ownKeyCheck: state.ownKeyCheck === null ? null : hex(state.ownKeyCheck),
        }),
      );
    case "PUT /account/subscription": {
      const sent = await sentSubscription(request, signIn.appStore);
      if (!sent.ok) {
        return turnedDown(sent.status, sent.reason);
      }
      return answered(await store.keepPurchase(caller, sent.purchase, now), subscriptionKept);
    }
    case "PUT /account/own-key-check": {
      if (request.headers.get("Content-Type") !== "application/octet-stream") {
        return turnedDown(415, "the own key check is sent as application/octet-stream");
      }
      const check = new Uint8Array(await request.arrayBuffer());
      if (check.length !== 32) {
        return turnedDown(400, "the own key check is 32 bytes");
      }
      return answered(await store.keepOwnKeyCheck(caller, check, now), (kept) =>
        kept
          ? new Response(null, { status: 204 })
          : problem(409, "the account has another own key check; its own key was made already"),
      );
    }
  }

  const readMode = await serveReadMode(request, path, caller, store, turnedDown, now);
  if (readMode !== undefined) {
    return readMode;
  }
  if (path[0] === "photos") {
    const part = path.length === 2 ? "photo" : path[2] === "thumbnail" ? "thumbnail" : undefined;
    const id = parsePhotoId(path[1] ?? "");
    if (part === undefined || path.length > 3) {
      return turnedDown(
        404,
        "a photo is at /photos/<ID>, and its thumbnail at /photos/<ID>/thumbnail",
      );
    }
    if (id === undefined) {
      return turnedDown(404, "a photo's ID is a UUID");
    }
    switch (request.method) {
      case "GET":
        return answered(
          await getPhoto(caller, id, part, store, photos.bucket, now),
          (read) => read ?? problem(404, `the server has no ${part} for this photo`),
        );
      case "PUT": {
        const sized = sizeOf(request, part);
        if (!sized.ok) {
          return turnedDown(sized.status, sized.reason);
        }
        return answered(
          await putPhoto(
            sized.body,
            sized.size,
            caller,
            id,
            part,
            store,
            photos.bucket,
            photos.keepAlive,
            now,
          ),
          (put) => put,
        );
      }
      default:
        return turnedDown(405, `a ${part} is read with GET and sent with PUT`);
    }
  }
  if (path[0] !== "writings" || path.length > 2) {
    return turnedDown(404, "there is no such route; Server/README.md lists them");
  }

  if (path.length === 1) {
    if (request.method !== "GET") {
      return turnedDown(405, "/writings is only read, with GET");
    }
    return answered(await store.list(caller, now), (writings) => Response.json({ writings }));
  }

  const id = parseWritingId(path[1] ?? "");
  if (id === undefined) {
    return turnedDown(404, "a writing's ID is a UUID");
  }
  switch (request.method) {
    case "GET": {
      return answered(await store.read(caller, id, now), (read) =>
        read === undefined
          ? problem(404, "the server has no writing with this ID")
          : new Response(read.bytes, {
              headers: {
                "Content-Type": "application/octet-stream",
                "Mai-Revision": read.revision,
              },
            }),
      );
    }
    case "PUT": {
      if (request.headers.get("Content-Type") !== "application/octet-stream") {
        return turnedDown(415, "a sealed writing is sent as application/octet-stream");
      }
      const base = parseBase(request.headers.get("Mai-Base-Revision"));
      if (!base.ok) {
        return turnedDown(400, base.reason);
      }
      const envelope = await parseEnvelope(await request.arrayBuffer());
      if (!envelope.ok) {
        return turnedDown(400, envelope.reason);
      }
      if (envelope.value.id !== id) {
        return turnedDown(400, "the sealed writing's ID is not the one in the path");
      }
      return answered(await store.save(caller, envelope.value, base.value, now), (saved) =>
        Response.json({ revision: saved.revision }, { status: saved.saved ? 200 : 409 }),
      );
    }
    default:
      return turnedDown(405, "a writing is read with GET and saved with PUT");
  }
}
