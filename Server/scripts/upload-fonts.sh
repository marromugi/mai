#!/bin/bash
# Puts the font files fonts.json lists into the FONTS bucket (wrangler.jsonc), under fonts/<name>,
# leaving each one the bucket already holds with the SHA-256 fonts.json names. A file to put is
# fetched from google/fonts at the commit fonts.json names and checked against its SHA-256 first.
# --local writes the bucket wrangler dev serves from (with --persist-to <directory> when wrangler
# dev is given one); --remote writes the bucket of the deployed environment named, staging or prod.
# Usage: upload-fonts.sh --local [--persist-to <directory>] | --remote staging|prod
set -euo pipefail

server="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  --local)
    target=("$@")
    environment=prod
    ;;
  --remote)
    [[ $# -eq 2 ]] || { echo "usage: upload-fonts.sh --remote staging|prod" >&2; exit 1; }
    target=(--remote)
    environment="$2"
    ;;
  *)
    echo "usage: upload-fonts.sh --local [--persist-to <directory>] | --remote staging|prod" >&2
    exit 1
    ;;
esac
bucket="$(node "$server/scripts/environment.mjs" "$environment" | jq -r .fontsBucket)"
source="$(jq -r .source "$server/fonts.json")"
directory="$(mktemp -d "${TMPDIR:-/tmp}/mai-fonts.XXXXXX")"
trap 'rm -rf "$directory"' EXIT

jq -r '.files[] | [.name, .path, .sha256] | @tsv' "$server/fonts.json" |
  while IFS=$'\t' read -r name path sha256; do
    if pnpm --dir "$server" exec wrangler r2 object get "$bucket/fonts/$name" \
      --file "$directory/stored" "${target[@]}" >/dev/null 2>"$directory/errors"; then
      if [[ "$(shasum -a 256 "$directory/stored" | cut -d ' ' -f 1)" == "$sha256" ]]; then
        echo "$bucket/fonts/$name is already the file fonts.json names"
        continue
      fi
    elif ! grep -q "The specified key does not exist" "$directory/errors"; then
      cat "$directory/errors" >&2
      exit 1
    fi
    curl -fsSL -o "$directory/$name" "$source/$(jq -rn --arg p "$path" '$p | @uri | gsub("%2F"; "/")')"
    actual="$(shasum -a 256 "$directory/$name" | cut -d ' ' -f 1)"
    if [[ "$actual" != "$sha256" ]]; then
      echo "$name from $source/$path is not the file fonts.json names (SHA-256 $actual)" >&2
      exit 1
    fi
    pnpm --dir "$server" exec wrangler r2 object put "$bucket/fonts/$name" \
      --file "$directory/$name" --content-type font/ttf "${target[@]}"
  done
