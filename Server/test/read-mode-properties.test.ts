import { env } from "cloudflare:test";
import { createClient } from "@libsql/client/web";
import * as fc from "fast-check";
import { expect, it } from "vitest";
import type { AccountId } from "../src/account-id";
import { newAccount, store } from "./accounts";
import { callAt, type Sent } from "./calls";
import { sealedWriting } from "./envelopes";

/**
 * The properties of `Specs/ReadMode` that are about the server, checked on the Worker and sqld
 * after each step of random runs of the model's operations. A device's view may be stale: copies
 * may be sent for any period and revision seen before, as the model's `view[d]` and `clock[d]`
 * allow, and for revoked agents, and the server must turn down what breaks a property.
 */

const database = createClient({ url: env.TURSO_URL });
/** The model's unit of time, in milliseconds. */
const tick = 100;
const writingCount = 2;

/** Mostly the latest seen, else one of the three before it: a device's stale view. */
const back = fc.oneof({ arbitrary: fc.constant(0), weight: 3 }, fc.integer({ min: 1, max: 3 }));
const writingIndex = fc.nat(writingCount - 1);

const step = fc.oneof(
  { arbitrary: fc.record({ op: fc.constant("save"), writing: writingIndex }), weight: 2 },
  fc.record({ op: fc.constant("turnOn"), ticks: fc.integer({ min: 30, max: 180 }) }),
  fc.record({ op: fc.constant("turnOff") }),
  fc.record({ op: fc.constant("exclude"), writing: writingIndex }),
  fc.record({ op: fc.constant("include"), writing: writingIndex }),
  fc.record({ op: fc.constant("approve") }),
  fc.record({ op: fc.constant("revoke"), agent: fc.nat(2) }),
  {
    arbitrary: fc.record({ op: fc.constant("tick"), ticks: fc.integer({ min: 1, max: 70 }) }),
    weight: 2,
  },
  fc.record({ op: fc.constant("sweep") }),
  { arbitrary: fc.record({ op: fc.constant("fetch") }), weight: 2 },
  {
    arbitrary: fc.record({
      op: fc.constant("copy"),
      period: back,
      revisions: fc.array(back, { minLength: writingCount, maxLength: writingCount }),
    }),
    weight: 3,
  },
);
type Step = typeof step extends fc.Arbitrary<infer T> ? T : never;

/** Each run starts with what lets copies be kept, so that the steps after it reach them. */
const start: Step[] = [
  { op: "approve" },
  { op: "save", writing: 0 },
  { op: "save", writing: 1 },
  { op: "turnOn", ticks: 60 },
  { op: "copy", period: 0, revisions: [0, 0] },
];

/**
 * How many copies the server kept, agents were served, and sweeps found expired, over every run.
 */
type Reached = { kept: number; served: number; swept: number };

/** What the devices have seen, which the steps pick from: not the server's state. */
type Seen = {
  /** The server's time. */
  now: number;
  token: string;
  account: AccountId;
  writings: string[];
  /** Every revision each writing was saved as, newest last. */
  revisions: string[][];
  /** Every agent approved, revoked ones included. */
  agents: { agent: string; token: string }[];
  /** Every end read mode was turned on with. */
  periods: number[];
  saves: number;
};

function call(seen: Seen, path: string, token: string, sent: Sent = {}): Promise<Response> {
  return callAt(seen.now, path, token, sent);
}

async function run(seen: Seen, next: Step, reached: Reached): Promise<void> {
  const writing = (index: number): string => seen.writings[index] ?? "";
  switch (next.op) {
    case "save": {
      const revisions = seen.revisions[next.writing] ?? [];
      seen.saves += 1;
      const saved = await call(seen, `/writings/${writing(next.writing)}`, seen.token, {
        method: "PUT",
        body: sealedWriting({
          writing: writing(next.writing),
          updated: 1_790_000_000_000n + BigInt(seen.saves),
        }),
        base: revisions.at(-1) ?? "none",
      });
      expect(saved.status).toBe(200);
      revisions.push((await saved.json<{ revision: string }>()).revision);
      seen.revisions[next.writing] = revisions;
      return;
    }
    case "turnOn": {
      const until = seen.now + next.ticks * tick;
      const on = await call(seen, "/read-mode", seen.token, { method: "PUT", json: { until } });
      expect(on.status).toBe(200);
      seen.periods.push(until);
      return;
    }
    case "turnOff":
      expect((await call(seen, "/read-mode", seen.token, { method: "DELETE" })).status).toBe(204);
      return;
    case "exclude":
    case "include": {
      const method = next.op === "exclude" ? "PUT" : "DELETE";
      const marked = await call(seen, `/exclusions/${writing(next.writing)}`, seen.token, {
        method,
      });
      expect(marked.status).toBe(204);
      return;
    }
    case "approve": {
      if (seen.agents.length > 2) {
        return;
      }
      const approved = await call(seen, "/agents", seen.token, {
        method: "POST",
        // A new key each time: a revoked key is never approved again.
        json: { publicKey: `0${seen.agents.length}`, signature: "bb" },
      });
      expect(approved.status).toBe(201);
      seen.agents.push(await approved.json<{ agent: string; token: string }>());
      return;
    }
    case "revoke": {
      const agent = seen.agents[next.agent];
      if (agent !== undefined) {
        const revoked = await call(seen, `/agents/${agent.agent}`, seen.token, {
          method: "DELETE",
        });
        expect(revoked.status).toBe(204);
      }
      return;
    }
    case "tick":
      seen.now += next.ticks * tick;
      return;
    case "sweep":
      reached.swept += await count("copies WHERE account_id = :account AND expires <= :now", seen);
      await store.sweepReadMode(seen.now, [seen.account]);
      // ExpiredCopiesSwept and ModeEndsOnTime: after a sweep, until the time moves on.
      expect(await count("copies WHERE account_id = :account AND expires <= :now", seen)).toBe(0);
      expect(await count("read_modes WHERE account_id = :account AND until <= :now", seen)).toBe(0);
      return;
    case "fetch":
      for (const agent of seen.agents) {
        for (const id of seen.writings) {
          const read = await call(seen, `/agent/writings/${id}`, agent.token);
          // NoServedCopyPastExpiry.
          if (read.status === 200) {
            expect(Number(read.headers.get("Mai-Expires"))).toBeGreaterThan(seen.now);
            reached.served += 1;
          } else {
            expect([401, 404]).toContain(read.status);
          }
          await read.body?.cancel();
        }
      }
      return;
    case "copy": {
      const expires = seen.periods.at(-1 - next.period);
      const copies = seen.agents.flatMap((agent) =>
        seen.writings.flatMap((id, index) => {
          const revision = (seen.revisions[index] ?? []).at(-1 - (next.revisions[index] ?? 0));
          return revision === undefined
            ? []
            : [{ writing: id, agent: agent.agent, revision, wrapped: "cc" }];
        }),
      );
      if (expires === undefined || copies.length === 0) {
        return;
      }
      const sent = await call(seen, "/copies", seen.token, {
        method: "POST",
        json: { expires, copies },
      });
      expect(sent.status).toBe(200);
      const answer = await sent.json<{ copies: { refused: string | null }[] }>();
      reached.kept += answer.copies.filter((copy) => copy.refused === null).length;
      return;
    }
  }
}

async function count(from: string, seen: Seen): Promise<number> {
  const { rows } = await database.execute({
    sql: `SELECT count(*) AS count FROM ${from}`,
    args: { account: seen.account, ...(from.includes(":now") ? { now: seen.now } : {}) },
  });
  return Number(rows[0]?.["count"]);
}

/** The properties that hold in every state. */
async function holds(seen: Seen): Promise<void> {
  // NoCopyOfExcluded.
  expect(
    await count(
      `copies c JOIN exclusions e ON e.account_id = c.account_id AND e.writing_id = c.writing_id
       WHERE c.account_id = :account`,
      seen,
    ),
  ).toBe(0);
  // NoCopyOutsideMode: a copy only while the server holds a read mode, ending when it ends.
  expect(
    await count(
      `copies c WHERE c.account_id = :account AND NOT EXISTS (
         SELECT 1 FROM read_modes m WHERE m.account_id = c.account_id AND m.until = c.expires)`,
      seen,
    ),
  ).toBe(0);
  // NoCopyForRevokedKey.
  expect(
    await count(
      `copies c JOIN agents g ON g.id = c.agent_id
       WHERE c.account_id = :account AND (g.revoked = 1 OR g.account_id != c.account_id)`,
      seen,
    ),
  ).toBe(0);
  // CopyIsOfCurrentVersion.
  expect(
    await count(
      `copies c WHERE c.account_id = :account AND NOT EXISTS (
         SELECT 1 FROM writings w
         WHERE w.account_id = c.account_id AND w.id = c.writing_id AND w.revision = c.revision)`,
      seen,
    ),
  ).toBe(0);
}

it("keeps the server's properties of Specs/ReadMode over any run of its operations", async () => {
  const reached: Reached = { kept: 0, served: 0, swept: 0 };
  await fc.assert(
    fc.asyncProperty(
      fc.array(step, { minLength: 1, maxLength: 30, size: "max" }),
      async (steps) => {
        const { account, token } = await newAccount();
        const seen: Seen = {
          now: Date.now(),
          token,
          account,
          writings: Array.from({ length: writingCount }, () => crypto.randomUUID()),
          revisions: [],
          agents: [],
          periods: [],
          saves: 0,
        };
        for (const next of [...start, ...steps]) {
          await run(seen, next, reached);
          await holds(seen);
        }
      },
    ),
    { numRuns: 100 },
  );
  // The runs reach the states the properties are about.
  expect(reached.kept).toBeGreaterThan(100);
  expect(reached.served).toBeGreaterThan(20);
  expect(reached.swept).toBeGreaterThan(0);
}, 120_000);
