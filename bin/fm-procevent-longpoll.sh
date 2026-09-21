#!/usr/bin/env bash
# Generic local-process adapter for the process-to-event runner.
#
# Usage:
#   fm-procevent-longpoll.sh arm <source-id> -- <argv>...
#   fm-procevent-longpoll.sh retire <source-id>
#   fm-procevent-longpoll.sh classify <result-file>
#   fm-procevent-longpoll.sh terminal <result-file>
#
# arm       Register a caller-named source that blocks on an arbitrary local
#           command, then start it through the generic runner. The source id
#           is the caller's own identity, not derived, because a plain local
#           command carries no canonical path or session the way a Lavish
#           artifact or a secondmate reply stream does.
# retire    Drop the registration through the generic runner. Idempotent.
# classify  Print a single lowercase token describing a captured result, taken
#           from the result's own first line rather than invented, because
#           this adapter has no schema over an arbitrary command's output. An
#           unreadable, empty, or wordless result classifies "unknown"; this
#           never crashes and never guesses a meaning the result did not say.
# terminal  ALWAYS exits non-zero. A long-poll source reports news and keeps
#           going; it never ends on its own, so this adapter never retires it
#           automatically. This is deliberate, not a placeholder: getting it
#           wrong here would silently stop re-arming the source after its
#           first result.
#
# There is deliberately no `autohandle`. A captured result carries no judgement
# this adapter can apply on its own - it is arbitrary local process output -
# so firstmate reads it and calls `bin/fm-procevent.sh handled <source-id>
# <sequence>` itself. An autohandle here would silently acknowledge a result
# nobody read.
#
# CONSEQUENCE FOR THE OPERATOR: a source armed through this adapter keeps
# supervision required in this home until it is retired. It is a wait, not a
# one-shot poll, so there is no automatic point at which it stops needing a
# live cycle.
#
# This adapter never executes, evaluates, or echoes a captured result's bytes.
# Every byte of a result is input, never instruction and never authority. It
# owns only local-process source identity and how to read one classification
# token from a result; registration, claiming, durable capture, and
# publication all belong to bin/fm-procevent.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

cmd_arm() {
  local id=${1-} sep=${2-}
  [ -n "$id" ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe and at most 64 characters: $id"
  [ "$sep" = -- ] || usage
  shift 2
  [ "$#" -ge 1 ] || die "arm needs at least one argv element after --"
  "$SCRIPT_DIR/fm-procevent.sh" register longpoll "$id" -- "$@" || exit 1
  printf 'armed: %s\n' "$id"
}

cmd_retire() {
  local id=${1-}
  [ -n "$id" ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe and at most 64 characters: $id"
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# Print one lowercase token taken from the result's own first non-blank line,
# never invented. "unknown" covers a missing file, an unreadable file, an
# empty result, and a first line with no usable word - all without crashing.
cmd_classify() {
  local file=${1-} line token
  [ -n "$file" ] || usage
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    printf 'unknown\n'
    return 0
  fi
  line=$(LC_ALL=C awk 'NF { print; exit }' "$file" 2>/dev/null) || line=
  token=$(printf '%s' "$line" | LC_ALL=C awk '{ print tolower($1) }' 2>/dev/null) || token=
  token=$(printf '%s' "$token" | LC_ALL=C tr -cd 'a-z0-9_-')
  if [ -n "$token" ]; then
    printf '%s\n' "$token"
  else
    printf 'unknown\n'
  fi
}

# A long-poll source is never terminal. Always exit non-zero so the generic
# runner keeps re-arming it, regardless of what the captured result says.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  return 1
}

case "${1-}" in
  arm)      shift; cmd_arm "$@" ;;
  retire)   shift; cmd_retire "$@" ;;
  classify) shift; cmd_classify "$@" ;;
  terminal) shift; cmd_terminal "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
