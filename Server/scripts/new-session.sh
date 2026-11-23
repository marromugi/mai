#!/bin/bash
# Makes an account with one session in a local database file, before `turso dev --db-file` serves
# it, and prints the session's token. Writes the rows Store.makeAccount and Store.startSession
# write; for local runs only, until signing in (#22, S3) makes sessions.
# Usage: new-session.sh <database file> [plan]
set -euo pipefail

database="$1"
tier="${2:-basic}"
[[ "$tier" =~ ^[a-z-]+$ ]] || { echo "a plan's name is lowercase letters and hyphens" >&2; exit 1; }
account="$(uuidgen | tr '[:upper:]' '[:lower:]')"
session="$(uuidgen | tr '[:upper:]' '[:lower:]')"
secret="$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=')"
digest="$(printf '%s' "$secret" | shasum -a 256 | cut -d ' ' -f 1)"
now="$(($(date +%s) * 1000))"

sqlite3 "$database" \
  "INSERT INTO accounts (id, tier, created) SELECT '$account', tier, $now FROM plans WHERE tier = '$tier';
   INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
   SELECT '$session', '$account', X'$digest', $now, $now FROM accounts WHERE id = '$account';
   SELECT changes();" | grep -qx 1 || { echo "there is no plan named $tier" >&2; exit 1; }
printf 's1.%s.%s\n' "$session" "$secret"
