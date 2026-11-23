#!/bin/bash
# Two installs of the app syncing through the Worker in Server/ under wrangler dev
# (AppUITests/SyncAppTests). The first install makes the own key and sends a writing saved in its
# store; the app is then removed and the simulator's keychain emptied, and the second install
# takes the recovery key typed back and receives the writing.
#
# Runs on the simulator mai-sync-check (made when missing, shut down afterwards; remove it with
# `xcrun simctl delete mai-sync-check`). The Worker, its storage and the build are removed
# afterwards.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
port="${MAI_SYNC_APP_PORT:-8791}"
device_name="mai-sync-check"
device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-27-2"
app="com.marromugi.mai"
work="$(mktemp -d /private/tmp/mai-sync-app.XXXXXX)"
worker=""

udid="$(xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["name"] == name:
            print(device["udid"])
            sys.exit()
' "$device_name")"
if [ -z "$udid" ]; then
  udid="$(xcrun simctl create "$device_name" "$device_type" "$runtime")"
fi

finish() {
  if [ -n "$worker" ]; then
    kill "$worker" 2>/dev/null || true
    wait "$worker" 2>/dev/null || true
  fi
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  rm -rf "$work"
}
trap finish EXIT

# A fresh install with an empty keychain, as on a device that never held the own key.
fresh_install() {
  xcrun simctl uninstall "$udid" "$app" 2>/dev/null || true
  xcrun simctl keychain "$udid" reset
}

run_step() {
  TEST_RUNNER_MAI_SYNC_CHECK_DIR="$work" TEST_RUNNER_MAI_SERVER_URL="http://127.0.0.1:$port" \
    xcodebuild test-without-building -project "$root/Mai.xcodeproj" -scheme Mai \
    -destination "id=$udid" -derivedDataPath "$work/build" -collect-test-diagnostics never \
    -only-testing:"MaiUITests/SyncAppTests/$1" | grep -E "error:|passed|failed|skipped"
}

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
fresh_install

(cd "$root" && xcodegen generate --quiet)
xcodebuild build-for-testing -project "$root/Mai.xcodeproj" -scheme Mai -destination "id=$udid" \
  -derivedDataPath "$work/build" -quiet

run_step testMakesTheOwnKeyAndShowsItsRecoveryKey

# The Worker takes the value the first install showed, as the deployed one would.
pnpm --dir "$root/Server" exec wrangler dev --port "$port" --persist-to "$work/storage" \
  --var "ACCESS_TOKEN_SHA256:$(cat "$work/access-token-sha256.txt")" >"$work/wrangler.log" 2>&1 &
worker=$!
for _ in $(seq 60); do
  if curl -s -o /dev/null "http://127.0.0.1:$port/writings"; then break; fi
  if ! kill -0 "$worker" 2>/dev/null; then cat "$work/wrangler.log"; exit 1; fi
  sleep 0.5
done

# A writing saved in the first install's store, as the app saves one.
container="$(xcrun simctl get_app_container "$udid" "$app" data)"
writings="$container/Library/Application Support/Writings"
id="$(uuidgen)"
updated="$(python3 -c 'import time; print(time.time() - 978307200)')"
mkdir -p "$writings"
cat >"$writings/$id.json" <<END_OF_WRITING
{"id":"$id","title":"同期で届く文書","body":"一台目で書いた。","updated":$updated}
END_OF_WRITING

run_step testSendsTheWritingSavedOnThisInstall

fresh_install
run_step testRestoresTheOwnKeyAndReceivesTheWriting

echo "Requests the Worker answered:"
grep -E '(GET|PUT) /writings' "$work/wrangler.log" || true

# The one writing saved, and none of the samples, was sent, and sent once.
lowercase_id="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
puts="$(grep -E 'PUT /writings/' "$work/wrangler.log" || true)"
if [ "$(printf '%s\n' "$puts" | grep -c .)" -ne 1 ] || ! printf '%s' "$puts" | grep -q "PUT /writings/$lowercase_id 200"; then
  echo "Expected one PUT of $lowercase_id answered 200, and no other." >&2
  exit 1
fi
