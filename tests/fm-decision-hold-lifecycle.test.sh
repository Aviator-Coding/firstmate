#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}

# Shape 1 of the stranded-hold gap: the captain answers, the dependent work is
# dispatched, validated, merged and torn down inside one session, and the hold can
# no longer close through its owner script. Completed dependent work that still
# carries the hold's blocked-by edge is the strongest available evidence that the
# decision was acted on, so it must resolve rather than refuse.
test_resolve_closes_holds_whose_routed_work_completed() {
  local home origin hold unrouted show json
  home=$(make_home resolve-after-completion)
  origin=sample-completed-route-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Completed route review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create completed-route origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Completed route review\n\nOne unresolved captain choice.\n' > "$home/data/$origin/report.md"

  hold=$(run_decisions "$home" hold "$origin" route \
    --title "Choose the completed route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register the completed-route hold"

  tasks_in "$home" add sample-done-route "Apply the chosen route" --kind ship --repo sample \
    --blocked-by "$hold" >/dev/null || fail "could not create routed dependent work"
  tasks_in "$home" "done" sample-done-route >/dev/null \
    || fail "could not complete routed dependent work"
  show=$(tasks_in "$home" show sample-done-route --full)
  assert_contains "$show" "state: done" "routed work fixture must be complete"
  assert_contains "$show" "blocked_by: $hold" \
    "completed routed work must retain the durable routing edge the close depends on"

  printf 'Take the north route.\n' > "$home/done-route-decision.txt"
  run_decisions "$home" resolve "$origin" route --decision-file "$home/done-route-decision.txt" \
    --routed-to sample-done-route > "$home/done-route.out" 2> "$home/done-route.err" \
    || fail "resolve refused a hold whose routed work had completed: $(cat "$home/done-route.err")"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "a hold with completed routed work did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" \
    "the closed hold lost its durable decision record"
  assert_contains "$show" "Routed work:" "the closed hold lost its routed identities"

  run_decisions "$home" resolve "$origin" route --decision-file "$home/done-route-decision.txt" \
    --routed-to sample-done-route >/dev/null \
    || fail "resolve against completed routed work was not idempotent on retry"
  printf 'Take the south route.\n' > "$home/changed-done-route-decision.txt"
  if run_decisions "$home" resolve "$origin" route \
    --decision-file "$home/changed-done-route-decision.txt" --routed-to sample-done-route \
    > "$home/done-drift.out" 2> "$home/done-drift.err"; then
    fail "resolve accepted a different captain decision for completed routed work"
  fi

  json=$(run_bearings "$home") || fail "Bearings failed after resolving completed routed work"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    (.decisions_open | any(.id == $hold) | not)
      and (.landed | any(.id == $hold) | not)
  ' >/dev/null || fail "a closed hold still projected as an open captain decision: $json"

  # Accepting completed dependent work must not weaken the refusals that carry the
  # safety property: the routed task must exist and must be blocked by this hold.
  unrouted=$(run_decisions "$home" hold "$origin" unrouted \
    --title "Choose the unrouted option" --reason "captain unrouted choice pending" --repo sample) \
    || fail "could not register the unrouted control hold"
  if run_decisions "$home" resolve "$origin" unrouted --decision-file "$home/done-route-decision.txt" \
    --routed-to sample-missing-route > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "resolve accepted a routed task that does not exist"
  fi
  assert_grep "does not exist in the active home" "$home/missing-route.err" \
    "an absent routed task must fail with the existence error"

  tasks_in "$home" add sample-unrelated-done "Unrelated finished work" --kind ship --repo sample >/dev/null \
    || fail "could not create unrelated finished work"
  tasks_in "$home" "done" sample-unrelated-done >/dev/null \
    || fail "could not complete unrelated work"
  if run_decisions "$home" resolve "$origin" unrouted --decision-file "$home/done-route-decision.txt" \
    --routed-to sample-unrelated-done > "$home/unrelated.out" 2> "$home/unrelated.err"; then
    fail "completed work that was never blocked by the hold closed it"
  fi
  assert_grep "not durably blocked by" "$home/unrelated.err" \
    "completed but unrouted work must fail with the durable-block error"
  show=$(tasks_in "$home" show "$unrouted" --full)
  assert_contains "$show" "state: queued" "a refused resolve must leave the hold open"
  assert_contains "$show" "held: yes" "a refused resolve must leave the hold held"
  pass "resolve closes a hold whose routed work already completed and keeps its routing refusals"
}

# One piece of work often answers two captain decisions at once. It must be able
# to carry both hold edges simultaneously and have each close independently, so
# that answering the first decision neither drops the second edge nor needs the
# row rewritten by hand between the two closes.
test_one_task_answers_two_decisions() {
  local home origin first second show
  home=$(make_home two-edge-answer)
  origin=sample-two-answer-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Two-answer review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the two-answer origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Two-answer review\n\nTwo choices answered by one change.\n' > "$home/data/$origin/report.md"

  first=$(run_decisions "$home" hold "$origin" relocation \
    --title "Choose the relocation" --reason "captain relocation choice pending" --repo sample) \
    || fail "could not register the relocation hold"
  second=$(run_decisions "$home" hold "$origin" one-place \
    --title "Choose where a finding lands" --reason "captain landing choice pending" --repo sample) \
    || fail "could not register the landing hold"

  tasks_in "$home" add sample-answers-both "Apply both choices" --kind ship --repo sample >/dev/null \
    || fail "could not create the answering work"
  tasks_in "$home" block sample-answers-both --by "$first" >/dev/null \
    || fail "could not record the first edge"
  tasks_in "$home" block sample-answers-both --by "$second" >/dev/null \
    || fail "could not record the second edge"
  show=$(tasks_in "$home" show sample-answers-both --full)
  assert_contains "$show" "blocked_by: \"$first,$second\"" \
    "one task must carry both hold edges at once"

  printf 'Relocate it.\n' > "$home/answer-first.txt"
  run_decisions "$home" resolve "$origin" relocation --decision-file "$home/answer-first.txt" \
    --routed-to sample-answers-both > "$home/two-first.out" 2> "$home/two-first.err" \
    || fail "the first of two decisions did not close: $(cat "$home/two-first.err")"
  show=$(tasks_in "$home" show sample-answers-both --full)
  assert_contains "$show" "blocked_by: $second" \
    "closing the first decision must clear only its own edge and keep the second"

  printf 'Land it in one place.\n' > "$home/answer-second.txt"
  run_decisions "$home" resolve "$origin" one-place --decision-file "$home/answer-second.txt" \
    --routed-to sample-answers-both > "$home/two-second.out" 2> "$home/two-second.err" \
    || fail "the second of two decisions did not close: $(cat "$home/two-second.err")"
  show=$(tasks_in "$home" show sample-answers-both --full)
  assert_contains "$show" "blocked_by: none" "closing both decisions must leave the work unblocked"
  assert_contains "$show" "state: queued" "the answering work must stay dispatchable"

  for show in "$first" "$second"; do
    assert_contains "$(tasks_in "$home" show "$show" --full)" "state: done" \
      "hold $show did not close against work that answered both decisions"
  done
  pass "one task carries two decision edges and each closes independently"
}

# Closing several holds in one batch is the ordinary case, not an edge case: each
# close appends a row to Done, and Done retention archives the oldest rows to stay
# at its limit. The routed work a batch closes against has usually completed some
# time ago, so it sits near the bottom of Done and the earliest closes push it out
# from under the later ones. The batch must not depend on the order the holds are
# closed in, nor on how much unrelated Done churn ran alongside it.
test_batch_close_survives_done_retention_pruning() {
  local home origin keep k hold show json archived
  home=$(make_home batch-retention)
  origin=sample-batch-review
  mkdir -p "$home/data/$origin"
  keep=$(sed -n 's/^[[:space:]]*done_keep[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$home/.tasks.toml" | head -1)
  [ -n "$keep" ] || fail "the fixture backlog config declares no Done retention limit"
  tasks_in "$home" add "$origin" "Batch review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the batch origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Batch review\n\nThree unresolved captain choices.\n' > "$home/data/$origin/report.md"

  for k in one two three; do
    run_decisions "$home" hold "$origin" "$k" --title "Choose option $k" \
      --reason "captain choice $k pending" --repo sample >/dev/null \
      || fail "could not register the $k hold"
    tasks_in "$home" add "sample-routed-$k" "Apply option $k" --kind ship --repo sample \
      --blocked-by "$origin-decision-$k" >/dev/null \
      || fail "could not create routed work for $k"
    tasks_in "$home" "done" "sample-routed-$k" >/dev/null \
      || fail "could not complete routed work for $k"
    printf 'Take option %s.\n' "$k" > "$home/decision-$k.txt"
  done

  # Ordinary later work fills Done to its retention limit, so the routed rows are
  # the oldest entries and the first close in the batch starts archiving them.
  for k in $(seq 1 "$((keep - 3))"); do
    tasks_in "$home" add "sample-filler-$k" "Unrelated finished work $k" --kind ship --repo sample >/dev/null \
      || fail "could not create filler work $k"
    tasks_in "$home" "done" "sample-filler-$k" >/dev/null || fail "could not complete filler work $k"
  done
  tasks_in "$home" show sample-routed-one --full >/dev/null \
    || fail "the fixture must start with every routed row still in the live backlog"

  # Closed in the order that pushes each routed row out from under a later close.
  for k in three two one; do
    run_decisions "$home" resolve "$origin" "$k" --decision-file "$home/decision-$k.txt" \
      --routed-to "sample-routed-$k" > "$home/batch-$k.out" 2> "$home/batch-$k.err" \
      || fail "closing $k in a batch needed manual recovery: $(cat "$home/batch-$k.err")"
  done

  archived=0
  for k in one two three; do
    tasks_in "$home" show "sample-routed-$k" --full >/dev/null 2>&1 || archived=$((archived + 1))
  done
  [ "$archived" -gt 0 ] \
    || fail "the fixture never pruned a routed row, so it does not exercise the retention gap"

  for k in one two three; do
    hold="$origin-decision-$k"
    show=$(run_decisions "$home" verify "$origin" 2>/dev/null; tasks_in "$home" show "$hold" --full) \
      || fail "closed hold $hold vanished from the home"
    assert_contains "$show" "state: done" "hold $hold did not close in the batch"
    assert_contains "$show" "Resolution recorded by fm-decision-hold" \
      "hold $hold lost its durable decision record"
    assert_contains "$show" "sample-routed-$k" "hold $hold lost its routed identity"
  done

  # Reading the archive must not weaken either refusal the close depends on.
  run_decisions "$home" hold "$origin" four --title "Choose option four" \
    --reason "captain choice four pending" --repo sample >/dev/null \
    || fail "could not register the control hold"
  if run_decisions "$home" resolve "$origin" four --decision-file "$home/decision-one.txt" \
    --routed-to sample-never-existed > "$home/control.out" 2> "$home/control.err"; then
    fail "resolve accepted a routed task that exists in neither the backlog nor the archive"
  fi
  assert_grep "does not exist in the active home" "$home/control.err" \
    "an absent routed task must still fail with the existence error"
  if run_decisions "$home" resolve "$origin" four --decision-file "$home/decision-one.txt" \
    --routed-to sample-filler-1 > "$home/control2.out" 2> "$home/control2.err"; then
    fail "archived-or-live lookup let unrouted finished work close a hold"
  fi
  assert_grep "not durably blocked by" "$home/control2.err" \
    "finished work that was never routed must still fail with the durable-block error"
  show=$(tasks_in "$home" show "$origin-decision-four" --full)
  assert_contains "$show" "state: queued" "a refused resolve must leave the control hold open"
  assert_contains "$show" "held: yes" "a refused resolve must leave the control hold held"

  json=$(run_bearings "$home") || fail "Bearings failed after the batch close"
  printf '%s' "$json" | jq -e --arg origin "$origin" '
    [.decisions_open[]? | select(.id | startswith($origin + "-decision-"))]
    | length == 1 and .[0].id == ($origin + "-decision-four")
  ' >/dev/null || fail "the batch left the wrong set of decisions open: $json"
  pass "a batch of closes survives Done retention pruning without manual recovery"
}

# Shape 2 of the stranded-hold gap: a hold registered in error, for a choice that
# had already been taken and executed. There is no captain answer to record, so
# resolve cannot close it and no supported path existed at all.
test_withdraw_closes_a_hold_registered_in_error() {
  local home origin hold answered show json
  home=$(make_home withdraw-registered-in-error)
  origin=sample-withdrawal-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Withdrawal review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create withdrawal origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Withdrawal review\n\nOne choice was registered in error.\n' > "$home/data/$origin/report.md"

  hold=$(run_decisions "$home" hold "$origin" duplicate \
    --title "Approve the already-executed cleanup" --reason "captain approval pending" --repo sample) \
    || fail "could not register the withdrawal hold"

  # A withdrawal needs a durable record exactly as a resolution needs a decision
  # file, and none of these refusals may close the hold.
  if run_decisions "$home" withdraw "$origin" duplicate \
    > "$home/no-reason.out" 2> "$home/no-reason.err"; then
    fail "withdraw closed a hold with no durable reason"
  fi
  assert_grep "--reason-file is required" "$home/no-reason.err" \
    "withdraw without a reason must name the missing requirement"
  if run_decisions "$home" withdraw "$origin" duplicate --reason-file "$home/absent-reason.txt" \
    > "$home/absent-reason.out" 2> "$home/absent-reason.err"; then
    fail "withdraw accepted a reason file that does not exist"
  fi
  : > "$home/empty-reason.txt"
  if run_decisions "$home" withdraw "$origin" duplicate --reason-file "$home/empty-reason.txt" \
    > "$home/empty-reason.out" 2> "$home/empty-reason.err"; then
    fail "withdraw accepted an empty reason file"
  fi
  set +e
  run_decisions "$home" withdraw "$origin" duplicate --reason-file "$home/empty-reason.txt" \
    --routed-to sample-any-routed-task > "$home/routed-withdraw.out" 2> "$home/routed-withdraw.err"
  expect_code 2 "$?" "withdraw must reject --routed-to because a withdrawn hold routed nothing"
  set -e
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused withdrawal closed the hold"
  assert_contains "$show" "held: yes" "a refused withdrawal released the hold"

  printf 'Registered in error: this deletion was already approved and executed the same day.\n' \
    > "$home/withdrawal-reason.txt"
  run_decisions "$home" withdraw "$origin" duplicate --reason-file "$home/withdrawal-reason.txt" \
    > "$home/withdraw.out" 2> "$home/withdraw.err" \
    || fail "withdraw could not close a hold registered in error: $(cat "$home/withdraw.err")"
  assert_grep "withdrawn: $hold" "$home/withdraw.out" "withdraw must report the closed identity"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the withdrawn hold did not close"
  assert_contains "$show" "Withdrawn by fm-decision-hold" "the withdrawn hold lost its durable record"
  assert_contains "$show" "already approved and executed the same day" \
    "the withdrawn hold lost the written reason"
  assert_not_contains "$show" "Resolution recorded by fm-decision-hold" \
    "a withdrawal must stay distinguishable from a recorded captain decision"

  run_decisions "$home" withdraw "$origin" duplicate --reason-file "$home/withdrawal-reason.txt" >/dev/null \
    || fail "withdrawal was not idempotent on retry"
  printf 'A different account of why this was withdrawn.\n' > "$home/changed-withdrawal-reason.txt"
  if run_decisions "$home" withdraw "$origin" duplicate \
    --reason-file "$home/changed-withdrawal-reason.txt" \
    > "$home/withdraw-drift.out" 2> "$home/withdraw-drift.err"; then
    fail "withdrawal retry accepted a different written reason"
  fi

  # A withdrawn hold is durably closed, not open work, and cannot be reopened or
  # re-closed down the other path.
  json=$(run_bearings "$home") || fail "Bearings failed after a withdrawal"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    (.decisions_open | any(.id == $hold) | not)
      and (.landed | any(.id == $hold) | not)
  ' >/dev/null || fail "a withdrawn hold still projected as an open captain decision: $json"
  run_decisions "$home" complete "$origin" duplicate >/dev/null \
    || fail "completion rejected a durably withdrawn decision key"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "verification rejected a durably withdrawn decision key"
  if run_decisions "$home" hold "$origin" duplicate \
    --title "Approve the already-executed cleanup" --reason "captain approval pending" --repo sample \
    > "$home/reopen.out" 2> "$home/reopen.err"; then
    fail "a durably withdrawn decision key was reopened"
  fi
  assert_grep "already durably withdrawn" "$home/reopen.err" \
    "reopening a withdrawn key must say it was withdrawn, not resolved"
  tasks_in "$home" add sample-late-route "Late dependent work" --kind ship --repo sample \
    --blocked-by "$hold" >/dev/null || fail "could not create late dependent work"
  printf 'Take the late route.\n' > "$home/late-decision.txt"
  if run_decisions "$home" resolve "$origin" duplicate --decision-file "$home/late-decision.txt" \
    --routed-to sample-late-route > "$home/late-resolve.out" 2> "$home/late-resolve.err"; then
    fail "resolve reopened and re-closed a durably withdrawn hold"
  fi
  assert_grep "is not queued" "$home/late-resolve.err" \
    "resolving a withdrawn hold must fail the not-queued refusal"

  # The reverse direction is refused too: a recorded captain decision may not be
  # overwritten by a withdrawal.
  answered=$(run_decisions "$home" hold "$origin" answered \
    --title "Choose the answered option" --reason "captain answered choice pending" --repo sample) \
    || fail "could not register the answered hold"
  tasks_in "$home" add sample-answered-work "Apply the answered choice" --kind ship --repo sample \
    --blocked-by "$answered" >/dev/null || fail "could not create answered dependent work"
  printf 'Take the answered option.\n' > "$home/answered-decision.txt"
  run_decisions "$home" resolve "$origin" answered --decision-file "$home/answered-decision.txt" \
    --routed-to sample-answered-work >/dev/null \
    || fail "could not resolve the answered hold"
  if run_decisions "$home" withdraw "$origin" answered --reason-file "$home/withdrawal-reason.txt" \
    > "$home/withdraw-answered.out" 2> "$home/withdraw-answered.err"; then
    fail "withdrawal overwrote a recorded captain decision"
  fi
  assert_grep "already records a captain decision" "$home/withdraw-answered.err" \
    "withdrawing an answered hold must name the recorded decision"
  show=$(tasks_in "$home" show "$answered" --full)
  assert_contains "$show" "Resolution recorded by fm-decision-hold" \
    "a refused withdrawal damaged the recorded captain decision"
  pass "withdraw closes a hold registered in error and stays distinct from a captain decision"
}

# After update --body succeeds and tasks-axi done fails once, the hold stays queued
# with close text already stored. That partial-close window must re-verify identity
# on exact retry, reject a changed record, and refuse the opposite close path.
test_partial_close_identity_survives_done_failure() {
  local home origin hold show

  # Partial withdrawal: changed reason is refused; exact retry still closes.
  home=$(make_home partial-withdraw-identity)
  origin=sample-partial-withdraw-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Partial withdraw review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create partial-withdraw origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Partial withdraw review\n\nOne hold registered in error.\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" mistaken \
    --title "Approve an already-taken choice" --reason "registered in error" --repo sample) \
    || fail "could not register the partial-withdraw hold"
  printf 'Registered in error: the choice was already executed.\n' > "$home/partial-withdraw-reason.txt"
  printf 'A different account of the same registration error.\n' > "$home/changed-partial-withdraw-reason.txt"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ ! -f "$FM_HOME/done-failed-once" ]; then
  : > "$FM_HOME/done-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" withdraw "$origin" mistaken \
    --reason-file "$home/partial-withdraw-reason.txt" \
    > "$home/partial-withdraw.out" 2> "$home/partial-withdraw.err"; then
    fail "withdrawal succeeded after a forced done failure"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "partial withdrawal closed the hold before done succeeded"
  assert_contains "$show" "Withdrawn by fm-decision-hold" \
    "partial withdrawal did not store the durable reason before done failed"
  assert_contains "$show" "the choice was already executed" \
    "partial withdrawal lost the written reason"
  if run_decisions "$home" withdraw "$origin" mistaken \
    --reason-file "$home/changed-partial-withdraw-reason.txt" \
    > "$home/partial-withdraw-drift.out" 2> "$home/partial-withdraw-drift.err"; then
    fail "partial withdrawal retry accepted a different written reason"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "the choice was already executed" \
    "a drifted partial-withdraw retry overwrote the stored reason"
  assert_not_contains "$show" "A different account of the same registration error" \
    "a drifted partial-withdraw retry wrote the changed reason"
  run_decisions "$home" withdraw "$origin" mistaken \
    --reason-file "$home/partial-withdraw-reason.txt" >/dev/null \
    || fail "exact partial-withdraw retry did not close the hold"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "exact partial-withdraw retry left the hold open"
  assert_contains "$show" "the choice was already executed" \
    "exact partial-withdraw retry lost the stored reason"

  # Partial resolution body refuses withdraw and keeps the captain decision.
  home=$(make_home partial-resolve-blocks-withdraw)
  origin=sample-partial-resolve-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Partial resolve review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create partial-resolve origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Partial resolve review\n\nOne answered hold.\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" answered \
    --title "Choose the answered option" --reason "captain answer pending" --repo sample) \
    || fail "could not register the partial-resolve hold"
  tasks_in "$home" add sample-partial-resolve-work "Apply the answered choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create partial-resolve dependent work"
  printf 'Take the answered option.\n' > "$home/partial-resolve-decision.txt"
  printf 'Registered in error after a partial resolution.\n' > "$home/partial-resolve-withdraw-reason.txt"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ ! -f "$FM_HOME/done-failed-once" ]; then
  : > "$FM_HOME/done-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$origin" answered \
    --decision-file "$home/partial-resolve-decision.txt" \
    --routed-to sample-partial-resolve-work \
    > "$home/partial-resolve.out" 2> "$home/partial-resolve.err"; then
    fail "resolution succeeded after a forced done failure"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "partial resolution closed the hold before done succeeded"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" \
    "partial resolution did not store the captain decision before done failed"
  assert_contains "$show" "Take the answered option." \
    "partial resolution lost the captain decision text"
  if run_decisions "$home" withdraw "$origin" answered \
    --reason-file "$home/partial-resolve-withdraw-reason.txt" \
    > "$home/partial-resolve-withdraw.out" 2> "$home/partial-resolve-withdraw.err"; then
    fail "withdraw replaced a partially recorded captain decision"
  fi
  assert_grep "already records a captain decision" "$home/partial-resolve-withdraw.err" \
    "withdrawing a partial resolution must name the recorded decision"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "Resolution recorded by fm-decision-hold" \
    "withdraw damaged a partially recorded captain decision"
  assert_contains "$show" "Take the answered option." \
    "withdraw overwrote the partially recorded captain decision text"
  assert_not_contains "$show" "Withdrawn by fm-decision-hold" \
    "withdraw wrote a withdrawal over a partial resolution"
  run_decisions "$home" resolve "$origin" answered \
    --decision-file "$home/partial-resolve-decision.txt" \
    --routed-to sample-partial-resolve-work >/dev/null \
    || fail "exact partial-resolve retry did not close the hold"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "exact partial-resolve retry left the hold open"
  assert_contains "$show" "Take the answered option." \
    "exact partial-resolve retry lost the captain decision"

  # Partial withdrawal body refuses resolve and keeps the withdrawal reason.
  home=$(make_home partial-withdraw-blocks-resolve)
  origin=sample-partial-cross-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Partial cross review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create partial-cross origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Partial cross review\n\nOne hold registered in error.\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" mistaken \
    --title "Approve an already-taken choice" --reason "registered in error" --repo sample) \
    || fail "could not register the partial-cross hold"
  tasks_in "$home" add sample-partial-cross-work "Late dependent work" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create partial-cross dependent work"
  printf 'Registered in error: no captain answer belongs here.\n' > "$home/partial-cross-reason.txt"
  printf 'Invent a captain answer after a partial withdrawal.\n' > "$home/partial-cross-decision.txt"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ ! -f "$FM_HOME/done-failed-once" ]; then
  : > "$FM_HOME/done-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" withdraw "$origin" mistaken \
    --reason-file "$home/partial-cross-reason.txt" \
    > "$home/partial-cross-withdraw.out" 2> "$home/partial-cross-withdraw.err"; then
    fail "cross-path withdrawal succeeded after a forced done failure"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "partial cross withdrawal closed the hold before done succeeded"
  assert_contains "$show" "Withdrawn by fm-decision-hold" \
    "partial cross withdrawal did not store its reason before done failed"
  assert_contains "$show" "no captain answer belongs here" \
    "partial cross withdrawal lost the written reason"
  if run_decisions "$home" resolve "$origin" mistaken \
    --decision-file "$home/partial-cross-decision.txt" \
    --routed-to sample-partial-cross-work \
    > "$home/partial-cross-resolve.out" 2> "$home/partial-cross-resolve.err"; then
    fail "resolve replaced a partially recorded withdrawal"
  fi
  assert_grep "already records a withdrawal" "$home/partial-cross-resolve.err" \
    "resolving a partial withdrawal must name the recorded withdrawal"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "Withdrawn by fm-decision-hold" \
    "resolve damaged a partially recorded withdrawal"
  assert_contains "$show" "no captain answer belongs here" \
    "resolve overwrote the partially recorded withdrawal reason"
  assert_not_contains "$show" "Resolution recorded by fm-decision-hold" \
    "resolve wrote a resolution over a partial withdrawal"
  run_decisions "$home" withdraw "$origin" mistaken \
    --reason-file "$home/partial-cross-reason.txt" >/dev/null \
    || fail "exact partial-cross withdraw retry did not close the hold"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "exact partial-cross withdraw retry left the hold open"
  assert_contains "$show" "no captain answer belongs here" \
    "exact partial-cross withdraw retry lost the stored reason"

  pass "partial close identity is stable across a done failure on both paths"
}

# Free text inside a decision or reason may quote the other path's marker sentence.
# Classification must use the canonical recorded body prefix, not a substring match,
# or an exact retry after a partial close would misroute and refuse identity re-verify.
test_queued_close_markers_ignore_free_text_phrases() {
  local home origin hold show

  # Withdrawal reason quotes the resolution marker; exact retry must still close.
  home=$(make_home marker-in-withdraw-reason)
  origin=sample-marker-withdraw-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Marker withdraw review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create marker-withdraw origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Marker withdraw review\n\nOne hold registered in error.\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" mistaken \
    --title "Approve an already-taken choice" --reason "registered in error" --repo sample) \
    || fail "could not register the marker-withdraw hold"
  printf 'Registered in error after someone wrote Resolution recorded by fm-decision-hold. in notes.\n' \
    > "$home/marker-withdraw-reason.txt"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ ! -f "$FM_HOME/done-failed-once" ]; then
  : > "$FM_HOME/done-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" withdraw "$origin" mistaken \
    --reason-file "$home/marker-withdraw-reason.txt" \
    > "$home/marker-withdraw.out" 2> "$home/marker-withdraw.err"; then
    fail "marker withdrawal succeeded after a forced done failure"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" \
    "marker withdrawal closed the hold before done succeeded"
  assert_contains "$show" "Withdrawn by fm-decision-hold" \
    "marker withdrawal did not store its durable reason before done failed"
  assert_contains "$show" "Resolution recorded by fm-decision-hold." \
    "marker withdrawal lost the quoted resolution phrase inside the reason"
  run_decisions "$home" withdraw "$origin" mistaken \
    --reason-file "$home/marker-withdraw-reason.txt" >/dev/null \
    || fail "exact marker-withdraw retry refused a genuine withdrawal whose reason quotes the resolution marker"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "exact marker-withdraw retry left the hold open"
  assert_contains "$show" "Withdrawn by fm-decision-hold" \
    "exact marker-withdraw retry lost the withdrawal record"
  assert_contains "$show" "someone wrote Resolution recorded by fm-decision-hold. in notes" \
    "exact marker-withdraw retry lost the free-text reason"
  run_decisions "$home" complete "$origin" mistaken >/dev/null \
    || fail "completion rejected a withdrawn hold whose reason quotes the resolution marker"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "verification rejected a withdrawn hold whose reason quotes the resolution marker"
  if run_decisions "$home" hold "$origin" mistaken \
    --title "Approve an already-taken choice" --reason "registered in error" --repo sample \
    > "$home/marker-withdraw-reopen.out" 2> "$home/marker-withdraw-reopen.err"; then
    fail "a withdrawn hold whose reason quotes the resolution marker was treated as unresolved"
  fi
  assert_grep "already durably withdrawn" "$home/marker-withdraw-reopen.err" \
    "a done withdrawal with a resolution phrase in free text must still classify as withdrawn"

  # Resolution decision quotes the withdrawal marker; exact retry must still close.
  home=$(make_home marker-in-resolve-decision)
  origin=sample-marker-resolve-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Marker resolve review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create marker-resolve origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Marker resolve review\n\nOne answered hold.\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" answered \
    --title "Choose the answered option" --reason "captain answer pending" --repo sample) \
    || fail "could not register the marker-resolve hold"
  tasks_in "$home" add sample-marker-resolve-work "Apply the answered choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create marker-resolve dependent work"
  printf 'Take the answered option, and ignore any note saying Withdrawn by fm-decision-hold.\n' \
    > "$home/marker-resolve-decision.txt"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ ! -f "$FM_HOME/done-failed-once" ]; then
  : > "$FM_HOME/done-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$origin" answered \
    --decision-file "$home/marker-resolve-decision.txt" \
    --routed-to sample-marker-resolve-work \
    > "$home/marker-resolve.out" 2> "$home/marker-resolve.err"; then
    fail "marker resolution succeeded after a forced done failure"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" \
    "marker resolution closed the hold before done succeeded"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" \
    "marker resolution did not store the captain decision before done failed"
  assert_contains "$show" "Withdrawn by fm-decision-hold." \
    "marker resolution lost the quoted withdrawal phrase inside the decision"
  run_decisions "$home" resolve "$origin" answered \
    --decision-file "$home/marker-resolve-decision.txt" \
    --routed-to sample-marker-resolve-work >/dev/null \
    || fail "exact marker-resolve retry refused a genuine resolution whose decision quotes the withdrawal marker"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "exact marker-resolve retry left the hold open"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" \
    "exact marker-resolve retry lost the resolution record"
  assert_contains "$show" "ignore any note saying Withdrawn by fm-decision-hold." \
    "exact marker-resolve retry lost the free-text decision"
  run_decisions "$home" complete "$origin" answered >/dev/null \
    || fail "completion rejected a resolved hold whose decision quotes the withdrawal marker"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "verification rejected a resolved hold whose decision quotes the withdrawal marker"

  # Ordinary cross-path refusals still hold so prefix classification is not a hole.
  home=$(make_home marker-cross-path-refusals)
  origin=sample-marker-cross-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Marker cross review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create marker-cross origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Marker cross review\n\nTwo ordinary partial closes.\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" answered \
    --title "Choose the answered option" --reason "captain answer pending" --repo sample) \
    || fail "could not register the marker-cross resolution hold"
  tasks_in "$home" add sample-marker-cross-work "Apply the answered choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create marker-cross dependent work"
  printf 'Take the answered option.\n' > "$home/marker-cross-decision.txt"
  printf 'Registered in error with ordinary text.\n' > "$home/marker-cross-reason.txt"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ ! -f "$FM_HOME/done-failed-once" ]; then
  : > "$FM_HOME/done-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$origin" answered \
    --decision-file "$home/marker-cross-decision.txt" \
    --routed-to sample-marker-cross-work \
    > "$home/marker-cross-resolve.out" 2> "$home/marker-cross-resolve.err"; then
    fail "marker-cross resolution succeeded after a forced done failure"
  fi
  if run_decisions "$home" withdraw "$origin" answered \
    --reason-file "$home/marker-cross-reason.txt" \
    > "$home/marker-cross-withdraw.out" 2> "$home/marker-cross-withdraw.err"; then
    fail "withdraw replaced an ordinary partially recorded captain decision"
  fi
  assert_grep "already records a captain decision" "$home/marker-cross-withdraw.err" \
    "withdrawing an ordinary partial resolution must still be refused"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "Take the answered option." \
    "ordinary cross-path withdraw damaged the captain decision"
  assert_not_contains "$show" "Withdrawn by fm-decision-hold" \
    "ordinary cross-path withdraw wrote a withdrawal over a partial resolution"
  run_decisions "$home" resolve "$origin" answered \
    --decision-file "$home/marker-cross-decision.txt" \
    --routed-to sample-marker-cross-work >/dev/null \
    || fail "ordinary partial-resolve retry did not close after the cross-path refusal"

  hold=$(run_decisions "$home" hold "$origin" mistaken \
    --title "Approve an already-taken choice" --reason "registered in error" --repo sample) \
    || fail "could not register the marker-cross withdrawal hold"
  tasks_in "$home" add sample-marker-cross-late "Late dependent work" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create marker-cross late work"
  rm -f "$home/done-failed-once"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ ! -f "$FM_HOME/done-failed-once" ]; then
  : > "$FM_HOME/done-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" withdraw "$origin" mistaken \
    --reason-file "$home/marker-cross-reason.txt" \
    > "$home/marker-cross-withdraw2.out" 2> "$home/marker-cross-withdraw2.err"; then
    fail "marker-cross withdrawal succeeded after a forced done failure"
  fi
  if run_decisions "$home" resolve "$origin" mistaken \
    --decision-file "$home/marker-cross-decision.txt" \
    --routed-to sample-marker-cross-late \
    > "$home/marker-cross-resolve2.out" 2> "$home/marker-cross-resolve2.err"; then
    fail "resolve replaced an ordinary partially recorded withdrawal"
  fi
  assert_grep "already records a withdrawal" "$home/marker-cross-resolve2.err" \
    "resolving an ordinary partial withdrawal must still be refused"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "Registered in error with ordinary text." \
    "ordinary cross-path resolve damaged the withdrawal reason"
  assert_not_contains "$show" "Resolution recorded by fm-decision-hold" \
    "ordinary cross-path resolve wrote a resolution over a partial withdrawal"
  run_decisions "$home" withdraw "$origin" mistaken \
    --reason-file "$home/marker-cross-reason.txt" >/dev/null \
    || fail "ordinary partial-withdraw retry did not close after the cross-path refusal"

  pass "queued close markers ignore free-text phrases and keep cross-path refusals"
}

# Once a closed hold ages out of Done into the archive, exact retry and identity
# rejection must still work. verify_hold_resolved/withdrawn already consult the
# archive; the retry body reload must too, or set -e exits silently on live-only
# task_show before the identity checks run.
test_archived_hold_retry_stays_idempotent_and_identity_safe() {
  local home origin hold show out err

  # Resolved hold ages out of Done, then exact and drifted retries.
  home=$(make_home archived-resolve-retry)
  origin=sample-archived-resolve
  mkdir -p "$home/data/$origin"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 1
EOF
  tasks_in "$home" add "$origin" "Archived resolve review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create archived-resolve origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Archived resolve review\n\nOne choice.\n' > "$home/data/$origin/report.md"

  hold=$(run_decisions "$home" hold "$origin" route \
    --title "Choose the archived route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register the archived-resolve hold"
  tasks_in "$home" add sample-archived-route "Apply the archived route" --kind ship --repo sample \
    --blocked-by "$hold" >/dev/null || fail "could not create archived-route work"
  printf 'Take the archived north route.\n' > "$home/archived-route-decision.txt"
  run_decisions "$home" resolve "$origin" route --decision-file "$home/archived-route-decision.txt" \
    --routed-to sample-archived-route > "$home/archived-resolve.out" 2> "$home/archived-resolve.err" \
    || fail "initial resolve failed before archival: $(cat "$home/archived-resolve.err")"

  # Push the closed hold out of Done under done_keep=1.
  tasks_in "$home" add sample-archive-pusher "Push the closed hold out of Done" \
    --kind ship --repo sample >/dev/null || fail "could not create archive pusher"
  tasks_in "$home" "done" sample-archive-pusher >/dev/null \
    || fail "could not complete archive pusher"
  if tasks_in "$home" show "$hold" --full >/dev/null 2>&1; then
    fail "fixture expected the resolved hold to leave live Done after retention pruning"
  fi
  grep -E "^- \[x\] $hold -" "$home/data/done-archive.md" >/dev/null \
    || fail "resolved hold was not archived; retention fixture is vacuous"

  out=$(run_decisions "$home" resolve "$origin" route \
    --decision-file "$home/archived-route-decision.txt" \
    --routed-to sample-archived-route 2> "$home/archived-retry.err") \
    || fail "exact resolve retry of an archived hold failed: $(cat "$home/archived-retry.err")"
  assert_contains "$out" "resolved: $hold" \
    "exact resolve retry of an archived hold must still print its resolved line"

  printf 'Take a different archived route.\n' > "$home/changed-archived-route-decision.txt"
  if run_decisions "$home" resolve "$origin" route \
    --decision-file "$home/changed-archived-route-decision.txt" \
    --routed-to sample-archived-route \
    > "$home/archived-drift.out" 2> "$home/archived-drift.err"; then
    fail "changed-decision retry of an archived hold succeeded silently"
  fi
  assert_grep "records a different captain decision" "$home/archived-drift.err" \
    "changed-decision retry of an archived hold must keep its explicit identity error"

  # Withdrawn hold ages out of Done, then exact and drifted retries.
  home=$(make_home archived-withdraw-retry)
  origin=sample-archived-withdraw
  mkdir -p "$home/data/$origin"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 1
EOF
  tasks_in "$home" add "$origin" "Archived withdraw review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create archived-withdraw origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Archived withdraw review\n\nOne mistaken choice.\n' > "$home/data/$origin/report.md"

  hold=$(run_decisions "$home" hold "$origin" mistaken \
    --title "Approve an already-taken choice" --reason "registered in error" --repo sample) \
    || fail "could not register the archived-withdraw hold"
  printf 'Registered in error and already executed.\n' > "$home/archived-withdraw-reason.txt"
  run_decisions "$home" withdraw "$origin" mistaken \
    --reason-file "$home/archived-withdraw-reason.txt" \
    > "$home/archived-withdraw.out" 2> "$home/archived-withdraw.err" \
    || fail "initial withdraw failed before archival: $(cat "$home/archived-withdraw.err")"

  tasks_in "$home" add sample-withdraw-pusher "Push the withdrawn hold out of Done" \
    --kind ship --repo sample >/dev/null || fail "could not create withdraw pusher"
  tasks_in "$home" "done" sample-withdraw-pusher >/dev/null \
    || fail "could not complete withdraw pusher"
  if tasks_in "$home" show "$hold" --full >/dev/null 2>&1; then
    fail "fixture expected the withdrawn hold to leave live Done after retention pruning"
  fi
  grep -E "^- \[x\] $hold -" "$home/data/done-archive.md" >/dev/null \
    || fail "withdrawn hold was not archived; retention fixture is vacuous"

  out=$(run_decisions "$home" withdraw "$origin" mistaken \
    --reason-file "$home/archived-withdraw-reason.txt" 2> "$home/archived-withdraw-retry.err") \
    || fail "exact withdraw retry of an archived hold failed: $(cat "$home/archived-withdraw-retry.err")"
  assert_contains "$out" "withdrawn: $hold" \
    "exact withdraw retry of an archived hold must still print its withdrawn line"

  printf 'A different archived withdrawal reason.\n' > "$home/changed-archived-withdraw-reason.txt"
  if run_decisions "$home" withdraw "$origin" mistaken \
    --reason-file "$home/changed-archived-withdraw-reason.txt" \
    > "$home/archived-withdraw-drift.out" 2> "$home/archived-withdraw-drift.err"; then
    fail "changed-reason retry of an archived hold succeeded silently"
  fi
  assert_grep "records a different withdrawal reason" "$home/archived-withdraw-drift.err" \
    "changed-reason retry of an archived hold must keep its explicit identity error"

  pass "archived hold retries stay idempotent and identity-safe after Done retention"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_resolve_closes_holds_whose_routed_work_completed
test_one_task_answers_two_decisions
test_batch_close_survives_done_retention_pruning
test_withdraw_closes_a_hold_registered_in_error
test_partial_close_identity_survives_done_failure
test_queued_close_markers_ignore_free_text_phrases
test_archived_hold_retry_stays_idempotent_and_identity_safe
