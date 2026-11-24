#!/bin/bash
# Sets up one environment of wrangler.jsonc, staging or prod, making only what it lacks and changing
# nothing it has. It deploys no code; pnpm deploy:<environment> does.
# - Its Turso database, made when missing, with schema.sql loaded only into one holding nothing.
# - Its R2 buckets, made when missing.
# - The font files fonts.json lists, put where missing or different (upload-fonts.sh).
# - The required secrets its Worker lacks, set with wrangler secret bulk, which makes the Worker
#   when there is none yet. TURSO_URL and TURSO_TOKEN come from its database, CHALLENGE_KEY and
#   REFRESH_TOKEN_KEY are new random keys, APPLE_CLIENT_ID is the app's bundle ID, and
#   APPLE_TEAM_ID, APPLE_SIGN_IN_KEY_ID and APPLE_SIGN_IN_KEY come from the shell variables
#   APPLE_TEAM_ID, APPLE_SIGN_IN_KEY_ID and APPLE_SIGN_IN_KEY_FILE (the .p8's path).
# Needs wrangler and turso logged in.
# Usage: setup.sh staging | prod
set -euo pipefail

server="$(cd "$(dirname "$0")/.." && pwd)"
environment="$(node "$server/scripts/environment.mjs" "${1:-}")"
name="$1"
wrangler_env="$(jq -r .wranglerEnv <<<"$environment")"
worker="$(jq -r .worker <<<"$environment")"
database="$(jq -r .database <<<"$environment")"
directory="$(mktemp -d "${TMPDIR:-/tmp}/mai-setup.XXXXXX")"
trap 'rm -rf "$directory"' EXIT
cd "$server"

# What the Worker lacks, and whether the shell gives what making it needs, before anything is made.
if pnpm exec wrangler secret list --env "$wrangler_env" >"$directory/listed" 2>"$directory/errors"; then
  jq -r '.[].name' "$directory/listed" >"$directory/set"
elif grep -q "Worker \"$worker\".* not found" "$directory/errors"; then
  : >"$directory/set"
else
  cat "$directory/errors" >&2
  exit 1
fi
missing=()
while read -r secret; do
  grep -qx "$secret" "$directory/set" || missing+=("$secret")
done < <(jq -r '.secrets[]' <<<"$environment")
unset_variables=()
for secret in ${missing[@]+"${missing[@]}"}; do
  case "$secret" in
    APPLE_TEAM_ID | APPLE_SIGN_IN_KEY_ID)
      [[ -n "${!secret:-}" ]] || unset_variables+=("$secret")
      ;;
    APPLE_SIGN_IN_KEY)
      key="$(grep -v -- ----- "${APPLE_SIGN_IN_KEY_FILE:-}" 2>/dev/null | tr -d '\r\n')" || true
      [[ -n "$key" ]] || unset_variables+=("APPLE_SIGN_IN_KEY_FILE")
      ;;
    TURSO_URL | TURSO_TOKEN | CHALLENGE_KEY | REFRESH_TOKEN_KEY | APPLE_CLIENT_ID) ;;
    *)
      echo "$worker lacks the secret $secret, which setup.sh can't make; set it first with" >&2
      echo "  pnpm exec wrangler secret put $secret --env '$wrangler_env'" >&2
      exit 1
      ;;
  esac
done
if [[ ${#unset_variables[@]} -gt 0 ]]; then
  echo "$worker lacks secrets made from ${unset_variables[*]}; set them in the shell and run again" >&2
  echo "(APPLE_SIGN_IN_KEY_FILE is the path of a .p8 file holding the key)" >&2
  exit 1
fi

turso db list >"$directory/databases"
if ! awk 'NR > 1 { print $1 }' "$directory/databases" | grep -qx "$database"; then
  turso db create "$database"
fi
objects="$(turso db shell "$database" \
  "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'" | tail -n 1 | tr -d '[:space:]')"
if [[ "$objects" == 0 ]]; then
  echo "Loading schema.sql into $database, which holds nothing yet"
  turso db shell "$database" <schema.sql
elif ! [[ "$objects" =~ ^[0-9]+$ ]]; then
  echo "Counting what $database holds answered \"$objects\", not a number" >&2
  exit 1
fi

pnpm exec wrangler r2 bucket list >"$directory/buckets"
while read -r bucket; do
  if ! sed -n 's/^name: *//p' "$directory/buckets" | grep -qx "$bucket"; then
    pnpm exec wrangler r2 bucket create "$bucket" --update-config=false
  fi
done < <(jq -r '.buckets[]' <<<"$environment")

scripts/upload-fonts.sh --remote "$name"

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "$worker has every secret it requires"
  exit 0
fi
echo '{}' >"$directory/secrets.json"
for secret in "${missing[@]}"; do
  case "$secret" in
    TURSO_URL) value="$(turso db show "$database" --url)" ;;
    TURSO_TOKEN) value="$(turso db tokens create "$database")" ;;
    CHALLENGE_KEY | REFRESH_TOKEN_KEY) value="$(openssl rand -base64 32)" ;;
    APPLE_CLIENT_ID) value="com.marromugi.mai" ;;
    APPLE_TEAM_ID | APPLE_SIGN_IN_KEY_ID) value="${!secret}" ;;
    APPLE_SIGN_IN_KEY) value="$key" ;;
  esac
  jq --arg name "$secret" --arg value "$value" '.[$name] = $value' "$directory/secrets.json" \
    >"$directory/next.json"
  mv "$directory/next.json" "$directory/secrets.json"
done
echo "Setting the secrets $worker lacks: ${missing[*]}"
pnpm exec wrangler secret bulk "$directory/secrets.json" --env "$wrangler_env"
