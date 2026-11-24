import { serve, signInOf } from "../src/index";
import { appleIssuer, appleKeysUrl } from "../src/apple-sign-in";
import { appleRevokeUrl, appleTokenUrl } from "../src/apple-tokens";
import { jsonBody, problem } from "../src/http";
import { text, whole } from "../src/jws";
import {
  base64url,
  certificateOf,
  jwks,
  makeChain,
  makeSignInKey,
  signAppStore,
  signIdentityToken,
  type Chain,
  type SignInKey,
} from "./apple-fakes";

/**
 * The Worker with a stand-in for Apple, for local runs of the app and of `Packages/Sync` that
 * can't reach Apple: `wrangler dev test/stand-in-apple.ts`, as `scripts/server-contract-test.sh`
 * runs it. Never deployed.
 *
 * Every route of `src/index.ts` is served as there, with Apple's keys, `/auth/token` and
 * `/auth/revoke` answered by the stand-in, and App Store data checked under the stand-in's root in
 * place of Apple Root CA - G3. Two routes of its own give what Apple would give the app:
 *
 * - `POST /stand-in-apple/sign-in` `{"user", "nonce"}`: what Sign in with Apple gives for the
 *   Apple user `user` asked with `nonce`, `{"identityToken", "authorizationCode"}`.
 * - `POST /stand-in-apple/subscription` `{"account", "plan", "originalTransactionId"?,
 *   "expiresDate"?}`: a month of `plan` bought for `account` in Production, as StoreKit 2 gives it,
 *   `{"transaction", "renewalInfo"}`. A new subscription unless `originalTransactionId` is given;
 *   `expiresDate` is milliseconds since 1970.
 */

type StandIn = {
  readonly signInKey: SignInKey;
  readonly chain: Chain;
  /** The PKCS #8 P-256 key, in base64, that `/auth/token` is asked with, as `APPLE_SIGN_IN_KEY`. */
  readonly clientKey: string;
};

let made: Promise<StandIn> | undefined;

/** Made once per isolate: the tokens and data it signs check out while the Worker runs. */
function standIn(): Promise<StandIn> {
  made ??= (async () => {
    const client = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
      "sign",
    ]);
    if (!("privateKey" in client)) {
      throw new Error("ECDSA makes a key pair");
    }
    const pkcs8 = await crypto.subtle.exportKey("pkcs8", client.privateKey);
    if (!(pkcs8 instanceof ArrayBuffer)) {
      throw new Error("a key exported as PKCS #8 is bytes");
    }
    return {
      signInKey: await makeSignInKey("stand-in"),
      chain: await makeChain(),
      clientKey: btoa(String.fromCharCode(...new Uint8Array(pkcs8))),
    };
  })();
  return made;
}

const codePrefix = "stand-in.";
const day = 24 * 60 * 60 * 1000;

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const apple = await standIn();
    switch (`${request.method} ${new URL(request.url).pathname}`) {
      case "POST /stand-in-apple/sign-in":
        return signedIn(request, apple, env.APPLE_CLIENT_ID);
      case "POST /stand-in-apple/subscription":
        return subscribed(request, apple, env.APPLE_CLIENT_ID);
    }
    return serve(
      request,
      signInOf(
        { ...env, APPLE_SIGN_IN_KEY: apple.clientKey },
        (url, init) => answerAsApple(url, apple, init),
        caches.default,
        certificateOf(apple.chain.root),
      ),
      { bucket: env.PHOTOS, keepAlive: (work) => ctx.waitUntil(work) },
    );
  },
} satisfies ExportedHandler<Env>;

async function signedIn(request: Request, apple: StandIn, clientId: string): Promise<Response> {
  const body = await jsonBody(request);
  const user = text(body?.["user"]);
  const nonce = text(body?.["nonce"]);
  if (user === undefined || nonce === undefined) {
    return problem(400, "a stand-in sign-in is asked with a user and a nonce");
  }
  return Response.json({
    identityToken: await identityToken(apple, clientId, user, { nonce }),
    authorizationCode: `${codePrefix}${user}`,
  });
}

async function subscribed(request: Request, apple: StandIn, clientId: string): Promise<Response> {
  const body = await jsonBody(request);
  const account = text(body?.["account"]);
  const plan = text(body?.["plan"]);
  if (account === undefined || plan === undefined) {
    return problem(400, "a stand-in subscription is bought for an account and a plan");
  }
  const now = Date.now();
  const originalTransactionId = text(body?.["originalTransactionId"]) ?? crypto.randomUUID();
  const expiresDate = whole(body?.["expiresDate"]) ?? now + 30 * day;
  const productId = `com.marromugi.mai.${plan}.monthly`;
  const transaction = await signAppStore(
    {
      transactionId: crypto.randomUUID(),
      originalTransactionId,
      webOrderLineItemId: crypto.randomUUID(),
      bundleId: clientId,
      productId,
      subscriptionGroupIdentifier: "21500000",
      purchaseDate: now - 1000,
      originalPurchaseDate: now - 1000,
      expiresDate,
      quantity: 1,
      type: "Auto-Renewable Subscription",
      appAccountToken: account,
      inAppOwnershipType: "PURCHASED",
      signedDate: now,
      environment: "Production",
      transactionReason: "PURCHASE",
      storefront: "JPN",
      storefrontId: "143462",
      currency: "JPY",
    },
    apple.chain,
  );
  const renewalInfo = await signAppStore(
    {
      originalTransactionId,
      autoRenewProductId: productId,
      productId,
      autoRenewStatus: 1,
      signedDate: now,
      environment: "Production",
      recentSubscriptionStartDate: now - 1000,
      renewalDate: expiresDate,
    },
    apple.chain,
  );
  return Response.json({ transaction, renewalInfo });
}

function identityToken(
  apple: StandIn,
  clientId: string,
  user: string,
  claims: Record<string, unknown> = {},
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return signIdentityToken(
    { iss: appleIssuer, aud: clientId, sub: user, iat: now, exp: now + 600, ...claims },
    apple.signInKey,
  );
}

/** Answers the Worker's requests to Apple: the keys, a code `stand-in.<user>`, and revoking. */
async function answerAsApple(url: string, apple: StandIn, init?: RequestInit): Promise<Response> {
  switch (url) {
    case appleKeysUrl:
      return new Response(await jwks([apple.signInKey]));
    case appleTokenUrl: {
      // AppleTokens posts a form.
      const form = init?.body instanceof URLSearchParams ? init.body : new URLSearchParams();
      const code = form.get("code") ?? "";
      if (!code.startsWith(codePrefix)) {
        return Response.json({ error: "invalid_grant" }, { status: 400 });
      }
      const user = code.slice(codePrefix.length);
      const refreshToken = base64url(crypto.getRandomValues(new Uint8Array(32)));
      return Response.json({
        refresh_token: refreshToken,
        id_token: await identityToken(apple, "stand-in", user),
      });
    }
    case appleRevokeUrl:
      return new Response(null, { status: 200 });
    default:
      return problem(404, `the stand-in Apple doesn't answer ${url}`);
  }
}
