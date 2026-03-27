#!/bin/sh
set -eu

usage() {
  echo "Usage: $0 --url URL --token TOKEN <payload lines>" >&2
  echo "       or: echo '<payload>' | $0 --url URL --token TOKEN" >&2
  exit 3
}

URL=""
TOKEN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --url)
      URL="$2"; shift 2;;
    --token)
      TOKEN="$2"; shift 2;;
    *)
      break;;
  esac
done

if [ -z "$URL" ] || [ -z "$TOKEN" ]; then
  usage
fi

if [ "$#" -gt 0 ]; then
  body=$(printf "%s\n" "$@")
else
  body=$(cat)
fi

if [ -z "$body" ]; then
  usage
fi

resp=$(curl -sS -w "\n%{http_code}" \
  -H "Accept: application/icinga" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: text/plain" \
  --data-binary "$body" \
  "$URL") || {
  echo "UNKNOWN: DirX API call failed"; exit 3; }

http_code=$(printf "%s" "$resp" | tail -n 1 | tr -d '\r')
if [ "$http_code" != "200" ]; then
  echo "UNKNOWN: DirX API HTTP $http_code"
  exit 3
fi

std=$(printf "%s" "$resp" | sed -n '1p')
if [ -z "$std" ]; then
  echo "UNKNOWN: Empty response"
  exit 3
fi

code=$(printf "%s" "$resp" | sed -n '2p' | tr -d '\r' | tr -d '[:space:]')

echo "$std"

case "$code" in
  0|1|2|3) exit "$code";;
  *) exit 3;;
esac
