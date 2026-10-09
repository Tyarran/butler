#!/usr/bin/env bash
# Regenerates docs/screenshots/*-{light,dark}.png from `mix butler.demo`
# (synthetic data only). Needs node and a Chromium (CHROMIUM_PATH, default
# /usr/bin/chromium). playwright-core is installed under tmp/screenshots.
set -euo pipefail
cd "$(dirname "$0")/.."

port="${PORT:-4010}"
work=tmp/screenshots
log="$work/demo.log"
mkdir -p "$work"

if [ ! -d "$work/node_modules/playwright-core" ]; then
  (cd "$work" && npm init -y >/dev/null && npm install --silent playwright-core)
fi

mix butler.demo --port "$port" >"$log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -fs -o /dev/null "http://localhost:$port/jobs" && break
  kill -0 "$server" 2>/dev/null || { cat "$log"; exit 1; }
  sleep 1
done

PLAYWRIGHT_DIR="$PWD/$work" BASE_URL="http://localhost:$port" node scripts/screenshots.mjs "$@"
