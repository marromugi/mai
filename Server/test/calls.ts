import { env } from "cloudflare:test";
import { serve, signInOf } from "../src/index";
import { photos } from "./accounts";

export type Sent = {
  method?: string;
  json?: unknown;
  body?: Uint8Array<ArrayBuffer>;
  base?: string;
};

/**
 * Sends `path` to the Worker with `token`, as of the time `now`, with Apple never reached. The time
 * is given, not faked, since test files running side by side share `Date`.
 */
export function callAt(
  now: number,
  path: string,
  token: string,
  { method = "GET", json, body, base }: Sent = {},
): Promise<Response> {
  const headers = new Headers({ Authorization: `Bearer ${token}` });
  if (json !== undefined) headers.set("Content-Type", "application/json");
  if (body !== undefined) headers.set("Content-Type", "application/octet-stream");
  if (base !== undefined) headers.set("Mai-Base-Revision", base);
  const signIn = signInOf(
    env,
    () => Promise.reject(new Error("read mode doesn't reach Apple")),
    caches.default,
  );
  const request = new Request(`https://mai.test${path}`, {
    method,
    headers,
    body: json !== undefined ? JSON.stringify(json) : (body ?? null),
  });
  return serve(request, signIn, photos, now);
}
