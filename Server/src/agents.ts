import { base64url, sha256 } from "./sessions";
import { lowercaseUuid } from "./uuid";

/**
 * An agent's token is `agent.<agent ID>.<secret>`, the secret 32 random bytes in base64url. The
 * server keeps only the SHA-256 of the secret as written in the token (`agents.token_sha256`).
 * The token only reads the copies wrapped for its agent (`GET /agent/...`), and stops working
 * once its agent is revoked.
 */

/** An agent ID in the lowercase text form: a UUID the server made when the agent was approved. */
export type AgentId = string & { readonly brand: unique symbol };

export function parseAgentId(text: string): AgentId | undefined {
  const lowered = text.toLowerCase();
  return isAgentId(lowered) ? lowered : undefined;
}

function isAgentId(text: string): text is AgentId {
  return lowercaseUuid.test(text);
}

/** Who a request says it is: an agent, and the SHA-256 of the secret it was sent with. */
export type AgentCaller = { readonly agent: AgentId; readonly secretSha256: Uint8Array };

const tokenPattern =
  /^agent\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.([A-Za-z0-9_-]{43})$/;

export async function agentOf(authorization: string | null): Promise<AgentCaller | undefined> {
  if (authorization === null || !authorization.startsWith("Bearer ")) {
    return undefined;
  }
  const match = tokenPattern.exec(authorization.slice("Bearer ".length));
  const agent = parseAgentId(match?.[1] ?? "");
  const secret = match?.[2];
  if (agent === undefined || secret === undefined) {
    return undefined;
  }
  return { agent, secretSha256: await sha256(new TextEncoder().encode(secret)) };
}

/** A new agent's token, and what the server keeps of it. */
export async function newAgentToken(): Promise<{ token: string; caller: AgentCaller }> {
  const agent = parseAgentId(crypto.randomUUID());
  if (agent === undefined) {
    throw new Error("crypto.randomUUID() gives a lowercase UUID");
  }
  const secret = base64url(crypto.getRandomValues(new Uint8Array(32)));
  return {
    token: `agent.${agent}.${secret}`,
    caller: { agent, secretSha256: await sha256(new TextEncoder().encode(secret)) },
  };
}
