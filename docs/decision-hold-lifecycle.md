# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an identity already closed by a resolution or a withdrawal.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

A hold has two closing subcommands, and both demand a durable record before anything closes.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
Dependent work that has already reached Done still resolves, because tasks-axi preserves a completed task's `blocked-by` edge, so the routing evidence the close depends on survives the dependent work finishing before the decision is filed.
Done retention then moves the oldest Done rows from the live backlog into the archive `.tasks.toml` names rather than deleting them, so the live backlog and that archive are two halves of one backlog.
Every read that may legitimately land on a Done row therefore consults both halves: the script reconstitutes them into one throwaway backlog that tasks-axi alone parses, instead of introducing a second row parser or reading the archive standalone (which would drop a `blocked-by` edge whose target is absent from that file while the hold it points at is still live).
That lookup is order-independent and time-independent, so a batch of closes does not depend on Done recency, on how much unrelated Done churn ran before or during it, or on raising `done_keep`.
Open holds and other live rows stay on the live path, because retention never moves a queued row.
The durable `blocked-by` edge is still required either way; when the routed task is still live, resolve then clears that edge through tasks-axi before marking the hold Done, and when the routed task is already only in the archive, no live edge remains to clear.
It records the decision digest and routed task identities as a retry identity in the hold body and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

The `withdraw` subcommand closes a hold registered in error, accepts no routed work, and requires a reason file rather than a decision file.
It records the reason and its digest under a `Withdrawn by fm-decision-hold.` marker that no resolution record carries, so a later reader can tell a withdrawn hold from an answered one, and marks the hold Done only after that write succeeds.
Close-record detection matches those canonical body prefixes only, so free-text phrases that merely mention resolution or withdrawal do not count as a durable close record.
When a prior close wrote its record and then failed before Done, an exact retry re-verifies that identity on the same path, including after the closed hold itself has been retention-pruned into the archive, while the opposite path refuses so a partial resolution cannot become a withdrawal and a partial withdrawal cannot become a resolution.
`complete` and `verify` accept a withdrawn hold as durably closed, `hold` refuses to reopen an identity already closed by resolution or withdrawal even after that row leaves the live backlog, `resolve` refuses a withdrawn hold, and `withdraw` refuses one that already records a captain decision.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
It also splits a hand-edited comma-joined token so readiness names the intended ids instead of treating `a,b` as one blocker no task can satisfy; `docs/configuration.md` owns the repeated-token write contract that tasks-axi itself requires.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Completed-routed-work resolution and withdrawal verification date: 2026-08-31.
Archive-aware batch close, two-edge routing, and comma-joined blocker readiness verification date: 2026-09-02.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
Two further regressions cover the closing paths: a hold whose routed work reached Done before the decision was filed, and a hold withdrawn as registered in error.
Each was run against the pre-change script first and failed there, the first with `fm-decision-hold: routed task sample-done-route is already done` and the second because no `withdraw` command existed, so neither passes vacuously.
Both also pin the refusals that carry the safety property, including an absent routed task, completed work that was never blocked by the hold, a withdrawal with no written reason, `--routed-to` on a withdrawal, resolving a withdrawn hold, and withdrawing an answered one.
Two review regressions pin the partial-close identity gate on both paths and the canonical-prefix close-marker classification that keeps free-text phrases from counting as a close record.
Archive-aware regressions pin a batch of at least three closes against retention-pruned routed work with no manual recovery, exact resolve and withdraw retries after the closed hold itself has been archived, `hold` refusing to reopen that archived closed identity, and one task carrying two repeated `blocked-by` edges so each decision closes independently.
The batch and comma-joined fleet-snapshot cases were each run against the pre-change scripts first and failed there, the first with `routed task sample-routed-one does not exist in the active home` and the second with `a comma-joined blocker list did not parse as two ids`, so neither passes vacuously.
The two-edge routing case is an acceptance guard for the repeated-token form rather than a pre-fix failure.

The final verification commands and their exact summarized outputs follow.
`bin/fm-test-run.sh` owns complete-inventory enforcement in CI, so the whole suite is not recopied here.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - resolve closes a hold whose routed work already completed and keeps its routing refusals
ok - one task carries two decision edges and each closes independently
ok - a batch of closes survives Done retention pruning without manual recovery
ok - withdraw closes a hold registered in error and stays distinct from a captain decision
ok - partial close identity is stable across a done failure on both paths
ok - queued close markers ignore free-text phrases and keep cross-path refusals
ok - archived hold retries stay idempotent and identity-safe after Done retention
ok - archived closed holds refuse re-hold after Done retention

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - comma-joined blocker lists parse as separate ids and resolve independently
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh | grep -c '^ok - '
65

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=67 local_links=234

$ git diff --check
(no output)

$ bin/fm-test-run.sh --check-coverage
FM_TEST_COVERAGE ok total=136 parallel=24 serial=99 serial_shards=4 herdr=13
```
