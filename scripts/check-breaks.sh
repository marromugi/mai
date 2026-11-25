#!/bin/bash
# Checks that ast-grep loads every rule in references/breaks, so break-it can
# apply each one.
#
#   scripts/check-breaks.sh           check every rule there
#   scripts/check-breaks.sh FILE...   check these rules

set -u
cd "$(dirname "$0")/.."

if [ $# -eq 0 ]; then
  set -- .claude/skills/project-rules/references/breaks/*.yml
fi

failed=0
for rule in "$@"; do
  if ! ast-grep scan --rule "$rule" --stdin </dev/null >/dev/null; then
    echo "ast-grep can't load $rule" >&2
    failed=1
  fi
done
exit $failed
