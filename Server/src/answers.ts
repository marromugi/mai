import { problem } from "./http";
import type { Answer, Refusal } from "./store";

/** `respond` to what the store answered, or the refusal's status and reason when it refused. */
export function answered<T>(answer: Answer<T>, respond: (value: T) => Response): Response {
  return answer.ok ? respond(answer.value) : refused(answer.refusal);
}

const refusals: Record<Refusal, { status: number; reason: string }> = {
  session: { status: 401, reason: "the session token is unknown, or its session has ended" },
  agent: { status: 401, reason: "the agent token is unknown, or its agent was revoked" },
  lapsed: {
    status: 402,
    reason: "the account's subscription has lapsed; it is read but not written",
  },
  requests: { status: 429, reason: "the plan's requests for today are used up" },
  lists: { status: 429, reason: "the plan's listings for today are used up" },
  saves: { status: 429, reason: "the plan's saves for today are used up" },
  photos: { status: 429, reason: "the plan's photos for today are used up" },
  storage: { status: 429, reason: "the plan's storage for writings is full" },
  "photo-storage": { status: 429, reason: "the plan's storage for photos has no room for this" },
};

export function refused(refusal: Refusal): Response {
  const { status, reason } = refusals[refusal];
  return problem(status, reason);
}
