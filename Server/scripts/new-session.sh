#!/bin/bash
# Makes an account with one session in a local database file, before `turso dev --db-file` serves
# it, and prints the session's token. Writes an account, its subscription and a session as
# Store.makeAccount does, with no Apple user or refresh token behind them and the subscription paid
# for 30 days; for local runs, which don't reach Apple.
# Usage: new-session.sh <database file> [plan]
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: new-session.sh <database file> [plan]" >&2
  exit 1
fi
database="$1"
[[ -f "$database" ]] || { echo "$database is not a file; make it with schema.sql first" >&2; exit 1; }
tier="${2:-basic}"
[[ "$tier" =~ ^[a-z-]+$ ]] || { echo "a plan's name is lowercase letters and hyphens" >&2; exit 1; }
account="$(uuidgen | tr '[:upper:]' '[:lower:]')"
session="$(uuidgen | tr '[:upper:]' '[:lower:]')"
secret="$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=')"
digest="$(printf '%s' "$secret" | shasum -a 256 | cut -d ' ' -f 1)"
now="$(($(date +%s) * 1000))"
paid_until="$((now + 30 * 24 * 60 * 60 * 1000))"

sqlite3 "$database" \
  "INSERT INTO accounts (id, apple_sub, apple_refresh_token, tier, paid_until, created)
   SELECT '$account', 'local.$account', X'', tier, $paid_until, $now FROM plans WHERE tier = '$tier';
   INSERT INTO subscriptions (original_transaction_id, account_id, product_id, period_ends,
     paid_until, environment, signed_date)
   SELECT 'local.$account', '$account', product_id, $paid_until, $paid_until,
     'Production', $now FROM plans WHERE tier = '$tier';
   INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
   SELECT '$session', '$account', X'$digest', $now, $now FROM accounts WHERE id = '$account';
   SELECT changes();" | grep -qx 1 || { echo "there is no plan named $tier" >&2; exit 1; }
printf 's1.%s.%s\n' "$session" "$secret"
