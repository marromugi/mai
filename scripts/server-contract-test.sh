#!/bin/bash
# Runs the server contract (Packages/Sync, ServerContract) and two devices syncing on the Worker in
# Server/ under wrangler dev. Each runs on a Worker of its own with empty storage, since syncing
# takes in every writing on the server; each Worker is stopped and its storage removed afterwards.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
port="${MAI_CONTRACT_PORT:-8790}"

run_on_a_fresh_worker() {
  local storage token digest worker status=0
  storage="$(mktemp -d /private/tmp/mai-contract.XXXXXX)"
  token="$(openssl rand -hex 32)"
  digest="$(printf '%s' "$token" | shasum -a 256 | cut -d ' ' -f 1)"

  pnpm --dir "$root/Server" exec wrangler dev --port "$port" --persist-to "$storage" \
    --var "ACCESS_TOKEN_SHA256:$digest" >"$storage/wrangler.log" 2>&1 &
  worker=$!

  for _ in $(seq 60); do
    if curl -s -o /dev/null "http://127.0.0.1:$port/writings"; then break; fi
    if ! kill -0 "$worker" 2>/dev/null; then cat "$storage/wrangler.log"; return 1; fi
    sleep 0.5
  done

  MAI_SERVER_URL="http://127.0.0.1:$port" MAI_SERVER_TOKEN="$token" \
    swift test --package-path "$root/Packages/Sync" --filter "$1" || status=$?

  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  rm -rf "$storage"
  return "$status"
}

run_on_a_fresh_worker "ContractTests/workerKeepsTheContract"
run_on_a_fresh_worker "ContractTests/twoDevicesSyncThroughTheWorker"
