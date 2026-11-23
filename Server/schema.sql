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

-- id is the UUID the app made, which is also its purchases' appAccountToken. apple_sub is the
-- Sign in with Apple user. apple_refresh_token is Apple's refresh token sealed by
-- src/refresh-tokens.ts; it is never kept unsealed. own_key_check is set once, by the first device
-- to make the own key.
CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  apple_sub TEXT NOT NULL UNIQUE,
  apple_refresh_token BLOB NOT NULL,
  own_key_check BLOB,
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

-- A Sign in with Apple challenge (src/challenges.ts) once used, kept until it expires. claim tells
-- the request that used it from one that came after.
CREATE TABLE used_challenges (
  value TEXT PRIMARY KEY,
  expires INTEGER NOT NULL,
  claim TEXT NOT NULL
) STRICT;
CREATE INDEX used_challenges_expires ON used_challenges (expires);

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
