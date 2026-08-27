#!/usr/bin/env bash
#
# Starts the mock delayed-events server, runs the Swift test suite against it with
# MOCK_SERVER=1, and tears the server down again.
#
#   tools/run_contract_tests.sh                     # whole suite, contract tests included
#   tools/run_contract_tests.sh --filter Contract   # extra args go through to `swift test`
#
# macOS / `swift test` only. Under `xcodebuild test` on a simulator the shell environment does
# not reach the test process, so MOCK_SERVER would be unset there and the contract tests would
# skip themselves.
set -euo pipefail

PORT="${MOCK_SERVER_PORT:-8123}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$(mktemp -t mock_delayed_server)"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "${KEEP_LOG:-0}" == "1" ]]; then
    echo "mock server log: $LOG"
  else
    rm -f "$LOG"
  fi
}
trap cleanup EXIT

python3 "$ROOT/tools/mock_delayed_server.py" --port "$PORT" --quiet > "$LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/healthcheck" > /dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "mock server exited before becoming ready:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  sleep 0.1
done

if ! curl -fsS "http://127.0.0.1:$PORT/healthcheck" > /dev/null 2>&1; then
  echo "mock server did not become ready on port $PORT" >&2
  cat "$LOG" >&2
  exit 1
fi

echo "mock server ready on http://127.0.0.1:$PORT (pid $SERVER_PID)"
MOCK_SERVER=1 swift test --package-path "$ROOT" "$@"
