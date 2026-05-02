#!/usr/bin/env bash
set -euo pipefail

url="${1:-}"

if [[ -z "$url" ]]; then
  echo "usage: youtube-id <youtube-channel-url-or-handle>" >&2
  exit 2
fi

if [[ "$url" == @* ]]; then
  url="https://www.youtube.com/$url"
fi

id="$(
  curl -fsSL "$url" |
    grep -oE '"(channelId|externalId)":"UC[^"]+' |
    head -1 |
    cut -d'"' -f4
)"

if [[ -z "$id" ]]; then
  echo "No YouTube channel ID found for: $url" >&2
  exit 1
fi

printf '%s\n' "$id"
