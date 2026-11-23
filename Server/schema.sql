-- The one Turso database. Every row of an account's data carries its account_id.
-- Applied once to a new database; see Server/README.md.

-- What each plan may use. The quota triggers and src/store.ts read their limits from here.
-- product_id is the plan's auto-renewable subscription in App Store Connect (Server/README.md).
CREATE TABLE plans (
  tier TEXT PRIMARY KEY,
  product_id TEXT UNIQUE,
  writings_bytes INTEGER NOT NULL,
  writings_count INTEGER NOT NULL,
  requests_per_day INTEGER NOT NULL,
  lists_per_day INTEGER NOT NULL,
  saves_per_day INTEGER NOT NULL,
  photos_bytes INTEGER NOT NULL,
  photos_per_day INTEGER NOT NULL
) STRICT;

INSERT INTO plans VALUES
  ('basic', 'com.marromugi.mai.basic.monthly', 100000000, 10000, 3000, 200, 500, 5000000000, 100),
  ('plus', 'com.marromugi.mai.plus.monthly', 500000000, 50000, 10000, 300, 2000, 50000000000, 300),
  ('pro', 'com.marromugi.mai.pro.monthly', 1000000000, 100000, 10000, 300, 2000, 200000000000, 300);

-- id is the UUID the app made, which is also its purchases' appAccountToken. apple_sub is the
-- Sign in with Apple user. apple_refresh_token is Apple's refresh token sealed by
-- src/refresh-tokens.ts; it is never kept unsealed. own_key_check is set once, by the first device
-- to make the own key. tier and paid_until follow the account's subscriptions: tier is the plan of
-- the one paid for longest, and paid_until the latest time any of them is paid until. Past
-- paid_until the account has lapsed: it is read but not written, and 90 days past it the cron
-- trigger deletes it (lapsedKept in src/store.ts). deleting is 1 from when the cron trigger starts
-- deleting it; from then on its subscriptions no longer change paid_until or tier, so a
-- resubscription comes too late.
CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  apple_sub TEXT NOT NULL UNIQUE,
  apple_refresh_token BLOB NOT NULL,
  own_key_check BLOB,
  tier TEXT NOT NULL,
  paid_until INTEGER NOT NULL,
  writings_bytes INTEGER NOT NULL DEFAULT 0,
  writings_count INTEGER NOT NULL DEFAULT 0,
  photos_bytes INTEGER NOT NULL DEFAULT 0,
  created INTEGER NOT NULL,
  deleting INTEGER NOT NULL DEFAULT 0 CHECK (deleting IN (0, 1))
) STRICT;
CREATE INDEX accounts_paid_until ON accounts (paid_until);

-- An App Store subscription, by the originalTransactionId every renewal of it shares, as the
-- latest data the App Store signed about it reads (signed_date), among data about its latest billing
-- period (period_ends, the transaction's expiresDate). paid_until is when that period ends, the
-- end of its billing grace period if later, or when it was refunded or revoked.
CREATE TABLE subscriptions (
  original_transaction_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  product_id TEXT NOT NULL,
  period_ends INTEGER NOT NULL,
  paid_until INTEGER NOT NULL,
  environment TEXT NOT NULL,
  signed_date INTEGER NOT NULL
) STRICT;
CREATE INDEX subscriptions_account ON subscriptions (account_id);

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

-- A Sign in with Apple challenge (src/challenges.ts) once used, kept an hour past its expiry
-- (usedChallengeMargin in src/store.ts). claim tells
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
  photos INTEGER NOT NULL DEFAULT 0,
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

-- Each part of a photo, sealed on the device, kept in R2 under the key src/photos.ts makes from
-- account_id, id, part and upload. A part is 'reserved' before its bytes go to R2, so its size
-- counts against the plan from then on, and 'stored' once R2 holds them. An upload that failed is
-- 'releasing' until what R2 got of it is deleted; then its row goes. Only a 'reserved' row becomes
-- either of the others. upload names the one request that reserved it; reserved is when.
CREATE TABLE photos (
  account_id TEXT NOT NULL,
  id TEXT NOT NULL,
  part TEXT NOT NULL CHECK (part IN ('photo', 'thumbnail')),
  upload TEXT NOT NULL UNIQUE,
  size INTEGER NOT NULL,
  state TEXT NOT NULL DEFAULT 'reserved' CHECK (state IN ('reserved', 'stored', 'releasing')),
  reserved INTEGER NOT NULL,
  PRIMARY KEY (account_id, id, part)
) STRICT;
CREATE INDEX photos_unstored ON photos (reserved) WHERE state != 'stored';

-- accounts.photos_bytes follows every part, whatever its state, until its row is deleted. A
-- reservation that grows an account past its plan aborts the whole batch with this message, which
-- src/store.ts answers as 429.
CREATE TRIGGER photos_added AFTER INSERT ON photos BEGIN
  UPDATE accounts SET photos_bytes = photos_bytes + NEW.size WHERE id = NEW.account_id;
  SELECT RAISE(ABORT, 'mai: over the plan''s photo storage')
  FROM accounts a JOIN plans p ON p.tier = a.tier
  WHERE a.id = NEW.account_id AND a.photos_bytes > p.photos_bytes;
END;

CREATE TRIGGER photos_removed AFTER DELETE ON photos BEGIN
  UPDATE accounts SET photos_bytes = photos_bytes - OLD.size WHERE id = OLD.account_id;
END;
