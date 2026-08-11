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
# lab session that does not exist, so a call that routes correctly can only fail
# at resolution.
#
# The evidence is the installed client's own two answers, not any string it
# prints: the same passthrough command is run once unrouted and once with a
# leading --session, and every later probe is compared against those two
# references. Herdr 0.7.4 reports an unreachable socket as a bare OS error while
# 0.8.x names the session it resolved, so comparing whole answers is what keeps
# one guard honest on both.
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
# created as an empty file and nothing ever listens on it: a call that falls
# back to it reaches a path that exists but can never accept a connection, which
# no client reports the way it reports the lab session's simply absent socket,
# and that difference is what makes the two destinations tellable apart on a
# client that never names the socket it tried. The path is kept short and out of
# TMPDIR deliberately: a macOS TMPDIR path overruns sockaddr_un's sun_path
# capacity, and an address the client cannot even form fails before it resolves
# any destination at all.
AMBIENT_SOCKET=/tmp/fm-lab-amb-$$.sock
: > "$AMBIENT_SOCKET" || fail "cannot stage the ambient socket path $AMBIENT_SOCKET"
trap 'rm -f "$AMBIENT_SOCKET"' EXIT
LAB_SESSION=$("$HERDR_LAB_HELPER" name isolation-e2e)
export HERDR_SOCKET_PATH="$AMBIENT_SOCKET"
export HERDR_SESSION=default

# A pane id that cannot be allocated, so a probe that did reach a live server
# could still only fail at resolution.
IMPOSSIBLE_PANE=wZZ:p999999

# Herdr's own agent-argument passthrough, the shape that produced the leak: a
# bare -- ends the client's option parsing, so a --session after it is agent
# argument rather than routing. Its options are release-specific (0.7.4 takes
# --cwd/--workspace, 0.8.x requires --kind/--pane) and an option the installed
# client rejects never reaches resolution at all, so the shape is taken from
# that client's own usage text. The separator, which is what this guards, is the
# constant.
PASSTHROUGH=(agent start fm-lab-isolation-probe)
case "$(herdr agent 2>&1)" in
  *'agent start <name> --kind'*) PASSTHROUGH+=(--kind claude --pane "$IMPOSSIBLE_PANE") ;;
esac
PASSTHROUGH+=(-- --model x)

client_answer() { # <herdr arguments...>
  herdr "$@" 2>&1
}

AMBIENT_ANSWER=$(client_answer "${PASSTHROUGH[@]}")
LAB_ANSWER=$(client_answer --session "$LAB_SESSION" "${PASSTHROUGH[@]}")

assert_reached_the_lab() { # <what> <client output>
  local what=$1 out=$2
  [ "$out" != "$AMBIENT_ANSWER" ] || fail "$what was answered by the ambient session on $HERDR_VERSION; client said: $out"
  [ "$out" = "$LAB_ANSWER" ] || fail "$what was not answered by the lab session on $HERDR_VERSION; client said: $out"
}

test_the_client_tells_the_two_destinations_apart() {
  # Without this every comparison below could hold on two identical answers -
  # which is exactly what a passthrough shape the installed client rejects out
  # of hand would produce - and the guard would prove nothing.
  [ "$AMBIENT_ANSWER" != "$LAB_ANSWER" ] \
    || fail "$HERDR_VERSION answers a routed and an unrouted passthrough command identically, so this guard cannot see where a call went; client said: $LAB_ANSWER"
  pass "fm-herdr-lab: real Herdr answers a routed and an unrouted passthrough command differently"
}

test_passthrough_command_is_answered_by_the_lab() {
  local out
  out=$("$HERDR_LAB_HELPER" run "$LAB_SESSION" "${PASSTHROUGH[@]}" 2>&1) || true
  assert_reached_the_lab "an agent-argument passthrough command" "$out"
  pass "fm-herdr-lab: real Herdr answers a passthrough command from the lab session"
}

test_plain_command_is_answered_by_the_lab() {
  # A command with no separator, read back through the client's own report of
  # the socket it resolved rather than through a failure.
  local out
  out=$("$HERDR_LAB_HELPER" run "$LAB_SESSION" status server 2>&1) || true
  case "$out" in
    *"$LAB_SESSION"*) : ;;
    *) fail "a plain command did not resolve to the lab session on $HERDR_VERSION; client said: $out" ;;
  esac
  case "$out" in
    *"$AMBIENT_SOCKET"*) fail "a plain command resolved to the ambient socket on $HERDR_VERSION; client said: $out" ;;
  esac
  pass "fm-herdr-lab: real Herdr resolves a plain command to the lab session"
}

test_the_client_really_drops_a_flag_after_the_separator() {
  # Without this, the comparisons above would hold on a client that ignored the
  # separator entirely, and the guard would prove nothing. Probed outside the
  # helper because the helper exists precisely to make this shape impossible.
  local out
  out=$(client_answer "${PASSTHROUGH[@]}" --session "$LAB_SESSION")
  [ "$out" = "$AMBIENT_ANSWER" ] \
    || fail "cannot confirm $HERDR_VERSION drops a --session after the passthrough separator; client said: $out"
  pass "fm-herdr-lab: a session flag after the passthrough separator does not route on real Herdr"
}

test_the_client_tells_the_two_destinations_apart
test_passthrough_command_is_answered_by_the_lab
test_plain_command_is_answered_by_the_lab
test_the_client_really_drops_a_flag_after_the_separator
