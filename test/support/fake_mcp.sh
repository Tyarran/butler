#!/usr/bin/env bash
# Fake MCP stdio backend for tests: speaks line-delimited JSON-RPC with
# synthetic data. The first argument selects a start-up mode; the "method" of
# each request selects its behaviour.
#
#   never_start    never answers `initialize`
#   exit_on_start  exits immediately with status 3
#   exit_unless_file <path>  exits with status 3 unless <path> exists
#   ignore_term    ignores SIGTERM (only SIGKILL stops it)
#   (default)      behaves like a healthy backend
#
#   crash          exits with status 1 without answering
#   hang           never answers
#   slow           answers after 0.4 s (concurrently with other requests)
#   noisy          prints a non-JSON line, then answers
#   big            answers with a ~200 KB payload
#   tools/call     answers according to the tool "name" (synthetic outcomes):
#                    fake_ok          success JSON text
#                    fake_success_false / fake_error_key   failure JSON texts
#                    fake_is_error    result with isError true
#                    fake_rpc_error   JSON-RPC error (-32603)
#                    fake_lock        JSON-RPC error -32001 peer_contention
#                    fake_lock_text   isError result with the lock refusal
#                    fake_lock_text_ok  SUCCESS text that mentions MineAlreadyRunning
#                    fake_error_null  success JSON text with "error": null
#                    fake_big         success JSON text of ~100 KB
#                    fake_hang        never answers
#                    fake_env         echoes MEMPALACE_MCP_IDLE_HOURS
#                    anything else    {"success":true,"tool":<name>,"pid":<pid>}
#                  every call appends its tool name to $FAKE_MCP_CALL_LOG if set.
#   anything else  answers {"pid": <os pid>, "method": <method>}

case "${1:-normal}" in
  never_start) exec sleep 3600 ;;
  exit_on_start) exit 3 ;;
  exit_unless_file) [ -e "$2" ] || exit 3 ;;
  ignore_term) trap '' TERM ;;
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
    tools/call)
      tool=$(printf '%s' "$line" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' 2>/dev/null)
      [ -n "${FAKE_MCP_CALL_LOG:-}" ] && printf '%s\n' "$tool" >> "$FAKE_MCP_CALL_LOG"
      text() { reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"$1\"}]$2}}"; }
      case "$tool" in
        fake_ok) text '{\"success\":true,\"drawer_id\":\"d1\"}' ;;
        fake_success_false) text '{\"success\":false,\"error\":\"nope\"}' ;;
        fake_error_key) text '{\"error\":\"bad thing\"}' ;;
        fake_is_error) text 'tool exploded' ',"isError":true' ;;
        fake_rpc_error)
          reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32603,\"message\":\"internal\"}}" ;;
        fake_lock)
          reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32001,\"message\":\"Peer MCP writer active\",\"data\":{\"failure_kind\":\"peer_contention\"}}}" ;;
        fake_lock_text)
          text 'palace /tmp/p is held by PID 1 (x); wait for it to finish or stop the holder before retrying' ',"isError":true' ;;
        fake_lock_text_ok)
          text '{\"success\":true,\"note\":\"MineAlreadyRunning is a documented error\"}' ;;
        fake_error_null) text '{\"success\":true,\"error\":null}' ;;
        fake_big)
          big=$(head -c 100000 /dev/zero | tr '\0' 'a')
          text '{\"success\":true,\"blob\":\"'"$big"'\"}' ;;
        fake_hang) ;;
        fake_env) text '{\"success\":true,\"idle_hours\":\"'"${MEMPALACE_MCP_IDLE_HOURS:-unset}"'\"}' ;;
        *) text '{\"success\":true,\"tool\":\"'"$tool"'\",\"pid\":'"$$"'}' ;;
      esac
      ;;
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
