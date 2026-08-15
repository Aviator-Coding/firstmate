#!/usr/bin/env bash
# tests/fm-watch-arm.test.sh - the arm layer's cycle-close contract when the arm
# did not own the cycle.
#
# The watcher prints its one reason line to its OWN stdout, so only the arm that
# forked it ever reads that line. An arm that ATTACHED to an existing cycle holds
# no handle on it and can observe only a released lock, which is why a completely
# successful cycle used to be reported as
# "watcher: FAILED - cycle ended without an actionable reason" on every harness
# whose protocol reads that line. These are real-process tests: a real
# bin/fm-watch.sh holds the singleton, a real bin/fm-watch-arm.sh attaches to it,
# and a real status change drives a real wake through the watcher-bound delivery
# record and durable queue.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-arm-tests)

# Both starters background a real process the test later waits on, so they set a
# global instead of echoing: a command substitution would make the pid a child of
# a subshell this shell can no longer wait for.
SEED_PID=
ARM_PID=

# Start the real watcher as the singleton holder.
start_seed_watcher() {  # <state> <fakebin> <watch-out>
  local state=$1 fakebin=$2 out=$3 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "seed watcher did not take the lock"
}

# Attach a real arm to the live cycle.
start_attached_arm() {  # <state> <fakebin> <arm-out> <confirm-timeout>
  local state=$1 fakebin=$2 armout=$3 confirm=$4 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT="$confirm" "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$SEED_PID" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$SEED_PID" "$armout" \
    || fail "arm did not attach to the live watcher: $(cat "$armout")"
}

test_attached_arm_reports_the_delivered_wake() {
  local dir state fakebin out armout status
  dir=$(make_case attached-delivered-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A real captain-relevant status change: the watcher records it in the durable
  # queue, prints its one reason line to its own stdout, and exits.
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  grep -q '^signal:' "$out" || fail "seed watcher did not surface the signal wake: $(cat "$out")"

  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -q 'demo.status' "$state/.wake-queue" \
    || fail "the wake was not durably recorded, so this case proves nothing"
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported a delivered wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the durably recorded wake reason: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose cycle delivered a wake must close successfully"
  grep -q 'reason=attached-delivered-wake' "$state/.watch-cycle-exits.log" \
    || fail "the delivered-wake close was not classified in the lifecycle ledger"
  pass "watch-arm: an attached arm reports the wake its cycle delivered instead of a false failure"
}

test_attached_arm_reports_the_delivered_wake_after_drain() {
  local dir state fakebin out armout status
  dir=$(make_case attached-drained-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  # A wider confirmation budget keeps the arm in its successor wait while the
  # handling turn drains, which is the ordering this case exists to cover.
  start_attached_arm "$state" "$fakebin" "$armout" 5

  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  # The handling turn consumes the records before the attached arm closes: the
  # queue is empty again, while the watcher's identity-bound terminal record
  # still proves which cycle delivered the reason.
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  [ ! -s "$state/.wake-queue" ] || fail "drain left records behind"

  wait_for_exit "$ARM_PID" 200
  status=$?
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported an already-handled wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the delivered reason after the queue drain: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose wake was already drained must close successfully"
  pass "watch-arm: a delivered wake consumed by the handling turn still closes the attached arm cleanly"
}

test_attached_arm_still_fails_on_a_wake_it_did_not_deliver() {
  local dir state fakebin out armout status
  dir=$(make_case attached-no-delivery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A process-event producer advances the same home-wide queue while the
  # observed watcher remains uninvolved, so only watcher-bound evidence can
  # distinguish this from a delivered watcher cycle.
  append_wake "$state" check process-event "check: process-event result captured: fixture"
  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "a cycle that delivered nothing must still fail loudly: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "arm did not exit nonzero for a cycle that delivered nothing (status $status)"
  pass "watch-arm: a cycle that delivered no wake of its own still fails loudly"
}

# A lock-holding process that never writes a new beacon. Models a launched
# watcher that published ownership and then died or wedged before beating.
write_lock_only_watcher() {  # <dir>
  local dir=$1
  cat > "$dir/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  echo "watcher: already running pid ${FM_LOCK_HELD_PID:-}"
  exit 0
fi
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
identity=$(fm_pid_identity "${BASHPID:-$$}" 2>/dev/null || true)
printf '%s\n' "$identity" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true
# Deliberately never touch the liveness beacon.
sleep 300
SH
  chmod +x "$dir/bin/fm-watch.sh"
}

# Real arm script plus its lock/identity library, pointed at the lock-only
# watcher fixture so the confirm path is the production one.
install_real_arm_with_lock_only_watcher() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-watch-arm.sh" "$dir/bin/fm-watch-arm.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  chmod +x "$dir/bin/fm-watch-arm.sh"
  write_lock_only_watcher "$dir"
}

test_arm_does_not_report_started_when_child_never_beats() {
  local dir state armout armpid status i
  dir=$(make_case arm-false-started-no-beat)
  state="$dir/state"
  armout="$dir/arm.out"
  install_real_arm_with_lock_only_watcher "$dir"
  # Leftover fresh beacon from a previous cycle. Confirm must not treat that
  # leftover mtime as proof the new child is beating.
  touch "$state/.last-watcher-beat"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_CONFIRM_TIMEOUT=2 \
    FM_ARM_ATTACH_POLL=0.1 FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$dir/bin/fm-watch-arm.sh" > "$armout" 2>&1 &
  armpid=$!
  wait_for_exit "$armpid" 80
  status=$?

  ! grep -qF 'watcher: started' "$armout" \
    || fail "arm reported started without a beating watcher: $(cat "$armout")"
  ! grep -qE 'watcher: attached' "$armout" \
    || fail "arm attached to a lock-only phantom: $(cat "$armout")"
  grep -qF 'watcher: FAILED' "$armout" \
    || fail "arm did not fail loudly when the child never beat: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "arm exited $status after a launch that never produced a beating watcher"
  ! is_live_non_zombie "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" \
    || fail "a failed confirm left a live lock-only phantom running"
  pass "watch-arm: a child that never beats cannot be reported as started"
}

test_attached_arm_ignores_a_stale_delivery_record() {
  local dir state fakebin out armout status seed_pid seed_identity
  dir=$(make_case attached-stale-delivery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  seed_pid=$SEED_PID
  seed_identity=$(cat "$state/.watch.lock/pid-identity" 2>/dev/null || true)
  [ -n "$seed_identity" ] || fail "seed watcher did not publish a lock identity"
  # A leftover identity-bound row from an earlier cycle. Matching pid+identity
  # alone must not make this new attach look successful.
  printf '%s\t%s\t%s\n' "$seed_pid" "$seed_identity" \
    'signal: planted-stale-delivery' >> "$state/.watch-deliveries.log"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "a stale delivery record made a silent cycle look successful: $(cat "$armout")"
  ! grep -qF 'planted-stale-delivery' "$armout" \
    || fail "attached arm replayed a pre-cycle delivery record: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "attached arm exited $status after accepting a stale delivery record"
  pass "watch-arm: a stale delivery record cannot close an attached cycle as success"
}

test_plain_arm_does_not_attach_to_a_lock_only_phantom() {
  local dir state armout armpid status i lock_pid
  dir=$(make_case arm-plain-vs-restart-phantom)
  state="$dir/state"
  armout="$dir/arm.out"
  install_real_arm_with_lock_only_watcher "$dir"
  touch "$state/.last-watcher-beat"

  # A live lock holder with matching identity and a leftover fresh beacon is
  # the attach-to-phantom pre-state. Plain arm currently reports success here
  # while --restart replaces the holder with a real cycle.
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    "$dir/bin/fm-watch.sh" > "$dir/phantom.out" 2>&1 &
  lock_pid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$lock_pid" ] \
      && [ -s "$state/.watch.lock/pid-identity" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$lock_pid" ] \
    || fail "lock-only phantom did not publish a lock"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_CONFIRM_TIMEOUT=2 \
    FM_ARM_ATTACH_POLL=0.1 \
    "$dir/bin/fm-watch-arm.sh" > "$armout" 2>&1 &
  armpid=$!
  wait_for_exit "$armpid" 80
  status=$?
  ! grep -qE 'watcher: (started|attached)' "$armout" \
    || fail "plain arm claimed a lock-only phantom as a live cycle: $(cat "$armout")"
  grep -qF 'watcher: FAILED' "$armout" \
    || fail "plain arm did not fail a lock-only phantom: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "plain arm exited $status for a lock-only phantom"

  # --restart must still be able to replace that phantom. After the confirm
  # fix it kills or clears the holder and then fails the same way unless a
  # real watcher beats; the property here is that plain arm is no longer the
  # path that reports success for the dead cycle.
  kill "$lock_pid" "$armpid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "watch-arm: plain arm does not attach to a leftover-beacon lock-only phantom"
}

test_attached_arm_reports_the_delivered_wake
test_attached_arm_reports_the_delivered_wake_after_drain
test_attached_arm_still_fails_on_a_wake_it_did_not_deliver
test_arm_does_not_report_started_when_child_never_beats
test_attached_arm_ignores_a_stale_delivery_record
test_plain_arm_does_not_attach_to_a_lock_only_phantom
