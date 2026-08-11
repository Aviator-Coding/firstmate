#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
PROBE_LOG="$TMP_ROOT/herdr-probe.log"
TRIPWIRES="$TMP_ROOT/tripwires"
REAL_SLEEP=$(command -v sleep)
TAB=$(printf '\t')
# The socket every Herdr-managed pane exports, pointing at the session that
# spawned it. For a crewmate that is the fleet's live default session, so every
# helper call below is made under the exact ambient condition the lab has to
# survive.
AMBIENT_SOCKET='/home/test/.config/herdr/herdr.sock'
mkdir -p "$FAKE_STATE"
printf '%s\n' "$AMBIENT_SOCKET" > "$FAKE_STATE/default-socket"
: > "$FAKE_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
state=$FM_FAKE_HERDR_STATE
default_socket=$(cat "$state/default-socket")

# Resolve the answering session the way the real client does, verified against
# herdr 0.8.0 (docs/verification/runtime-backends.md "Lab session routing"): a
# --session flag is parsed before subcommand dispatch and wins;
# option parsing stops at a bare --, so a flag after it is agent passthrough and
# never routes; with no flag, HERDR_SOCKET_PATH outranks HERDR_SESSION; with
# neither, the default session answers.
flag_session=
args=()
passthrough=0
while [ "$#" -gt 0 ]; do
  if [ "$passthrough" -eq 0 ]; then
    case "$1" in
      --) passthrough=1 ;;
      --session) flag_session=${2:-}; shift 2; continue ;;
      --session=*) flag_session=${1#--session=}; shift; continue ;;
    esac
  fi
  args+=("$1")
  shift
done
[ "${FM_FAKE_HERDR_IGNORE_SESSION_FLAG:-}" != 1 ] || flag_session=
[ "${FM_FAKE_HERDR_IGNORE_SESSION_ENV:-}" != 1 ] || unset HERDR_SESSION

if [ -n "$flag_session" ]; then
  session=$flag_session
elif [ -n "${HERDR_SOCKET_PATH:-}" ]; then
  if [ "$HERDR_SOCKET_PATH" = "$default_socket" ]; then session=default; else session=ambient-unknown; fi
elif [ -n "${HERDR_SESSION:-}" ]; then
  session=$HERDR_SESSION
else
  session=default
fi

set -- "${args[@]+"${args[@]}"}"
printf '%s\t%s\n' "$session" "$*" >> "$FM_FAKE_HERDR_LOG"
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    if [ "$lab_state" = absent ] || [ "$lab_state" = deleted ]; then
      jq -nc --arg socket "$default_socket" '{sessions:[{default:true,name:"default",running:true,socket_path:$socket}]}'
    else
      running=false
      [ "$lab_state" = running ] && running=true
      jq -nc --arg socket "$default_socket" --arg name "$session" --argjson running "$running" \
        '{sessions:[{default:true,name:"default",running:true,socket_path:$socket},{default:false,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]}'
    fi
    ;;
  "server ")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    if [ "$lab_state" = running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    printf '%s\n' stopped > "$state/$session"
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    printf '%s\n' deleted > "$state/$session"
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-lab.sh"

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_FAKE_HERDR_IGNORE_SESSION_FLAG="${FM_FAKE_HERDR_IGNORE_SESSION_FLAG:-}" \
    FM_FAKE_HERDR_IGNORE_SESSION_ENV="${FM_FAKE_HERDR_IGNORE_SESSION_ENV:-}" \
    HERDR_SOCKET_PATH="$AMBIENT_SOCKET" \
    HERDR_SESSION=default \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

# Every logged call must have been answered by the lab session and nothing else.
assert_every_call_reached_the_lab() { # <session> <what>
  local name=$1 what=$2 resolved rest
  while IFS="$TAB" read -r resolved rest; do
    [ -n "$resolved" ] || continue
    [ "$resolved" = "$name" ] \
      || fail "$what reached session '$resolved' instead of the lab: $rest"
  done < "$FAKE_LOG"
  assert_absent "$FAKE_STATE/default" "$what mutated the ambient default session"
}

# Resolve one raw client call outside the helper, to characterise the client
# itself rather than the helper's use of it.
probe_resolved_session() { # <herdr arguments...>
  : > "$PROBE_LOG"
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$PROBE_LOG" \
    HERDR_SOCKET_PATH="$AMBIENT_SOCKET" \
    herdr "$@" >/dev/null 2>&1 || true
  cut -d"$TAB" -f1 < "$PROBE_LOG"
}

test_refuses_unsafe_names() {
  local status=0 generated
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
  generated=$(fm_herdr_lab_name fm-autodetect-smoke-concurrency-h3)
  fm_herdr_lab_validate_name "$generated" || fail "generated lab session name was refused"
  [ "${#generated}" -le 40 ] || fail "generated lab session name is too long for Herdr socket paths: $generated"
  pass "fm-herdr-lab: names fail closed and require the lab prefix"
}

test_provision_run_and_guarded_teardown() {
  local name='' line_count status=0 stop_line delete_line
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"

  run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "safe run command failed"
  run_with_fake fm_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bare server start outside provision must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server-global stop must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "direct session delete must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session=default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied equals-form session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --handoff server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting server stop past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --no-session session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting session delete past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --remote host workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option subverting session isolation must be refused"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful teardown left its tripwire behind"

  assert_every_call_reached_the_lab "$name" "a lifecycle call"
  line_count=$(wc -l < "$FAKE_LOG" | tr -d ' ')
  stop_line=$(grep -n "^$name${TAB}session stop $name --json$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^$name${TAB}session delete $name --json$" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$delete_line" ] || [ "$line_count" -le "$delete_line" ]; then
    fail "teardown did not emit explicit stop/delete followed by the after tripwire"
  fi
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" | grep -F "session list --json" >/dev/null \
    || fail "stop was not immediately preceded by a fresh refuse-default session list"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json" >/dev/null \
    || fail "delete was not immediately preceded by a fresh refuse-default session list"
  pass "fm-herdr-lab: provisioning, scoped calls, guarded teardown, and fleet tripwire are deterministic"
}

test_passthrough_cannot_reach_the_ambient_session() {
  local name="fm-lab-passthrough-$$" resolved
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "passthrough fixture provision failed"

  # Keep the regression from going quietly vacuous: the shape this helper used
  # to build - isolating flag last, agent passthrough separator in the middle -
  # really is answered by the ambient session, here as on herdr 0.8.0.
  resolved=$(probe_resolved_session agent start probe --kind claude --pane w1:p8 \
    -- --model haiku --session "$name")
  [ "$resolved" = default ] \
    || fail "fixture does not reproduce the passthrough leak (resolved '$resolved'); the assertion below would prove nothing"

  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_cli "$name" agent start probe --kind claude --pane w1:p8 \
    -- --model haiku >/dev/null || fail "an agent-argument passthrough command was rejected outright"
  assert_every_call_reached_the_lab "$name" "an agent-argument passthrough command"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "passthrough fixture teardown failed"
  pass "fm-herdr-lab: an agent-argument passthrough command cannot reach the ambient session"
}

test_leading_flag_alone_survives_the_passthrough_separator() {
  local name="fm-lab-leading-flag-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "leading-flag fixture provision failed"
  : > "$FAKE_LOG"
  # The flag is the primary isolation, so it has to hold on its own. Drop the
  # HERDR_SESSION fallback - bin/backends/herdr.sh records that a real client
  # does not reliably honor it once another server is bound - and only a flag
  # placed ahead of the bare -- still routes the call.
  FM_FAKE_HERDR_IGNORE_SESSION_ENV=1 \
    run_with_fake fm_herdr_lab_cli "$name" agent start probe --kind claude --pane w1:p8 \
    -- --model haiku >/dev/null \
    || fail "an agent-argument passthrough command was rejected outright"
  assert_every_call_reached_the_lab "$name" "a passthrough command without the session env fallback"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "leading-flag fixture teardown failed"
  pass "fm-herdr-lab: the leading session flag alone survives the agent-argument separator"
}

test_isolation_survives_losing_the_session_flag() {
  local name="fm-lab-flagless-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "flagless fixture provision failed"
  : > "$FAKE_LOG"
  # Defense in depth against a client that stops honoring the flag: the ambient
  # socket path is what wins precedence, so the lab must not leave it in place.
  FM_FAKE_HERDR_IGNORE_SESSION_FLAG=1 \
    run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null \
    || fail "flagless run command failed"
  assert_every_call_reached_the_lab "$name" "a command whose session flag was ignored"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "flagless fixture teardown failed"
  pass "fm-herdr-lab: losing the session flag falls back into the lab, never the ambient session"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" status=0 before after
  printf '%s\n' running > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse teardown"
  after=$(wc -l < "$FAKE_LOG")
  [ "$before" = "$after" ] || fail "missing tripwire reached Herdr instead of refusing before destructive calls"
  pass "fm-herdr-lab: missing tripwire refuses teardown before any Herdr call"
}

test_changed_default_trips_after_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  printf '%s\n' '/changed/default.sock' > "$FAKE_STATE/default-socket"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default fleet state must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  pass "fm-herdr-lab: changed default fleet state is a hard failure"
}

test_stopped_owned_lab_can_reprovision() {
  local name="fm-lab-reprovision-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "initial provision failed"
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "stop removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_provision "$name" || fail "re-provision after guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "re-provision did not restart the stopped lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "re-provision removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after re-provision failed"
  pass "fm-herdr-lab: an owned stopped lab can re-provision safely"
}

test_failed_delete_retains_tripwire() {
  local name="fm-lab-delete-failure-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "delete-failure fixture provision failed"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed delete must fail teardown"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "failed delete unexpectedly removed the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed delete removed the ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "retry after failed delete did not clean up the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful retry left the ownership tripwire behind"
  pass "fm-herdr-lab: failed deletion retains ownership until absence is confirmed"
}

test_timed_out_provision_cancels_late_launch() {
  local name="fm-lab-late-launch-$$" status=0
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
  chmod +x "$FAKEBIN/sleep"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "timed-out provision must fail"
  assert_present "$TRIPWIRES/$name.fleet-state.json" \
    "timed-out provision must retain its tripwire until teardown"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after timed-out provision failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "teardown after timed-out provision did not remove its tripwire"
  "$REAL_SLEEP" 1.1
  if [ -f "$FAKE_STATE/$name" ] && [ "$(cat "$FAKE_STATE/$name")" = running ]; then
    fail "timed-out provision left a late-starting lab session after teardown"
  fi
  pass "fm-herdr-lab: timed-out provisioning cancels the launch before teardown"
}

test_refuses_unsafe_names
test_provision_run_and_guarded_teardown
test_passthrough_cannot_reach_the_ambient_session
test_leading_flag_alone_survives_the_passthrough_separator
test_isolation_survives_losing_the_session_flag
test_missing_tripwire_blocks_destruction
test_changed_default_trips_after_teardown
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_timed_out_provision_cancels_late_launch
