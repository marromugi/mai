#!/bin/bash
# Runs TLC on Specs/ReadMode: the model must pass, and each broken variant
# must fail on the invariant named below.
#
#   scripts/model-check.sh            check everything
#   scripts/model-check.sh <variant>  print TLC's full output (the trace) for one variant
#
# Needs Java 11 or later: $JAVA_HOME, Homebrew's openjdk, or java on PATH.
set -euo pipefail

TLC_VERSION=1.7.4
TLC_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88

# variant -> the invariant it must break
VARIANTS="
AcceptExcluded NoCopyOfExcluded
KeepCopyOnExclude NoCopyOfExcluded
AcceptExpired NoCopyPastExpiry
KeepExpiredCopy NoCopyPastExpiry
SkipSignatureCheck NeverWrapForUnsignedKey
"

root="$(cd "$(dirname "$0")/.." && pwd)"
spec_dir="$root/Specs/ReadMode"

if [[ -n "${JAVA_HOME:-}" ]]; then
  java="$JAVA_HOME/bin/java"
elif [[ -x /opt/homebrew/opt/openjdk/bin/java ]]; then
  java=/opt/homebrew/opt/openjdk/bin/java
else
  java=java
fi

cache="${XDG_CACHE_HOME:-$HOME/.cache}/mai"
jar="$cache/tla2tools-$TLC_VERSION.jar"
if [[ ! -f "$jar" ]]; then
  mkdir -p "$cache"
  curl -fsSL -o "$jar.part" \
    "https://github.com/tlaplus/tlaplus/releases/download/v$TLC_VERSION/tla2tools.jar"
  mv "$jar.part" "$jar"
fi
if ! echo "$TLC_SHA256  $jar" | shasum -a 256 -c - >/dev/null; then
  echo "error: $jar does not match the pinned SHA-256; delete it and run again" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# tlc <config> <output file>; returns TLC's exit status
tlc() {
  (cd "$spec_dir" && "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC \
    -workers auto -metadir "$work/states" -config "$1" ReadMode.tla) >"$2" 2>&1
}

if [[ $# -eq 1 ]]; then
  tlc "Broken/$1.cfg" "$work/out" || true
  cat "$work/out"
  exit 0
fi

failed=0

if tlc ReadMode.cfg "$work/ReadMode.out" && grep -q "No error has been found" "$work/ReadMode.out"; then
  echo "pass  ReadMode: $(grep "states left on queue" "$work/ReadMode.out" | tail -1)"
else
  echo "FAIL  ReadMode: TLC found an error" >&2
  cat "$work/ReadMode.out" >&2
  failed=1
fi

while read -r variant invariant; do
  [[ -z "$variant" ]] && continue
  out="$work/$variant.out"
  tlc "Broken/$variant.cfg" "$out" || true
  if grep -q "Invariant $invariant is violated" "$out"; then
    echo "pass  $variant breaks $invariant"
  else
    echo "FAIL  $variant was expected to break $invariant" >&2
    cat "$out" >&2
    failed=1
  fi
done <<<"$VARIANTS"

exit $failed
