#!/usr/bin/env bash
# fm-decide.sh - firstmate's entry point to the public jev-decide skill: ask
# TypeSafe Jev to pick one option for a decision through the home's LiteLLM
# proxy, and report whether the answer is decided or inconclusive.
#
# Usage:
#   fm-decide.sh --question <text> --option <label>=<description> \
#                --option <label>=<description> [...] [--context <text>] [--json]
#   Every argument, the output, the verdict rule, and the exit codes are
#   skills/jev-decide/scripts/jev-decide.sh's; run it with --help. The
#   procedure for when to ask and what a verdict authorizes is
#   skills/jev-decide/SKILL.md.
#
# Configuration: each JEV_DECIDE_* variable the CLI reads (BASE_URL, API_KEY,
#   PATH, MODEL, CONFIDENCE_FLOOR, MARGIN, TIMEOUT) comes from this process
#   environment when non-empty, else from a JEV_DECIDE_*= line in
#   $FM_HOME/.env read with fmx_env_get (bin/fm-env-lib.sh), the same accessor
#   and env-wins rule as TYPESAFE_API_KEY and the Relay token. Absent base URL
#   or key means the CLI reports inconclusive with that reason, exit 0, and no
#   network call. docs/configuration.md "Jev decisions" owns the operator
#   contract.
#
# Key handling: the key reaches the CLI only through its environment, which
#   the CLI unsets before starting any child; it is never on argv or logged.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CLI="$FM_ROOT/skills/jev-decide/scripts/jev-decide.sh"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

[ -x "$CLI" ] || { printf 'fm-decide: error: jev-decide CLI missing or not executable: %s\n' "$CLI" >&2; exit 2; }

for suffix in BASE_URL API_KEY PATH MODEL CONFIDENCE_FLOOR MARGIN TIMEOUT; do
  name=JEV_DECIDE_$suffix
  if [ -z "${!name:-}" ]; then
    value=$(fmx_env_get "$name" "$FM_HOME/.env")
    if [ -n "$value" ]; then
      export "$name=$value"
    else
      unset "$name"
    fi
  fi
done
unset value

exec "$CLI" "$@"
