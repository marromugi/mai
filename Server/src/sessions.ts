/**
 * A session token is `s1.<session ID>.<secret>`, the secret 32 random bytes in base64url. The
 * server keeps only the SHA-256 of the secret as written in the token (`sessions.token_sha256`);
 * the device keeps the token.
 */

/** Who a request says it is: a session, and the SHA-256 of the secret it was sent with. */
export type Caller = { readonly session: string; readonly secretSha256: Uint8Array };

/** A session lasts this long after it was last used. */
export const sessionLifetime = 180 * 24 * 60 * 60 * 1000;

/** `last_used` is written at most this often. */
export const lastUsedResolution = 24 * 60 * 60 * 1000;

const tokenPattern =
  /^s1\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.([A-Za-z0-9_-]{43})$/;

export async function callerOf(authorization: string | null): Promise<Caller | undefined> {
  if (authorization === null || !authorization.startsWith("Bearer ")) {
    return undefined;
  }
  const match = tokenPattern.exec(authorization.slice("Bearer ".length));
  const session = match?.[1];
  const secret = match?.[2];
  if (session === undefined || secret === undefined) {
    return undefined;
  }
  return { session, secretSha256: await sha256(new TextEncoder().encode(secret)) };
}

/** A new session's token, and what the server keeps of it. */
export async function newSessionToken(): Promise<{ token: string; caller: Caller }> {
  const session = crypto.randomUUID();
  const secret = base64url(crypto.getRandomValues(new Uint8Array(32)));
  return {
    token: `s1.${session}.${secret}`,
    caller: { session, secretSha256: await sha256(new TextEncoder().encode(secret)) },
  };
}

async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}
