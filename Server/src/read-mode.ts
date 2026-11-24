import { parseAgentId, type AgentId } from "./agents";
import {
  parseRevision,
  parseWritingId,
  type Parsed,
  type Revision,
  type WritingId,
} from "./envelope";
import { parseHex } from "./hex";
import { jsonBody } from "./http";
import { isJson, whole, type Json } from "./jws";

/**
 * What the device sends for read mode (#26), checked here before the store sees it. Bytes are
 * written in lowercase hex.
 */

/** An agent's public key and the device's signature of it are each at most this long. */
export const keyBytesAtMost = 1024;

/** A writing's key wrapped for an agent is at most this long. */
export const wrappedBytesAtMost = 1024;

/** One `POST /copies` holds at most this many copies. */
export const copiesAtOnce = 100;

/** An account has at most this many agents that aren't revoked. */
export const liveAgentsAtMost = 10;

export type Approval = { readonly publicKey: Uint8Array; readonly signature: Uint8Array };

/** A copy as the device sends it: `wrapped` is `writing`'s key at `revision`, wrapped for `agent`. */
export type CopyToKeep = {
  readonly writing: WritingId;
  readonly agent: AgentId;
  readonly revision: Revision;
  readonly wrapped: Uint8Array;
};

/** Copies wrapped in the read mode that ends at `expires`. */
export type Copies = { readonly expires: number; readonly copies: readonly CopyToKeep[] };

/**
 * Why the server took no copy: the account's read mode isn't on until `expires`, the writing is
 * excluded, the agent isn't the account's or was revoked, or the writing's current revision is
 * another (or the server has none).
 */
export type CopyRefusal = "read-mode" | "excluded" | "agent" | "revision";

/** `{"publicKey", "signature"}` of `POST /agents`. */
export async function parseApproval(request: Request): Promise<Parsed<Approval>> {
  const body = await jsonBody(request);
  if (body === undefined) {
    return { ok: false, reason: "an approval is a JSON object sent as application/json" };
  }
  const publicKey = keyBytes(body["publicKey"]);
  const signature = keyBytes(body["signature"]);
  if (publicKey === undefined || signature === undefined) {
    return {
      ok: false,
      reason: `publicKey and signature are each 1 to ${keyBytesAtMost} bytes in lowercase hex`,
    };
  }
  return { ok: true, value: { publicKey, signature } };
}

/** `{"until"}` of `PUT /read-mode`: when read mode ends, in milliseconds since 1970. */
export async function parseUntil(request: Request, now: number): Promise<Parsed<number>> {
  const body = await jsonBody(request);
  const until = body === undefined ? undefined : whole(body["until"]);
  if (until === undefined) {
    return {
      ok: false,
      reason: `read mode is turned on with {"until"}, in milliseconds since 1970, as application/json`,
    };
  }
  if (until <= now) {
    return { ok: false, reason: "until has passed by the server's clock" };
  }
  return { ok: true, value: until };
}

/** `{"expires", "copies": [{"writing", "agent", "revision", "wrapped"}]}` of `POST /copies`. */
export async function parseCopies(request: Request): Promise<Parsed<Copies>> {
  const body = await jsonBody(request);
  const expires = body === undefined ? undefined : whole(body["expires"]);
  const sent = body?.["copies"];
  if (body === undefined || expires === undefined || !Array.isArray(sent)) {
    return {
      ok: false,
      reason: `copies are sent as {"expires", "copies"} in application/json`,
    };
  }
  if (sent.length === 0 || sent.length > copiesAtOnce) {
    return { ok: false, reason: `copies holds 1 to ${copiesAtOnce} copies` };
  }
  const copies: CopyToKeep[] = [];
  const seen = new Set<string>();
  for (const item of sent) {
    const copy = isJson(item) ? copyOf(item) : undefined;
    if (copy === undefined) {
      return {
        ok: false,
        reason: `each copy is {"writing", "agent", "revision", "wrapped"}: two UUIDs, a revision, and 1 to ${wrappedBytesAtMost} bytes in lowercase hex`,
      };
    }
    const key = `${copy.writing} ${copy.agent}`;
    if (seen.has(key)) {
      return { ok: false, reason: "copies holds one copy for each writing and agent" };
    }
    seen.add(key);
    copies.push(copy);
  }
  return { ok: true, value: { expires, copies } };
}

function copyOf(item: Json): CopyToKeep | undefined {
  const writing = parseWritingId(textOf(item["writing"]));
  const agent = parseAgentId(textOf(item["agent"]));
  const revision = parseRevision(textOf(item["revision"]));
  const wrapped = bytesOf(item["wrapped"], wrappedBytesAtMost);
  if (
    writing === undefined ||
    agent === undefined ||
    revision === undefined ||
    wrapped === undefined
  ) {
    return undefined;
  }
  return { writing, agent, revision, wrapped };
}

function keyBytes(value: unknown): Uint8Array | undefined {
  return bytesOf(value, keyBytesAtMost);
}

function bytesOf(value: unknown, atMost: number): Uint8Array | undefined {
  const bytes = parseHex(textOf(value));
  return bytes === undefined || bytes.length === 0 || bytes.length > atMost ? undefined : bytes;
}

function textOf(value: unknown): string {
  return typeof value === "string" ? value : "";
}
