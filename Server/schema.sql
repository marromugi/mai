-- The one Turso database. Every row of an account's data carries its account_id.
-- Applied once to a new database; see Server/README.md.

-- What each plan may use. The quota triggers and src/store.ts read their limits from here.
CREATE TABLE plans (
  tier TEXT PRIMARY KEY,
  writings_bytes INTEGER NOT NULL,
  writings_count INTEGER NOT NULL,
  requests_per_day INTEGER NOT NULL,
  lists_per_day INTEGER NOT NULL,
  saves_per_day INTEGER NOT NULL
) STRICT;

INSERT INTO plans VALUES
  ('basic', 100000000, 10000, 3000, 200, 500),
  ('plus', 500000000, 50000, 10000, 300, 2000),
  ('pro', 1000000000, 100000, 10000, 300, 2000);

CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  tier TEXT NOT NULL,
  writings_bytes INTEGER NOT NULL DEFAULT 0,
  writings_count INTEGER NOT NULL DEFAULT 0,
  created INTEGER NOT NULL
) STRICT;

-- token_sha256 is the SHA-256 of the session token's secret; the secret itself is never kept.
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  token_sha256 BLOB NOT NULL,
  created INTEGER NOT NULL,
  last_used INTEGER NOT NULL
) STRICT;
CREATE INDEX sessions_account ON sessions (account_id);
CREATE INDEX sessions_last_used ON sessions (last_used);

-- day is whole UTC days since 1970.
CREATE TABLE usage (
  account_id TEXT NOT NULL,
  day INTEGER NOT NULL,
  requests INTEGER NOT NULL DEFAULT 0,
  lists INTEGER NOT NULL DEFAULT 0,
  saves INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id, day)
) STRICT, WITHOUT ROWID;
CREATE INDEX usage_day ON usage (day);

CREATE TABLE writings (
  account_id TEXT NOT NULL,
  id TEXT NOT NULL,
  revision TEXT NOT NULL,
  updated INTEGER NOT NULL,
  size INTEGER NOT NULL,
  envelope BLOB NOT NULL,
  PRIMARY KEY (account_id, id)
) STRICT;

-- accounts.writings_bytes and writings_count follow every write to writings. A change that
-- grows an account past its plan aborts the whole batch with this message, which src/store.ts
-- answers as 429. A change that shrinks a writing is never refused.
CREATE TRIGGER writings_added AFTER INSERT ON writings BEGIN
  UPDATE accounts SET writings_bytes = writings_bytes + NEW.size,
    writings_count = writings_count + 1
  WHERE id = NEW.account_id;
  SELECT RAISE(ABORT, 'mai: over the plan''s storage')
  FROM accounts a JOIN plans p ON p.tier = a.tier
  WHERE a.id = NEW.account_id
    AND (a.writings_bytes > p.writings_bytes OR a.writings_count > p.writings_count);
END;

CREATE TRIGGER writings_resized AFTER UPDATE OF size ON writings BEGIN
  UPDATE accounts SET writings_bytes = writings_bytes + NEW.size - OLD.size
  WHERE id = NEW.account_id;
  SELECT RAISE(ABORT, 'mai: over the plan''s storage')
  FROM accounts a JOIN plans p ON p.tier = a.tier
  WHERE a.id = NEW.account_id AND NEW.size > OLD.size AND a.writings_bytes > p.writings_bytes;
END;
