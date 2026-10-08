#!/usr/bin/env bash
# Fake MCP stdio backend for tests: speaks line-delimited JSON-RPC with
# synthetic data. The first argument selects a start-up mode; the "method" of
# each request selects its behaviour.
#
#   never_start    never answers `initialize`
#   exit_on_start  exits immediately with status 3
#   exit_unless_file <path>  exits with status 3 unless <path> exists
#   (default)      behaves like a healthy backend
#
#   crash          exits with status 1 without answering
#   hang           never answers
#   slow           answers after 0.4 s (concurrently with other requests)
#   noisy          prints a non-JSON line, then answers
#   big            answers with a ~200 KB payload
#   anything else  answers {"pid": <os pid>, "method": <method>}

case "${1:-normal}" in
  never_start) exec sleep 3600 ;;
  exit_on_start) exit 3 ;;
  exit_unless_file) [ -e "$2" ] || exit 3 ;;
esac

reply() { printf '%s\n' "$1"; }

while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p' 2>/dev/null)
  method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p' 2>/dev/null)
  case "$method" in
    initialize)
      reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"fake-mcp\",\"version\":\"0\"}}}"
      ;;
    notifications/*) ;;
    crash) exit 1 ;;
    hang) ;;
    slow)
      ( sleep 0.4; reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"method\":\"slow\"}}" ) &
      ;;
    noisy)
      echo "INFO this is not JSON"
      reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"method\":\"noisy\"}}"
      ;;
    big)
      payload=$(head -c 200000 /dev/zero | tr '\0' 'a')
      reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"data\":\"$payload\"}}"
      ;;
    *)
      reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"pid\":$$,\"method\":\"$method\"}}"
      ;;
  esac
done
