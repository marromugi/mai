import { problem } from "./http";
import type { Answer, Limit, Refusal } from "./store";

/** `respond` to what the store answered, or the refusal's status and reason when it refused. */
export function answered<T>(answer: Answer<T>, respond: (value: T) => Response): Response {
  return answer.ok ? respond(answer.value) : refused(answer.refusal);
}

const refusals: Record<Exclude<Refusal, Limit>, { status: number; reason: string }> = {
  session: { status: 401, reason: "the session token is unknown, or its session has ended" },
  agent: { status: 401, reason: "the agent token is unknown, or its agent was revoked" },
  lapsed: {
    status: 402,
    reason: "the account's subscription has lapsed; it is read but not written",
  },
};

const limits: Record<Limit, string> = {
  requests: "the plan's requests for today are used up",
  lists: "the plan's listings for today are used up",
  saves: "the plan's saves for today are used up",
  photos: "the plan's photos for today are used up",
  storage: "the plan's storage for writings is full",
  "photo-storage": "the plan's storage for photos has no room for this",
};

function isLimit(refusal: Refusal): refusal is Limit {
  return Object.hasOwn(limits, refusal);
}

/** A limit reached is 429 with `{"error", "limit"}`, `limit` naming which. */
export function refused(refusal: Refusal): Response {
  if (isLimit(refusal)) {
    return Response.json({ error: limits[refusal], limit: refusal }, { status: 429 });
  }
  const { status, reason } = refusals[refusal];
  return problem(status, reason);
}
