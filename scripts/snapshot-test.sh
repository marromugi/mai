#!/bin/sh
# Runs the snapshot tests on the one simulator the snapshots were recorded on.
# Another device or iOS version renders text differently, so every snapshot would differ.
# Set SNAPSHOT_TESTING_RECORD=all to record them again.
set -eu

DEVICE_NAME="mai-snapshots"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-27-2"

udid=$(xcrun simctl list devices -j | jq -r --arg runtime "$RUNTIME" --arg name "$DEVICE_NAME" \
  '.devices[$runtime] // [] | map(select(.name == $name)) | first | .udid // empty')
if [ -z "$udid" ]; then
  udid=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")
fi

cd "$(dirname "$0")/../Packages/Modules"
TEST_RUNNER_SNAPSHOT_TESTING_RECORD="${SNAPSHOT_TESTING_RECORD:-missing}" \
  xcodebuild test -scheme Modules -destination "id=$udid" -quiet
