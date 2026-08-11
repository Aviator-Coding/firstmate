#!/usr/bin/env bash
# Real-Herdr guard for bin/fm-herdr-lab.sh session routing.
#
# tests/fm-herdr-lab.test.sh pins the helper against a fake client that models
# Herdr's resolution order. This guard pins that model against the installed
# client, because the verdict - which session a call is answered by - comes
# entirely from the vendor's argument parser and socket resolution, and a
# release can change it without changing anything here.
#
# Nothing is provisioned and no live server is contacted. Every probe names a
# lab session that does not exist and an ambient socket path that does not
# exist, so the socket named in the client's own error is the proof of where
# the call went, and neither outcome can reach a running session.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_VERSION=$(herdr --version 2>/dev/null | head -n 1) || HERDR_VERSION='unknown'

# An ambient identity of the kind Herdr exports into every pane it manages,
# pointing at the session that spawned the caller rather than at the lab. It is
# never created, and it is kept short and out of TMPDIR deliberately: a probe
# that does reach it must fail naming this path, and a macOS TMPDIR path
# overruns sockaddr_un's sun_path capacity, which would mask that outcome.
AMBIENT_SOCKET=/tmp/fm-lab-amb-$$.sock
LAB_SESSION=$("$HERDR_LAB_HELPER" name isolation-e2e)
export HERDR_SOCKET_PATH="$AMBIENT_SOCKET"
export HERDR_SESSION=default

# A pane id that cannot be allocated, so a probe that did reach a live server
# could still only fail at resolution.
IMPOSSIBLE_PANE=wZZ:p999999

assert_reached_the_lab() { # <what> <client output>
  local what=$1 out=$2
  case "$out" in
    *"$LAB_SESSION"*) : ;;
    *) fail "$what was not answered by the lab session on $HERDR_VERSION; client said: $out" ;;
  esac
  case "$out" in
    *"$AMBIENT_SOCKET"*) fail "$what reached the ambient socket on $HERDR_VERSION; client said: $out" ;;
  esac
}

test_passthrough_command_is_answered_by_the_lab() {
  local out
  out=$("$HERDR_LAB_HELPER" run "$LAB_SESSION" agent start probe --kind claude \
    --pane "$IMPOSSIBLE_PANE" -- --model x 2>&1) || true
  assert_reached_the_lab "an agent-argument passthrough command" "$out"
  pass "fm-herdr-lab: real Herdr answers a passthrough command from the lab session"
}

test_plain_command_is_answered_by_the_lab() {
  local out
  out=$("$HERDR_LAB_HELPER" run "$LAB_SESSION" agent start probe --kind claude \
    --pane "$IMPOSSIBLE_PANE" 2>&1) || true
  assert_reached_the_lab "a plain command" "$out"
  pass "fm-herdr-lab: real Herdr answers a plain command from the lab session"
}

test_the_client_really_drops_a_flag_after_the_separator() {
  # Without this, both assertions above would hold on a client that ignored the
  # separator entirely, and the guard would prove nothing. Probed outside the
  # helper because the helper exists precisely to make this shape impossible.
  local out
  out=$(herdr agent start probe --kind claude --pane "$IMPOSSIBLE_PANE" \
    -- --model x --session "$LAB_SESSION" 2>&1) || true
  case "$out" in
    *"$AMBIENT_SOCKET"*) : ;;
    *) fail "cannot confirm $HERDR_VERSION drops a --session after the passthrough separator; client said: $out" ;;
  esac
  pass "fm-herdr-lab: a session flag after the passthrough separator does not route on real Herdr"
}

test_passthrough_command_is_answered_by_the_lab
test_plain_command_is_answered_by_the_lab
test_the_client_really_drops_a_flag_after_the_separator
