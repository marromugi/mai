import { agentOf, newAgentToken, parseAgentId } from "./agents";
import { answered } from "./answers";
import { parseWritingId } from "./envelope";
import { hex } from "./hex";
import { problem } from "./http";
import { liveAgentsAtMost, parseApproval, parseCopies, parseUntil } from "./read-mode";
import type { Caller } from "./sessions";
import type { Store } from "./store";

/** A request turned down for its own shape, answered so once its caller is let in. */
export type TurnedDown = (status: number, reason: string) => Promise<Response>;

/**
 * The device's read-mode routes (#26), under a session; undefined for a path that isn't one of
 * them. `path` is the URL's path split at `/`, without the empty part before the first `/`.
 */
export async function serveReadMode(
  request: Request,
  path: readonly string[],
  caller: Caller,
  store: Store,
  turnedDown: TurnedDown,
  now: number,
): Promise<Response | undefined> {
  const [first, id, ...rest] = path;
  if (rest.length > 0) {
    return undefined;
  }
  switch (first) {
    case "agents":
      return id === undefined
        ? agents(request, caller, store, turnedDown, now)
        : agent(request, id, caller, store, turnedDown, now);
    case "read-mode":
      return id === undefined ? readMode(request, caller, store, turnedDown, now) : undefined;
    case "exclusions":
      return id === undefined
        ? request.method === "GET"
          ? answered(await store.exclusions(caller, now), (exclusions) =>
              Response.json({ exclusions }),
            )
          : turnedDown(405, "/exclusions is only read, with GET")
        : exclusion(request, id, caller, store, turnedDown, now);
    case "copies":
      if (id !== undefined) {
        return undefined;
      }
      if (request.method !== "POST") {
        return turnedDown(405, "copies are sent with POST");
      }
      return keepCopies(request, caller, store, turnedDown, now);
    case undefined:
    default:
      return undefined;
  }
}

async function agents(
  request: Request,
  caller: Caller,
  store: Store,
  turnedDown: TurnedDown,
  now: number,
): Promise<Response> {
  switch (request.method) {
    case "GET":
      return answered(await store.agents(caller, now), (all) =>
        Response.json({
          agents: all.map((one) => ({
            id: one.id,
            publicKey: hex(one.publicKey),
            signature: hex(one.signature),
            revoked: one.revoked,
          })),
        }),
      );
    case "POST": {
      const approval = await parseApproval(request);
      if (!approval.ok) {
        return turnedDown(400, approval.reason);
      }
      const token = await newAgentToken();
      return answered(await store.approveAgent(caller, approval.value, token.caller, now), (made) =>
        made.approved
          ? Response.json({ agent: made.agent, token: token.token }, { status: 201 })
          : problem(
              409,
              made.reason === "too-many"
                ? `the account has ${liveAgentsAtMost} agents already; revoke one to approve another`
                : "an agent with this public key was revoked; an agent needs a new key",
            ),
      );
    }
    default:
      return turnedDown(405, "agents are listed with GET and approved with POST");
  }
}

async function agent(
  request: Request,
  text: string,
  caller: Caller,
  store: Store,
  turnedDown: TurnedDown,
  now: number,
): Promise<Response> {
  const id = parseAgentId(text);
  if (id === undefined) {
    return turnedDown(404, "an agent's ID is a UUID");
  }
  if (request.method !== "DELETE") {
    return turnedDown(405, "an agent is revoked with DELETE");
  }
  return answered(await store.revokeAgent(caller, id, now), (revoked) =>
    revoked ? new Response(null, { status: 204 }) : problem(404, "the account has no such agent"),
  );
}

async function readMode(
  request: Request,
  caller: Caller,
  store: Store,
  turnedDown: TurnedDown,
  now: number,
): Promise<Response> {
  switch (request.method) {
    case "GET":
      return answered(await store.readMode(caller, now), (until) => Response.json({ until }));
    case "PUT": {
      const until = await parseUntil(request, now);
      if (!until.ok) {
        return turnedDown(400, until.reason);
      }
      return answered(await store.turnOnReadMode(caller, until.value, now), () =>
        Response.json({ until: until.value }),
      );
    }
    case "DELETE":
      return answered(
        await store.turnOffReadMode(caller, now),
        () => new Response(null, { status: 204 }),
      );
    default:
      return turnedDown(405, "read mode is read with GET, turned on with PUT and off with DELETE");
  }
}

async function exclusion(
  request: Request,
  text: string,
  caller: Caller,
  store: Store,
  turnedDown: TurnedDown,
  now: number,
): Promise<Response> {
  const id = parseWritingId(text);
  if (id === undefined) {
    return turnedDown(404, "a writing's ID is a UUID");
  }
  switch (request.method) {
    case "PUT":
      return answered(
        await store.exclude(caller, id, now),
        () => new Response(null, { status: 204 }),
      );
    case "DELETE":
      return answered(
        await store.include(caller, id, now),
        () => new Response(null, { status: 204 }),
      );
    default:
      return turnedDown(
        405,
        "a writing is excluded with PUT, and the exclusion taken off with DELETE",
      );
  }
}

async function keepCopies(
  request: Request,
  caller: Caller,
  store: Store,
  turnedDown: TurnedDown,
  now: number,
): Promise<Response> {
  const copies = await parseCopies(request);
  if (!copies.ok) {
    return turnedDown(400, copies.reason);
  }
  return answered(await store.keepCopies(caller, copies.value, now), (kept) =>
    Response.json({ copies: kept }),
  );
}

/**
 * The agent's routes, under `/agent/`, which only read: the writings it has a copy for, and each
 * of them with its key wrapped for it.
 */
export async function serveAgent(request: Request, store: Store, now: number): Promise<Response> {
  const caller = await agentOf(request.headers.get("Authorization"));
  if (caller === undefined) {
    return problem(401, "the Authorization header doesn't hold an agent token");
  }
  const turnedDown = async (status: number, reason: string): Promise<Response> =>
    answered(await store.admit(caller, now), () => problem(status, reason));
  const path = new URL(request.url).pathname.split("/").slice(1);
  if (path[1] !== "writings" || path.length > 3) {
    return turnedDown(404, "an agent reads /agent/writings and /agent/writings/<ID>");
  }
  if (request.method !== "GET") {
    return turnedDown(405, "an agent only reads, with GET");
  }
  if (path.length === 2) {
    return answered(await store.agentWritings(caller, now), (writings) =>
      Response.json({ writings }),
    );
  }
  const id = parseWritingId(path[2] ?? "");
  if (id === undefined) {
    return turnedDown(404, "a writing's ID is a UUID");
  }
  return answered(await store.agentRead(caller, id, now), (read) =>
    read === undefined
      ? problem(404, "the agent has no copy of this writing, or it has expired")
      : new Response(read.bytes, {
          headers: {
            "Content-Type": "application/octet-stream",
            "Mai-Revision": read.revision,
            "Mai-Wrapped-Key": hex(read.wrapped),
            "Mai-Expires": String(read.expires),
          },
        }),
  );
}
