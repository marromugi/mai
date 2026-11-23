#!/bin/bash
# Runs the server contract (Packages/Sync, ServerContract) and two devices syncing on the Worker in
# Server/ under wrangler dev, against a local libSQL server (turso dev) on a new database. Each runs
# as an account of its own, since syncing takes in every writing of the account; the servers are
# stopped and the database removed afterwards.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
port="${MAI_CONTRACT_PORT:-8790}"
database_port="${MAI_CONTRACT_DATABASE_PORT:-8791}"
directory="$(mktemp -d /private/tmp/mai-contract.XXXXXX)"
servers=()

stop() {
  for server in "${servers[@]}"; do
    kill "$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true
  done
  rm -rf "$directory"
}
trap stop EXIT

# Makes an account on the basic plan with one session, as Store.makeAccount and startSession do,
# and prints the session's token.
session_of_a_new_account() {
  local account session secret now
  account="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  session="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  secret="$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=')"
  now="$(($(date +%s) * 1000))"
  sqlite3 "$directory/mai.db" \
    "INSERT INTO accounts (id, tier, created) VALUES ('$account', 'basic', $now);
     INSERT INTO sessions (id, account_id, token_sha256, created, last_used)
     VALUES ('$session', '$account', X'$(printf '%s' "$secret" | shasum -a 256 | cut -d ' ' -f 1)', $now, $now);"
  printf 's1.%s.%s' "$session" "$secret"
}

wait_for() {
  local url="$1" server="$2" log="$3"
  for _ in $(seq 60); do
    if curl -s -o /dev/null "$url"; then return 0; fi
    if ! kill -0 "$server" 2>/dev/null; then cat "$log"; return 1; fi
    sleep 0.5
  done
  cat "$log"
  return 1
}

sqlite3 "$directory/mai.db" <"$root/Server/schema.sql"
contract_token="$(session_of_a_new_account)"
two_devices_token="$(session_of_a_new_account)"

turso dev --db-file "$directory/mai.db" --port "$database_port" >"$directory/turso.log" 2>&1 &
servers+=($!)
wait_for "http://127.0.0.1:$database_port/health" "${servers[0]}" "$directory/turso.log"

pnpm --dir "$root/Server" exec wrangler dev --port "$port" --persist-to "$directory/wrangler" \
  --var "TURSO_URL:http://127.0.0.1:$database_port" --var "TURSO_TOKEN:" \
  >"$directory/wrangler.log" 2>&1 &
servers+=($!)
wait_for "http://127.0.0.1:$port/writings" "${servers[1]}" "$directory/wrangler.log"

run_as() {
  MAI_SERVER_URL="http://127.0.0.1:$port" MAI_SERVER_TOKEN="$1" \
    swift test --package-path "$root/Packages/Sync" --filter "$2"
}

run_as "$contract_token" "ContractTests/workerKeepsTheContract"
run_as "$two_devices_token" "ContractTests/twoDevicesSyncThroughTheWorker"
