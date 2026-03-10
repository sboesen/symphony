#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ $# -eq 0 ]]; then
  set -- "./WORKFLOW.md"
fi

if [[ -n "${ELIXIR_ERL_OPTIONS:-}" ]]; then
  export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS} +Bd"
else
  export ELIXIR_ERL_OPTIONS="+Bd"
fi

child_pid=""
runtime_file="$(mktemp "${TMPDIR:-/tmp}/symphony-runtime.XXXXXX")"
export SYMPHONY_RUNTIME_FILE="$runtime_file"
interrupted=0

forward_shutdown() {
  interrupted=1
  if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
}

trap forward_shutdown INT TERM

mix run --no-start -e 'Symphony.CLI.main(System.argv())' -- "$@" </dev/tty &
child_pid=$!
set +e
wait "$child_pid" 2>/dev/null
exit_code=$?
set -e

mix run --no-start -e 'Symphony.CLI.cleanup_runtime_file(List.first(System.argv()) || "", "./WORKFLOW.md")' -- "$runtime_file" >/dev/null 2>&1 || true

if [[ "$interrupted" -eq 1 ]]; then
  exit 130
fi

exit "$exit_code"
