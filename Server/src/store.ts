import { createClient, LibsqlError } from "@libsql/client/web";
import type { Client, InStatement, InValue, ResultSet } from "@libsql/client/web";
import {
  parseRevision,
  parseWritingId,
  type Envelope,
  type Revision,
  type WritingId,
} from "./envelope";
import { parseAccountId, type AccountId } from "./account-id";
import type { Challenge } from "./challenges";
import { lastUsedResolution, sessionLifetime, type Caller } from "./sessions";
import type { Environment } from "./app-store";

/**
 * The only file that speaks to Turso. Every request is one `batch()`, so one round trip and one
 * transaction: it checks the caller, does the work only when the caller may, and counts it.
 * The tables are in `Server/schema.sql`.
 */

export type Listed = { id: WritingId; revision: Revision; updated: number; size: number };

/**
 * Why a caller was turned away: no live session, a write to an account whose subscription has
 * lapsed, or a limit of its plan reached.
 */
export type Refusal = "session" | "lapsed" | Limit;
export type Limit = "requests" | "lists" | "saves" | "storage";

export type Answer<T> = { ok: true; value: T } | { ok: false; refusal: Refusal };

export type Saved = { saved: boolean; revision: Revision | null };

export type Read = { revision: Revision; bytes: ArrayBuffer } | undefined;

export type NewAccount = {
  readonly id: AccountId;
  readonly appleSub: string;
  /** Apple's refresh token as `RefreshTokens.seal` sealed it for this account. */
  readonly sealedRefreshToken: Uint8Array;
  /** The subscription the account is made for; its product picks the plan. */
  readonly purchase: Purchase;
};

/** One subscription, as `subscriptions` keeps it. */
export type Purchase = {
  readonly originalTransactionId: string;
  /** The transaction's `appAccountToken`. */
  readonly account: AccountId | undefined;
  readonly productId: string;
  /** The transaction's `expiresDate`: when the billing period it is about ends. */
  readonly periodEnds: number;
  /** When that period ends, the end of its billing grace period if later, or when it was refunded or revoked. */
  readonly paidUntil: number;
  readonly revoked: boolean;
  readonly environment: Environment;
  /**
   * When the App Store signed what this was read from. It replaces what is kept only when signed
   * later and about the same or a later billing period.
   */
  readonly signedDate: number;
};

/**
 * `taken`: the account's ID or its Apple user has an account already. `purchase-taken`: the
 * subscription is another account's. `no-plan`: no plan is sold as the subscription's product.
 */
export type Made = "made" | "challenge-used" | "taken" | "purchase-taken" | "no-plan";

/** What an account's own resent subscription did: the account's plan and paid-until time after it. */
export type Kept =
  | { kept: "kept"; tier: string; paidUntil: number }
  | { kept: "another-account" | "no-plan" };

export type SignedIn =
  | { signedIn: true; account: AccountId }
  | { signedIn: false; reason: "challenge-used" | "no-account" };

/**
 * What a request counts against its plan's daily limits, beside the request itself. `save` and
 * `write` write the account's data, which only a paid-for account may do; only `save` is counted.
 */
type Counted = "list" | "save" | "write" | "other";

type Statement = { sql: string; args?: Record<string, InValue> };

const day = 24 * 60 * 60 * 1000;

/**
 * Uses up a challenge, inserting it only when no request used it before and it hasn't expired by
 * the time of the write; see `#claiming`.
 */
const claimStatement = `INSERT INTO used_challenges (value, expires, claim)
  SELECT :challenge, :expires, :claim WHERE :expires > :now
  ON CONFLICT (value) DO NOTHING`;

/**
 * A used challenge is swept this long after it expires, so a request that claims one just before
 * it expires still finds it there, however late its batch reaches the database.
 */
export const usedChallengeMargin = 60 * 60 * 1000;
const claimed = `EXISTS (SELECT 1 FROM used_challenges WHERE value = :challenge AND claim = :claim)`;

export class Store {
  readonly #client: Client;

  constructor(client: Client) {
    this.#client = client;
  }

  static open(url: string, authToken: string): Store {
    return new Store(createClient(authToken === "" ? { url } : { url, authToken }));
  }

  async list(caller: Caller, now: number): Promise<Answer<Listed[]>> {
    const answer = await this.#run(caller, now, "list", (account, allowed) => [
      {
        sql: `SELECT id, revision, updated, size FROM writings
              WHERE account_id = ${account} AND ${allowed}`,
      },
    ]);
    if (!answer.ok) {
      return answer;
    }
    return {
      ok: true,
      value: (answer.value[0]?.rows ?? []).map((row) => ({
        id: stored(parseWritingId, row["id"]),
        revision: stored(parseRevision, row["revision"]),
        updated: Number(row["updated"]),
        size: Number(row["size"]),
      })),
    };
  }

  async read(caller: Caller, id: WritingId, now: number): Promise<Answer<Read>> {
    const answer = await this.#run(caller, now, "other", (account, allowed) => [
      {
        sql: `SELECT revision, envelope FROM writings
              WHERE account_id = ${account} AND id = :id AND ${allowed}`,
        args: { id },
      },
    ]);
    if (!answer.ok) {
      return answer;
    }
    const row = answer.value[0]?.rows[0];
    if (row === undefined) {
      return { ok: true, value: undefined };
    }
    const envelope = row["envelope"];
    if (!(envelope instanceof ArrayBuffer)) {
      throw new Error("writings.envelope is a BLOB, but came back as something else");
    }
    return {
      ok: true,
      value: { revision: stored(parseRevision, row["revision"]), bytes: envelope },
    };
  }

  /** Saves `envelope` only when `base` is the writing's current revision, null for none yet. */
  async save(
    caller: Caller,
    envelope: Envelope,
    base: Revision | null,
    now: number,
  ): Promise<Answer<Saved>> {
    const writing = {
      id: envelope.id,
      revision: envelope.revision,
      updated: envelope.updated,
      size: envelope.bytes.byteLength,
      envelope: envelope.bytes,
    };
    let answer;
    try {
      answer = await this.#run(caller, now, "save", (account, allowed) => [
        base === null
          ? {
              sql: `INSERT INTO writings (account_id, id, revision, updated, size, envelope)
                    SELECT ${account}, :id, :revision, :updated, :size, :envelope WHERE ${allowed}
                    ON CONFLICT (account_id, id) DO NOTHING`,
              args: writing,
            }
          : {
              sql: `UPDATE writings
                    SET revision = :revision, updated = :updated, size = :size, envelope = :envelope
                    WHERE account_id = ${account} AND id = :id AND revision = :base AND ${allowed}`,
              args: { ...writing, base },
            },
        {
          sql: `SELECT revision FROM writings WHERE account_id = ${account} AND id = :id`,
          args: { id: envelope.id },
        },
      ]);
    } catch (error) {
      if (error instanceof LibsqlError && error.message.includes("mai: over the plan's storage")) {
        return { ok: false, refusal: "storage" };
      }
      throw error;
    }
    if (!answer.ok) {
      return answer;
    }
    const [written, current] = answer.value;
    const revision = current?.rows[0]?.["revision"];
    return {
      ok: true,
      value: {
        saved: written?.rowsAffected === 1,
        revision: revision === undefined ? null : stored(parseRevision, revision),
      },
    };
  }

  /** Checks the caller and counts the request, for a request that does nothing else. */
  async admit(caller: Caller, now: number): Promise<Answer<undefined>> {
    const answer = await this.#run(caller, now, "other", () => []);
    return answer.ok ? { ok: true, value: undefined } : answer;
  }

  /**
   * Makes the account, its subscription and its first session, using up `challenge`. Nothing is
   * written when the challenge was used before or has expired, when the account's ID or Apple
   * user already has an account, when the subscription is another account's, or when no plan is
   * sold as its product; the challenge is used up all the same.
   */
  async makeAccount(
    account: NewAccount,
    challenge: Challenge,
    session: Caller,
    now: number,
  ): Promise<Made> {
    const madeHere = `id = :id AND apple_sub = :sub AND apple_refresh_token = :refresh AND ${claimed}`;
    const results = await this.#claiming(
      now,
      challenge,
      [
        `SELECT ${plan} AS plan, EXISTS (SELECT 1 FROM subscriptions
                   WHERE original_transaction_id = :original AND account_id != :id) AS taken`,
        `INSERT INTO accounts (id, apple_sub, apple_refresh_token, tier, paid_until, created)
         SELECT :id, :sub, :refresh, tier, :paid, :now FROM plans
         WHERE product_id = :product AND ${claimed}
           AND NOT EXISTS (SELECT 1 FROM accounts WHERE id = :id OR apple_sub = :sub)
           AND NOT EXISTS (SELECT 1 FROM subscriptions WHERE original_transaction_id = :original)`,
        `INSERT INTO subscriptions (original_transaction_id, account_id, product_id, period_ends,
           paid_until, environment, signed_date)
         SELECT :original, id, :product, :period, :paid, :environment, :signed FROM accounts
         WHERE ${madeHere}
         ON CONFLICT (original_transaction_id) DO NOTHING`,
        `INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
         SELECT :session, id, :hash, :now, :now FROM accounts WHERE ${madeHere}`,
      ],
      {
        ...purchaseValues(account.purchase),
        id: account.id,
        sub: account.appleSub,
        refresh: account.sealedRefreshToken,
        session: session.session,
        hash: session.secretSha256,
        now,
      },
    );
    if (results === undefined) {
      return "challenge-used";
    }
    const [found, made] = results;
    if (made?.rowsAffected === 1) {
      return "made";
    }
    const row = found?.rows[0];
    if (Number(row?.["plan"]) !== 1) {
      return "no-plan";
    }
    return Number(row?.["taken"]) === 1 ? "purchase-taken" : "taken";
  }

  /**
   * Keeps the caller's own subscription, as the app resends it, when it is newer than what is
   * kept. Answers the account's plan and paid-until time after it.
   */
  async keepPurchase(caller: Caller, purchase: Purchase, now: number): Promise<Answer<Kept>> {
    const answer = await this.#run(caller, now, "other", (account, allowed) => {
      const mine = `coalesce(:account = ${account}, 0) AND NOT EXISTS (SELECT 1 FROM subscriptions
        WHERE original_transaction_id = :original AND account_id != :account)`;
      return [
        `SELECT ${plan} AS plan, ${mine} AS mine`,
        ...keepStatements(`${mine} AND ${allowed}`),
        `SELECT tier, paid_until FROM accounts WHERE id = ${account}`,
      ].map((sql) => ({
        sql,
        args: { ...purchaseValues(purchase), account: purchase.account ?? null },
      }));
    });
    if (!answer.ok) {
      return answer;
    }
    const found = answer.value[0]?.rows[0];
    const account = answer.value.at(-1)?.rows[0];
    if (Number(found?.["mine"]) !== 1) {
      return { ok: true, value: { kept: "another-account" } };
    }
    if (Number(found?.["plan"]) !== 1) {
      return { ok: true, value: { kept: "no-plan" } };
    }
    return {
      ok: true,
      value: {
        kept: "kept",
        tier: stored((tier) => tier, account?.["tier"]),
        paidUntil: Number(account?.["paid_until"]),
      },
    };
  }

  /**
   * Keeps a subscription as an App Store notification tells of it, when it is newer than what is
   * kept. A subscription not kept yet is kept only for an account its `appAccountToken` names.
   */
  async keepNotified(purchase: Purchase): Promise<void> {
    await this.#client.batch(
      keepStatements("true").map((sql) =>
        bind(sql, { ...purchaseValues(purchase), account: purchase.account ?? null }),
      ),
      "write",
    );
  }

  /** Starts a session on the Apple user's account, using up `challenge`. */
  async signIn(
    appleSub: string,
    challenge: Challenge,
    session: Caller,
    now: number,
  ): Promise<SignedIn> {
    const results = await this.#claiming(
      now,
      challenge,
      [
        `INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
         SELECT :session, id, :hash, :now, :now FROM accounts WHERE apple_sub = :sub AND ${claimed}`,
        `SELECT id FROM accounts WHERE apple_sub = :sub AND ${claimed}`,
      ],
      { sub: appleSub, session: session.session, hash: session.secretSha256, now },
    );
    if (results === undefined) {
      return { signedIn: false, reason: "challenge-used" };
    }
    const [started, account] = results;
    const row = account?.rows[0];
    if (started?.rowsAffected !== 1 || row === undefined) {
      return { signedIn: false, reason: "no-account" };
    }
    return {
      signedIn: true,
      account: stored(parseAccountId, row["id"]),
    };
  }

  /** Ends the caller's session; false when it had no live session to end. */
  async endSession(caller: Caller, now: number): Promise<boolean> {
    const ended = await this.#client.execute({
      sql: `DELETE FROM sessions WHERE id = :session AND token_sha256 = :hash AND last_used > :alive`,
      args: { session: caller.session, hash: caller.secretSha256, alive: now - sessionLifetime },
    });
    return ended.rowsAffected === 1;
  }

  /**
   * Keeps `check` as the account's own key check when it has none. Answers whether the account's
   * check is now `check`: false means another own key was made first.
   */
  async keepOwnKeyCheck(caller: Caller, check: Uint8Array, now: number): Promise<Answer<boolean>> {
    const answer = await this.#run(caller, now, "write", (account, allowed) => [
      {
        sql: `UPDATE accounts SET own_key_check = :check
              WHERE id = ${account} AND own_key_check IS NULL AND ${allowed}`,
        args: { check },
      },
      {
        sql: `SELECT own_key_check = :check AS same FROM accounts WHERE id = ${account}`,
        args: { check },
      },
    ]);
    if (!answer.ok) {
      return answer;
    }
    return { ok: true, value: Number(answer.value[1]?.rows[0]?.["same"]) === 1 };
  }

  /** Removes what has expired by `now`; run by the Worker's cron trigger. */
  async sweep(now: number): Promise<void> {
    await this.#client.batch(
      [
        {
          sql: "DELETE FROM sessions WHERE last_used <= :expired",
          args: { expired: now - sessionLifetime },
        },
        { sql: "DELETE FROM usage WHERE day < :today", args: { today: Math.floor(now / day) } },
        {
          sql: "DELETE FROM used_challenges WHERE expires <= :swept",
          args: { swept: now - usedChallengeMargin },
        },
      ],
      "write",
    );
  }

  /**
   * Uses up `challenge` and runs `statements` in one batch. The statements hold `claimed` in
   * their WHERE, so they do nothing when another request used the challenge first, or it expired
   * by `now`; then this
   * answers undefined, and otherwise the statements' results.
   */
  async #claiming(
    now: number,
    challenge: Challenge,
    statements: string[],
    values: Record<string, InValue>,
  ): Promise<ResultSet[] | undefined> {
    const all = {
      ...values,
      now,
      challenge: challenge.value,
      expires: challenge.expires,
      claim: crypto.randomUUID(),
    };
    const [used, ...results] = await this.#client.batch(
      [claimStatement, ...statements].map((sql) => bind(sql, all)),
      "write",
    );
    return used?.rowsAffected === 1 ? results : undefined;
  }

  /**
   * Runs `work` for the caller in one batch: first what the caller may do, then `work`, whose
   * statements must hold `allowed` in their WHERE so they do nothing for a caller turned away,
   * then the count against the plan. Answers the results of `work`'s statements.
   */
  async #run(
    caller: Caller,
    now: number,
    counted: Counted,
    work: (account: string, allowed: string) => Statement[],
  ): Promise<Answer<ResultSet[]>> {
    const args: Record<string, InValue> = {
      session: caller.session,
      hash: caller.secretSha256,
      now,
      alive: now - sessionLifetime,
      stale: now - lastUsedResolution,
      day: Math.floor(now / day),
      list: counted === "list" ? 1 : 0,
      save: counted === "save" ? 1 : 0,
      write: counted === "save" || counted === "write" ? 1 : 0,
    };
    const callerRows = `FROM sessions s
      JOIN accounts a ON a.id = s.account_id
      JOIN plans p ON p.tier = a.tier
      LEFT JOIN usage u ON u.account_id = a.id AND u.day = :day
      WHERE s.id = :session AND s.token_sha256 = :hash AND s.last_used > :alive`;
    // An account writes only while its subscription is paid for.
    const paid = "(:write = 0 OR a.paid_until > :now)";
    const left = {
      requests: "coalesce(u.requests, 0) < p.requests_per_day",
      lists: "(:list = 0 OR coalesce(u.lists, 0) < p.lists_per_day)",
      saves: "(:save = 0 OR coalesce(u.saves, 0) < p.saves_per_day)",
    };
    const allowed = `EXISTS (SELECT 1 ${callerRows}
      AND ${paid} AND ${left.requests} AND ${left.lists} AND ${left.saves})`;
    const account = "(SELECT account_id FROM sessions WHERE id = :session)";
    const statements = work(account, allowed);

    const results = await this.#client.batch(
      [
        {
          sql: `SELECT ${paid} AS lapsed, ${left.requests} AS requests, ${left.lists} AS lists,
                ${left.saves} AS saves ${callerRows}`,
        },
        ...statements,
        {
          sql: `INSERT INTO usage (account_id, day, requests, lists, saves)
                SELECT ${account}, :day, 1, :list, :save WHERE ${allowed}
                ON CONFLICT (account_id, day) DO UPDATE SET requests = requests + 1,
                  lists = lists + excluded.lists, saves = saves + excluded.saves`,
        },
        {
          sql: `UPDATE sessions SET last_used = :now
                WHERE id = :session AND token_sha256 = :hash
                  AND last_used > :alive AND last_used <= :stale`,
        },
      ].map((statement: Statement) => bind(statement.sql, { ...args, ...statement.args })),
      "write",
    );

    const gate = results[0]?.rows[0];
    if (gate === undefined) {
      return { ok: false, refusal: "session" };
    }
    for (const limit of ["lapsed", "requests", "lists", "saves"] as const) {
      if (Number(gate[limit]) !== 1) {
        return { ok: false, refusal: limit };
      }
    }
    return { ok: true, value: results.slice(1, 1 + statements.length) };
  }
}

/** Whether a plan is sold as the subscription's product, `:product`. */
const plan = "EXISTS (SELECT 1 FROM plans WHERE product_id = :product)";

function purchaseValues(purchase: Purchase): Record<string, InValue> {
  return {
    original: purchase.originalTransactionId,
    product: purchase.productId,
    period: purchase.periodEnds,
    paid: purchase.paidUntil,
    environment: purchase.environment,
    signed: purchase.signedDate,
  };
}

/**
 * Replaces the kept subscription `:original` with newer data about the same or a later billing
 * period, or keeps it for the account `:account` when it isn't kept yet; then sets its account's
 * plan and paid-until time from all of the account's subscriptions (on a tie, the larger plan).
 * Each statement holds `condition` in its WHERE.
 */
function keepStatements(condition: string): string[] {
  return [
    `UPDATE subscriptions SET product_id = :product, period_ends = :period, paid_until = :paid,
       environment = :environment, signed_date = :signed
     WHERE original_transaction_id = :original AND signed_date < :signed
       AND period_ends <= :period AND ${plan} AND ${condition}`,
    `INSERT INTO subscriptions (original_transaction_id, account_id, product_id, period_ends,
       paid_until, environment, signed_date)
     SELECT :original, id, :product, :period, :paid, :environment, :signed FROM accounts
     WHERE id = :account AND ${plan} AND ${condition}
     ON CONFLICT (original_transaction_id) DO NOTHING`,
    `UPDATE accounts SET
       paid_until = (SELECT max(paid_until) FROM subscriptions WHERE account_id = accounts.id),
       tier = coalesce((SELECT p.tier FROM subscriptions s JOIN plans p ON p.product_id = s.product_id
                        WHERE s.account_id = accounts.id
                        ORDER BY s.paid_until DESC, p.writings_bytes DESC LIMIT 1), tier)
     WHERE id = (SELECT account_id FROM subscriptions WHERE original_transaction_id = :original)
       AND ${condition}`,
  ];
}

/** A value read back from a column only this file writes, which holds only valid values. */
function stored<T>(parse: (text: string) => T | undefined, value: unknown): T {
  const parsed = typeof value === "string" ? parse(value) : undefined;
  if (parsed === undefined) {
    throw new Error(`the database holds ${String(value)} where this file wrote a valid value`);
  }
  return parsed;
}

/** `sql` with the values of the parameters it names, since the server refuses any others. */
function bind(sql: string, values: Record<string, InValue>): InStatement {
  const names = new Set(Array.from(sql.matchAll(/:(\w+)/g), (match) => match[1] ?? ""));
  return {
    sql,
    args: Object.fromEntries(
      Array.from(names, (name) => {
        const value = values[name];
        if (value === undefined) {
          throw new Error(`the statement names :${name} but is given no value for it`);
        }
        return [name, value];
      }),
    ),
  };
}
