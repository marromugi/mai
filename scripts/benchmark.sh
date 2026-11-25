#!/bin/sh
# Times the app's own work on a heavy library (FeaturesTests' LibraryBenchmark) on the simulator
# the snapshot tests use, built -O as the Beta build is, and prints one line per case.
# Boot that simulator first: `swift scripts/snapshot-test.swift` creates and boots it.
set -eu
cd "$(dirname "$0")/../Packages/Modules"
mkdir -p .build
TEST_RUNNER_BENCHMARK=1 xcodebuild test \
  -scheme Modules \
  -destination 'platform=iOS Simulator,name=mai-snapshots' \
  -derivedDataPath .build/benchmark \
  -only-testing:FeaturesTests/LibraryBenchmark \
  -collect-test-diagnostics never \
  SWIFT_OPTIMIZATION_LEVEL=-O 2>&1 | tee .build/benchmark.log | grep -E '^benchmark |error:|failed' || true
