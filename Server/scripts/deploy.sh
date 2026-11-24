#!/bin/bash
# Deploys the Worker of one environment of wrangler.jsonc, dev or prod, setting with it only the
# required secrets the Worker doesn't have yet (all of them on its first deploy) and never changing
# one it has. A missing secret is made as follows: TURSO_URL and TURSO_TOKEN from the environment's
# Turso database (logged in with turso), CHALLENGE_KEY and REFRESH_TOKEN_KEY as new random keys,
# APPLE_CLIENT_ID as the app's bundle ID, and APPLE_TEAM_ID, APPLE_SIGN_IN_KEY_ID and
# APPLE_SIGN_IN_KEY from the shell variables APPLE_TEAM_ID, APPLE_SIGN_IN_KEY_ID and
# APPLE_SIGN_IN_KEY_FILE (the .p8's path).
# Usage: deploy.sh dev | prod
set -euo pipefail

server="$(cd "$(dirname "$0")/.." && pwd)"
environment="$(node "$server/scripts/environment.mjs" "${1:-}")"
wrangler_env="$(jq -r .wranglerEnv <<<"$environment")"
worker="$(jq -r .worker <<<"$environment")"
database="$(jq -r .database <<<"$environment")"
directory="$(mktemp -d "${TMPDIR:-/tmp}/mai-deploy.XXXXXX")"
trap 'rm -rf "$directory"' EXIT
cd "$server"

if pnpm exec wrangler secret list --env "$wrangler_env" >"$directory/listed" 2>"$directory/errors"; then
  jq -r '.[].name' "$directory/listed" >"$directory/set"
elif grep -q "Worker \"$worker\".* not found" "$directory/errors"; then
  : >"$directory/set"
else
  cat "$directory/errors" >&2
  exit 1
fi
missing=()
while read -r name; do
  grep -qx "$name" "$directory/set" || missing+=("$name")
done < <(jq -r '.secrets[]' <<<"$environment")
if [[ ${#missing[@]} -eq 0 ]]; then
  pnpm exec wrangler deploy --env "$wrangler_env"
  exit 0
fi

unset_variables=()
for name in "${missing[@]}"; do
  case "$name" in
    APPLE_TEAM_ID | APPLE_SIGN_IN_KEY_ID)
      [[ -n "${!name:-}" ]] || unset_variables+=("$name")
      ;;
    APPLE_SIGN_IN_KEY)
      [[ -f "${APPLE_SIGN_IN_KEY_FILE:-}" ]] || unset_variables+=("APPLE_SIGN_IN_KEY_FILE")
      ;;
    TURSO_URL | TURSO_TOKEN | CHALLENGE_KEY | REFRESH_TOKEN_KEY | APPLE_CLIENT_ID) ;;
    *)
      echo "$worker lacks the secret $name, which deploy.sh can't make; set it first with" >&2
      echo "  pnpm exec wrangler secret put $name --env '$wrangler_env'" >&2
      exit 1
      ;;
  esac
done
if [[ ${#unset_variables[@]} -gt 0 ]]; then
  echo "$worker lacks secrets made from ${unset_variables[*]}; set them in the shell and run again" >&2
  exit 1
fi

echo '{}' >"$directory/secrets.json"
for name in "${missing[@]}"; do
  case "$name" in
    TURSO_URL) value="$(turso db show "$database" --url)" ;;
    TURSO_TOKEN) value="$(turso db tokens create "$database")" ;;
    CHALLENGE_KEY | REFRESH_TOKEN_KEY) value="$(openssl rand -base64 32)" ;;
    APPLE_CLIENT_ID) value="com.marromugi.mai" ;;
    APPLE_TEAM_ID | APPLE_SIGN_IN_KEY_ID) value="${!name}" ;;
    APPLE_SIGN_IN_KEY) value="$(grep -v -- ----- "$APPLE_SIGN_IN_KEY_FILE" | tr -d '\n')" ;;
  esac
  jq --arg name "$name" --arg value "$value" '.[$name] = $value' "$directory/secrets.json" \
    >"$directory/next.json"
  mv "$directory/next.json" "$directory/secrets.json"
done
echo "Setting the secrets $worker lacks: ${missing[*]}"
pnpm exec wrangler deploy --env "$wrangler_env" --secrets-file "$directory/secrets.json"
