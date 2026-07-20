# Ordering data node StatefulSet rollouts during upgrades

Status: implemented and shipped — commit `[RONDB-1089] 4e54bd8`, PR
[logicalclocks/rondb-helm#213](https://github.com/logicalclocks/rondb-helm/pull/213)
against `branch-26.02`. Gated behind `ndbmtdSequencedRollout.enabled`
(default off).

Implementation:

- `templates/ndbd.yaml` — the partition freeze on the node-group
  StatefulSets
- `templates/ndbmtd_sequenced_rollout.yaml` — the rollout CronJob (+ its
  ServiceAccount/Role/RoleBinding)
- `templates/shared_templates/_helpers.tpl` —
  `rondb.ndbmtdSequencedRollout.isActive` (single gate for freeze and
  CronJob together: flag on, more than one node group, not externally
  managed, not an in-place restore) and
  `rondb.ndbmtdSequencedRollout.perGroupStallTimeoutMinutes` (derived
  stall threshold)
- `values.schema.json` → `ndbmtdSequencedRollout` (source of truth;
  `values.yaml` regenerated via `json_to_yaml.py`)
- `test_scripts/sequenced-rollout-test.sh` — rendering gates + the CronJob
  script executed against a fake kubectl (46 assertions); wired into the
  CI lint job, no cluster needed

The chart code and schema are self-documenting and carry no references to
this document. Shipped comments and messages use plain wording ("rollout",
"run") — this document keeps some design-analysis terms ("walker",
"level-triggered") when comparing alternatives.

Revision history:

- **Rev 5 (current)** — simplified the reconciler, trimming observability
  that the revision-age metric alert already covers: removed the
  `SequencedRolloutBlocked` event and its two dedup annotations (a rollout
  held by an unhealthy frozen group is now logged, not evented — the safety
  gate that prevents degrading two groups at once is unchanged), the
  `SequencedRolloutComplete` event (completion is `updateRevision ==
  currentRevision` on every group), and the `observedGeneration` stale
  guard (its strong justification left with the canary in Rev 4; for the
  level-triggered loop a stale read only causes one self-correcting
  re-freeze/unfreeze cycle). Down to two annotations and a linear post-scan
  decision. Core algorithm and the `SequencedRolloutStalled` event unchanged.

- Rev 4 — dropped the optional canary gate (`canaryGroups`
  value + `ndbmtd_sequenced_rollout_canary.yaml`). It reintroduced the very
  awaited-post-upgrade-hook paradigm Rev 3 rejected, doubled the bash
  surface (the canary's own script with its `observedGeneration`-race,
  `podFailurePolicy`, and `activeDeadlineSeconds` edge cases), and its
  fail-fast-on-bad-image value was already covered by the revision-age
  metric alert or an operator/CI running `kubectl rollout status
  node-group-0` after the upgrade. It was purely additive and off by
  default, so it can be re-added verbatim if in-band fail-fast is ever
  actually requested. The core freeze + reconciler is unchanged.

- Rev 3 — the walker moved from awaited post-upgrade hooks to a
  level-triggered CronJob reconciler. Trigger: scale analysis. Node-group
  recovery is data-dependent and can take hours; at 10+ node groups the walk
  is tens of hours, and no synchronous `helm upgrade` can span that (beyond
  `--timeout`, a helm process *killed* mid-hook — dropped SSH, CI runner
  limit — leaves the release stuck in `pending-upgrade`, requiring manual
  surgery; over a multi-hour window interruption is near-certain). The
  freeze mechanism is unchanged from Rev 2; only where the walker runs
  changed.
- Rev 2 — recommendation changed from a pre-upgrade apply-hook to
  partition-gated rollout (freeze + walk). The pre-upgrade hook made a hook
  Job a second writer of the node-group manifests; see Alternatives §1.
- Rev 1 — pre-upgrade hook Job applying node groups sequentially.

## Problem

The chart renders one StatefulSet per node group (`node-group-0..N-1`, see
`templates/ndbd.yaml`). On `helm upgrade`, Helm stamps all of them at once and
each StatefulSet rolls independently. There is no Kubernetes primitive that
orders rollouts *across* objects, so up to one data node from **every** node
group restarts concurrently.

What already works correctly today:

- **Within a node group**: the StatefulSet controller rolls one pod at a time
  (ordinal-descending), and the startup/readiness probes gate on the NDB node
  actually reaching *started* state via `ndb_mgm` (`healthcheck.sh`). A node
  group can therefore never lose both replicas to a rolling update. (The
  `podManagementPolicy: Parallel` setting affects only scaling, not updates.)
- **Tier ordering (MGMd first)**: `templates/mgmd_pre_upgrade.yaml` is a
  pre-upgrade hook Job that applies the rendered MGMd manifests and waits for
  convergence before the main Helm apply, so MGMd rolls before everything
  else. (Its rollout is minutes and its scope is one small StatefulSet — the
  scale argument below does not apply to it. It stays as-is.)

What is missing — and what sequencing node groups would buy:

- **Blast-radius containment**: today a bad image takes down one node in every
  group simultaneously (the whole cluster at single-replica exposure at once).
  Sequenced, a bad image stops at the first group and the other groups never
  start rolling.
- **Bounded recovery load**: N simultaneous node restarts means N simultaneous
  recoveries syncing from their group peers.
- Note: the current concurrent behavior is *data-safe* in NDB terms (one node
  per group at a time is a documented rolling-restart pattern). Sequencing is
  about exposure windows and fail-fast containment, not a correctness bug.

## Hard requirements

1. **Feature flag.** The entire feature is gated behind a single value
   (default **off**). Flag off ⇒ the rendered manifests and upgrade behavior
   are byte-identical to today.
2. **Single writer.** Helm's main apply remains the only thing that writes
   the node-group StatefulSet manifests. Orchestration may only touch the
   one field that controls *when the controller acts*
   (`updateStrategy.rollingUpdate.partition`) — never the spec itself.
3. **Fail-safe.** Any orchestration failure must leave every group either
   fully converged or untouched-and-running on the old revision. "Nothing
   happened" must be the failure mode, not "half happened".
4. **No effect** on fresh install, in-place restore
   (`restoreFromBackup.inPlace`), externally-managed clusters, or
   single-node-group clusters (with one group there is nothing to sequence
   across — and `numNodeGroups` is immutable after install, so the
   condition is stable for the cluster's life).
5. **Scale.** A node-group roll can take hours (recovery is data-dependent)
   and clusters can have 10+ groups: the full walk is potentially **tens of
   hours**. No design may require a single synchronous process (a `helm`
   command, a hook watch, one long-lived Job pod) to span the whole walk.

## The design space

Every possible solution pulls one of three levers:

1. **When the new spec reaches each StatefulSet** — pre-upgrade hook,
   deployment-tool ordering (Argo waves, Flux `dependsOn`, CI pipelines).
   Rejected: it requires a second applier of the manifests (Alternatives §1).
2. **When the controller may act on a spec it already has** —
   `updateStrategy.rollingUpdate.partition`, `updateStrategy: OnDelete`.
   **This is the chosen lever**: spec delivery stays on the normal Helm path.
3. **When individual pods may die or start** — admission webhooks,
   preStop/init-container gating. Rejected (Alternatives §6): can't order
   terminations, or operationally hostile.

Within lever 2 there is a second axis — *where the walker runs*: awaited
hooks (edge-triggered, blocks the release), a fire-and-forget Job
(edge-triggered, async), or a reconciler (level-triggered, async).
Requirement 5 eliminates awaited hooks; the plain Job is strictly worse than
both (see "Where the walker runs" below). Level-triggered wins.

## Recommended: partition-frozen StatefulSets + level-triggered reconciler

### Mechanism — freeze (unchanged from Rev 2)

When the flag is on, each node-group StatefulSet renders:

```yaml
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    partition: {{ .Values.clusterSize.activeDataReplicas }}
```

The StatefulSet controller only acts on ordinals `>= partition`, so
`partition == replicas` is a total freeze: `helm upgrade` applies **all**
node-group specs atomically through the normal path, and nothing restarts.
The pending update is visible as `updateRevision != currentRevision` on each
StatefulSet — plain, inspectable Kubernetes state, no custom bookkeeping.

- `helm upgrade --wait` does not hang on frozen StatefulSets: Helm's
  readiness checker requires `updatedReplicas >= replicas - partition`
  (trivially true) and only compares revisions when `partition == 0`. Argo
  CD's StatefulSet health check is partition-aware the same way. (Both are
  version-dependent implementation details — the shipped test covers
  rendering and CronJob behavior, not this; still worth pinning in the
  lifecycle workflow against the Helm version in use.)
- Fresh install is unaffected: on creation `currentRevision ==
  updateRevision`, so the partition is irrelevant until the first upgrade.
- Fail-safe falls out for free: if the rollout CronJob never runs, the
  cluster keeps running the old revision indefinitely with the update
  parked. Nothing is half-applied, ever.

### Mechanism — the rollout CronJob (Rev 3 shape, simplified in Rev 5)

A **rollout CronJob** — a normal chart resource on the normal apply path,
rendered together with the partition field (never one without the other),
running every few minutes (`concurrencyPolicy: Forbid`;
`startingDeadlineSeconds: 300` so a long controller-manager outage can never
trip Kubernetes' 100-missed-start-times cutoff and permanently stop
scheduling; `successfulJobsHistoryLimit: 1`; every kubectl call bounded by
`--request-timeout` and the whole run by `activeDeadlineSeconds`). Each run
is idempotent, takes seconds, and holds almost no state of its own — the
partition value and `currentRevision`/`updateRevision` live on the
StatefulSets, plus two annotations the CronJob stamps to time a stalled
group (an unfroze-at timestamp and a stall-Event-dedup marker):

```
scan ALL groups (ascending), classifying each:
  pending = updateRevision != currentRevision
  frozen  = partition >= replicas
  healthy = readyReplicas == replicas

during the scan:
  unfrozen + converged (not pending, healthy):
      re-freeze (partition = replicas), clear annotations, emit Converged
  unfrozen + not yet converged:
      the rollout is busy — nothing else may unfreeze this run;
      adopt it (stamp unfroze-at) if the annotation is missing or invalid;
      past perGroupStallTimeoutMinutes emit Stalled once (dedup marker)

after the scan, if nothing is unfrozen:
  lowest pending frozen group, ALL groups healthy:
      unfreeze it (partition = 0), stamp unfroze-at, emit Unfroze
  lowest pending frozen group, some group unhealthy:
      hold (log only) so the rollout never degrades two groups at once
```

Properties:

- **At most one group unfrozen at any time** — the same exposure bound as
  the hook design, enforced per run against observed state rather than by
  process control flow.
- **Nothing long-running exists.** The rollout spans hours because the
  *StatefulSet controller* spends hours rolling pods between runs — no helm
  process, hook watch, or Job pod has to survive the duration. A killed
  run, drained node, or restarted control plane costs nothing; the next
  run re-reads reality and continues. Requirement 5 is met by
  construction.
- **Rollback needs no hooks at all.** `helm rollback` (or `--atomic`) simply
  creates new pending updates; the CronJob rolls them out the same way —
  including replacing a crash-looping half-upgraded pod once its group is
  unfrozen (the pod no longer matches the update revision). Working from
  current state also covers what no hook ever could: out-of-band spec
  changes (a manual `kubectl apply`, an Argo sync outside a Helm operation).
- **Stall = containment, not rollback.** A group that won't converge (bad
  image) pauses the rollout — no further groups are unfrozen — and stays
  unfrozen with an Event raised. Deliberate: re-freezing wouldn't heal the
  crash-looping pod (the controller never reverts a live pod below the
  partition), and leaving the group unfrozen means the *fix* — the next
  `helm upgrade` — rolls into it immediately, after which the rollout
  resumes.
- **Held while any group is unhealthy.** A pending update is not started
  while some frozen group has unready pods, so the rollout never degrades
  two groups at once. This is a log-only hold (Rev 5); the revision-age
  metric is the "not progressing" signal.
- **Take-over-and-re-freeze semantics.** Any unfrozen group — including one
  an operator unfroze by hand — is taken over: the CronJob stamps its
  unfroze-at annotation, watches it converge, and re-freezes it. Manual
  unfreezes are therefore temporary by design; the way to keep a group
  unmanaged is disabling the flag, not hand-editing the partition.

### The trade-off: release success ≠ rollout success

Because the rollout is asynchronous, `helm upgrade` succeeding means "intent
recorded, rollout in progress" — a bad image does not fail the release, and
completion must be observed on the cluster instead. This is by design (see
Requirement 5: no synchronous process can span a tens-of-hours rollout), and
it is mitigated, not eliminated:

- **Metrics** catch both a stalled rollout and a stopped CronJob: alert on
  `kube_statefulset_status_update_revision !=
  kube_statefulset_status_current_revision` with an age threshold (see
  Observability). This is the recommended in-fleet signal.
- **Manual / CI check**: an operator or pipeline that wants an explicit
  first-group gate can run `kubectl rollout status statefulset/node-group-0`
  after `helm upgrade` returns — no chart machinery required. Whole-cluster
  completion is `updateRevision == currentRevision` on every node group.

(An earlier revision shipped an optional in-release canary hook for this;
it was removed in Rev 4 — see the revision history for why, and for how to
re-add it if in-band fail-fast is ever required.)

### Where the walker runs — why level-triggered beats both hook variants

**Awaited post-upgrade hooks** (Rev 2) are the right shape only when the
total walk fits inside a timeout an operator will actually hold open. They
give per-group `--timeout` windows and release-outcome fidelity — but at
10 groups × hours, the helm command must survive tens of hours. Timeout
leaves a FAILED release with later hooks never created (safe but parked);
process death leaves `pending-upgrade` (manual surgery); interruption
probability over such a window approaches 1. The fidelity they exist to
provide becomes unearnable exactly at the scale this chart targets.
Rejected. (An earlier revision kept their one benefit — in-release
fail-fast on the first group — as an optional canary hook; Rev 4 removed it
in favor of metrics/CI checks. See the revision history.)

**A plain fire-and-forget release Job** is strictly worse than both other
options and is rejected outright:

- All release resources are created at once — nothing orders per-group
  Jobs, so it degenerates to one monolithic looping Job: a single pod that
  must survive the entire multi-hour walk (violates Requirement 5, modulo
  Job-controller retries).
- Failures are silent: release **deployed**, Argo **synced**, `--atomic`
  never triggers, CD remediation sees success — while the walker died at
  group 0 and pods sit frozen-old with no diff pressure. Unreported
  containment defeats fail-fast.
- Rollback is nondeterministic: `helm rollback` replays the stored manifest
  naming the *old revision's* Job; whether the walk re-runs depends on
  whether `ttlSecondsAfterFinished` already garbage-collected it.
- Job immutability forces revision-suffixed names and TTL GC fiddliness.

The rollout CronJob keeps the plain Job's fast-returning release while
fixing everything else: runs are short-lived (nothing to keep alive),
failures pause the rollout in observable API state rather than silence, and
rollback/out-of-band changes are handled by construction rather than by
hook annotations.

### Steady-state cost — why the CronJob runs forever

After a rollout completes, the CronJob keeps running on its schedule. That
is deliberate, and the waste is smaller than it looks: an idle run is one
short-lived pod doing `numNodeGroups` kubectl reads and exiting in seconds
— at the 3-minute default roughly 1–2 CPU-minutes per day, with
`successfulJobsHistoryLimit: 1` keeping clutter at a single completed Job.
The real cost is API/etcd churn and log noise, not compute. It is the same
bargain every Kubernetes controller makes: control loops run
unconditionally so they never miss work.

Could it slow down or stop when idle? Two designs were analyzed. The
load-bearing fact for both (verified against Helm v3.20 source,
`pkg/kube/client.go` `createPatch`): Helm's upgrade patch is a **true
three-way strategic merge** — old manifest, new manifest, *live object*,
with `overwrite=true` — and the delta half is computed as
`diff(live → new manifest)` (apimachinery `CreateThreeWayMergePatch`: "the
patch is the difference from current to modified"). So any live drift on a
field that the chart renders — `.spec.suspend`, `.spec.schedule` — is
**reset to the rendered value by every `helm upgrade` or `helm rollback`,
even when the manifests didn't change**. (An earlier draft of this section
claimed the opposite — that an unchanged manifest produces an empty patch
and drift survives; that is Helm 2's two-way behavior, not Helm 3's.)

**Decision (follow-up to PR #213, not yet implemented): the CronJob will
suspend itself when idle** and rely on Helm to wake it.

- The last run that finds every group converged and frozen patches its own
  CronJob to `suspend: true`. Any `helm upgrade` or `helm rollback` resets
  it to the rendered `suspend: false` (per the verified patch semantics
  above), so a new rollout always wakes at full speed. Flux
  helm-controller performs real Helm upgrades, so it wakes the CronJob the
  same way. Idle cost drops to zero pods.
- **Gated off when `mode` is set** — the chart's existing Argo CD
  convention (the same signal `rondb.canUseLookupFunc` keys on). Argo's
  sync engine either fights the suspension (selfHeal re-applies
  `suspend: false` every cycle, saving nothing) or, with
  `ignoreDifferences` on `.spec.suspend`, never resets it — and a real
  update would then land frozen with the CronJob asleep. Argo deployments
  therefore keep the always-on cadence; the suspend logic only activates
  when `mode` is unset (Helm CLI, Flux).
- **Accepted trade-off**: a spec change applied outside Helm (a manual
  `kubectl apply` to a node-group StatefulSet) while suspended stays
  frozen until the next Helm operation or a manual wake —
  `kubectl patch cronjob rondb-ndbmtd-sequenced-rollout --type merge -p
  '{"spec":{"suspend":false}}'`. The revision-age metric alert
  (Observability) is the safety net for this case; the value description
  and runbook must state it loudly.
- Runner-up, kept as the fallback if the out-of-band gap bites in
  practice: a **two-speed schedule** (idle runs patch `.spec.schedule` to
  a slow cadence, any run that sees work patches it back; Argo-safe and
  self-recovering within one idle interval). The margin is small — at a
  daily idle cadence, two-speed is within one short pod-run per day of
  suspend — so the choice favors zero idle activity over automatic
  self-recovery. (Plain two-speed beats *exponential* backoff either way:
  idle cost is flat, so extra backoff states buy nothing.)

Until that lands, the available lever is `reconcileIntervalMinutes`
(e.g. 10–15): between rollouts the CronJob only needs to catch rollbacks
and out-of-band changes, where minutes of detection latency are
irrelevant, and during a rollout the interval only adds boundary latency
(~N groups × interval) against runs measured in hours.

### Failure & recovery playbook

- **Bad image**: the rollout pauses at the first affected group — that
  group at single-replica with a crash-looping pod, all later groups
  frozen-old, stall Event raised. Fix values → `helm upgrade` → new spec
  lands (frozen) everywhere, the stalled group (unfrozen) rolls to the fix
  immediately, the CronJob resumes the rollout. No zombie processes, no
  release-state surgery.
- **Roll back instead**: `helm rollback` — pending updates in the old
  direction; the CronJob rolls them out; the bad pod is replaced when its
  group is unfrozen. (NDB caveat, inherent to any downgrade: a node that
  partially ran the new binary may have written newer on-disk structures
  and can need a node `--initial` start to rejoin on the old version.)
- **CronJob broken/misbehaving**: the mechanism is one integer per
  StatefulSet. Manual escape: `kubectl patch sts node-group-$i -p
  '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'` per
  group, in order, by hand — or disable the flag (see Values: pending
  updates then roll concurrently, i.e. today's behavior).
- **Rollback to a pre-feature revision**: drops the partition field and the
  CronJob → partition defaults to 0 → concurrent roll, exactly today's
  behavior. Acceptable.

### Interactions that must be designed in

- **In-place restore** (`templates/backups/inplace_restore.yaml`): its
  weight `-5` pre-upgrade Job scales every node-group StatefulSet to 0.
  Pods created at ordinals `< partition` come up on **currentRevision** —
  the *old* template — so a frozen scale-up from zero would resurrect old
  pods without `FORCE_INITIAL_START`/`INPLACE_BACKUP_ID` and break the
  restore. Hence: when `rondb.restoreFromBackup.isInPlace`, one shared gate
  (`rondb.ndbmtdSequencedRollout.isActive`) suppresses the partition and the
  rollout CronJob together for that release.
- **Frozen-recreation semantics**: any pod recreated while its group is
  frozen — eviction, node failure, replica scale-up — comes back on
  `currentRevision`. Mid-upgrade that is the currently-running version,
  which is exactly right; a replica scale-up concurrent with a pending
  update briefly starts an old-template pod that converges when its group
  is unfrozen.
- **Argo CD selfHeal will fight the rollout.** An unfrozen group is drift
  against the rendered `partition: replicas`; with `selfHeal: true` Argo
  re-freezes it mid-roll. Ship documented `ignoreDifferences` for
  `.spec.updateStrategy.rollingUpdate.partition` on `node-group-*`
  StatefulSets (standard practice for partition-based rollouts). Flux
  helm-controller: drift detection is off by default; if enabled, the same
  field exclusion is needed. Note the CronJob tolerates the fight
  gracefully (a re-frozen group is just re-unfrozen next run), but the
  tug-of-war wastes a roll step — configure the exclusion.
- **Consecutive upgrades mid-rollout**: the newest spec lands (frozen) on
  all frozen groups; the one currently-unfrozen group rolls straight to the
  newest revision (exposure bounded to that group); the rollout continues
  against the new target. Working from current state makes "upgrade during
  an upgrade" a non-event rather than a special case.
- **Topology immutability**: `numNodeGroups` changes are already rejected at
  weight `-30/-20` (`templates/topology-immutability.yaml`), so the
  CronJob may assume the group count; missing StatefulSets (Argo first
  sync, destructive `forceNodeGroupChange=true` path) are simply skipped.
- **Tier ordering**: MGMd still rolls first (existing weight-10 pre-upgrade
  hook, unchanged — minutes-long, arbitration-critical). The API tier
  (MySQLds, RDRS) rolls during the main apply, before the data-node rollout
  — strictly fewer moving parts than today's everything-at-once, and NDB
  supports mixed adjacent versions; if canonical `mgmd → ndbmtd → api`
  order is ever required, the same freeze+rollout extends to the API-tier
  StatefulSets. Out of scope for v1.

### Values

Schema-first (`values.schema.json` → `json_to_yaml.py`):

- `ndbmtdSequencedRollout.enabled` — default `false`. Gates the partition
  field and the rollout CronJob together (via
  `rondb.ndbmtdSequencedRollout.isActive`). Takes effect
  only with more than one node group — with a single group there is nothing
  to sequence across (the StatefulSet controller already rolls it one pod
  at a time), so the chart behaves exactly as if the flag were off; since
  `numNodeGroups` is immutable after install, the condition is stable.
  **Disable semantics**: removing the field resets partition to 0 — any
  *pending* frozen update then rolls all groups concurrently (today's
  behavior). Document: disable during a quiet period or after confirming no
  update is pending.
- `ndbmtdSequencedRollout.reconcileIntervalMinutes` — CronJob run
  interval, default 3 (schema bounds 1–30). Adds at most one interval of
  latency per group boundary (~N × interval over a full rollout — noise
  against hours-long rolls). A no-op run is a seconds-long pod; history
  limits stay tight. **Why the 30 cap**: the schedule renders as
  `*/N * * * *`, and cron's `*/N` on the minutes field resets at every
  hour boundary — it fires at minutes 0, N, 2N… *within each hour*. Any
  N > 30 silently lies about the interval (`*/45` fires at :00 and :45 —
  alternating 45- and 15-minute gaps); intervals above 30 minutes are not
  expressible in this pattern at all. 30 is the largest value the
  mechanism can honor evenly. (Below 30, only divisors of 60 are perfectly
  even; non-divisors like 7 have one shorter gap per hour — harmless.)
- `ndbmtdSequencedRollout.perGroupStallTimeoutMinutes` — stall-detection
  threshold; `0` (the default) derives it rather than inventing a number:
  `activeDataReplicas × timeoutsMinutes.ndbmtdStartupProbe` minutes plus
  30 minutes of slack (the startup probe already defines how long one node
  may take; a group is `replicas` of those, serially). This is an alerting
  threshold, not a process timeout — nothing is killed when it fires.

### Observability

The rollout's entire state is first-class API state, no custom store:

- Progress: `partition` + `currentRevision`/`updateRevision` per
  StatefulSet (document a `kubectl get sts -o custom-columns=...`
  one-liner). Pending-parked, mid-roll, stalled, and complete are all
  distinguishable from those fields.
- Events (`SequencedRolloutUnfroze`, `SequencedRolloutConverged`,
  `SequencedRolloutStalled`): the CronJob emits an Event when it unfreezes
  a group and when a group converges, plus a Warning (deduped via an
  annotation marker) on a group that won't converge within the stall
  timeout. A rollout held because another group is unhealthy is logged,
  not evented — the revision-age alert below is the signal for "not
  progressing".
- Alerting: pair `kube_statefulset_status_update_revision !=
  kube_statefulset_status_current_revision` with an age threshold
  (kube-state-metrics) — catches both stalls and a stopped CronJob, closing
  the silent-failure gap that async operation opens.

## Alternatives considered

### 1. Pre-upgrade hook Job applying node groups sequentially (Rev 1 — rejected)

Extend the `mgmd_pre_upgrade.yaml` pattern: render per-group manifests into a
hook ConfigMap; a weight-20 pre-upgrade Job loops `kubectl apply` →
`rollout status` per group, so the main apply later sees no diff. Attractive
on paper (canonical `mgmd → ndbmtd → api` order, idempotent resume), but it
structurally adds a **second writer of the same objects to the upgrade
path**:

- **Dual-writer divergence.** The hook's client-side `kubectl apply` and
  Helm's stored-manifest three-way patch must produce byte-identical pod
  templates forever. On the adoption upgrade the live objects have no
  `last-applied` annotation, so an upgrade that *removes* a pod-template
  field rolls every group once via the hook and then a second time,
  **concurrently**, when the main apply prunes the field — defeating the
  feature exactly when it's needed.
- **Cluster state runs ahead of the release record**; a failure at group
  *i* leaves live state matching neither revision, recorded nowhere.
- **Hook coupling**: breaks in-place restore outright (the weight `-5`
  shutdown Job scales groups to zero; the weight-20 apply would resurrect
  them mid-restore).
- **No rollback story**: pre-upgrade hooks don't fire on `helm rollback`,
  so rollback reverts everything concurrently — including MGMd ordering
  (the Error 2305 arbitration hazard) — precisely during bad-image
  recovery.
- **Blocks the release for the whole walk** — fails Requirement 5 outright,
  independent of everything above.

### 2. Awaited post-upgrade hook walker (Rev 2 — rejected)

Per-group post-upgrade + post-rollback hook Jobs (unfreeze → `rollout
status` → re-freeze), serialized by hook weight. Keeps Helm as the single
manifest writer and makes release outcome equal rollout outcome — the right
design **when the total walk fits inside a `--timeout` an operator will
hold open**. It fails Requirement 5: at hours per group × 10+ groups the
helm process must survive tens of hours; timeout parks the walk with later
hooks never created, process death leaves `pending-upgrade`, and
interruption over such a window is near-certain. Its unique benefit —
in-release fail-fast on a bad image — was carried for one revision as an
optional canary hook bounded to the first group(s), then removed in Rev 4
(the same benefit comes from the revision-age metric alert or a CI
`kubectl rollout status node-group-0` check, without a second mechanism).

### 3. Always-on sequencer Deployment

Same level-triggered logic as the recommended CronJob, as a persistent
controller: instant reactions (no tick latency), watch-based. Costs an
always-running component to version, secure, and debug — for a walk that
happens a few times a year, tick latency of minutes is irrelevant against
hours-long rolls. The CronJob is the same logic at near-zero steady-state
cost; promote to a Deployment (or a real operator, §8) only if reaction
latency or richer orchestration ever matters.

### 4. `updateStrategy: OnDelete` + orchestrator Job deleting pods in order

Maximal control, but it reimplements the StatefulSet update controller in
bash: comparing `controller-revision-hash` to `updateRevision`, handling
pods created mid-orchestration, mixed-revision states if the Job dies, and
`kubectl rollout status` stops being meaningful. Partition-gating strictly
dominates it. **Rejected.**

### 5. Collapse all node groups into one StatefulSet

One StatefulSet with `numNodeGroups × replicas` pods and ordinal →
node-group mapping computed at startup. Kubernetes would then provide a
total order natively — but a StatefulSet has a *uniform* pod template, so
per-group labels are lost, and with them the per-group required
anti-affinity ("replicas of the same node group on different hosts"),
per-group storage sizing, and per-group headless Services.
**Architecturally blocked**, but explains why the chart has this problem at
all.

### 6. Deployment-tool ordering

- **Argo CD sync waves** per node-group StatefulSet: declarative and
  resumable, but Helm-CLI users get nothing — at best a complement. (An
  Argo sync holding waves open for tens of hours has its own operation-
  duration problems.)
- **Split into per-group releases** ordered externally (Flux `dependsOn`,
  CI running `helm upgrade --wait` per group): relocates the orchestrator
  into CI — same logic, worse cohesion, and the CI pipeline now must span
  the multi-hour walk.
- **Third-party workload CRDs** (OpenKruise `UnitedDeployment`): maps well,
  but a CRD/controller dependency in a general-purpose chart is a big ask.

### 7. Pod-level self-coordination — listed to close the space, not to use

- **Init-container lease gating**: orders *starts*, not *terminations* —
  controllers still kill one pod per group simultaneously; the dead pods
  then queue on the lock, holding *every* group at single-replica exposure
  for the full serialized duration. Strictly worse than today.
- **preStop gating**: capped by `terminationGracePeriodSeconds`, defeated
  by force-deletes and node failures.
- **Validating admission webhook** rejecting out-of-order pod deletions:
  the only pod-level mechanism that can order terminations, but it sits on
  the pod-deletion critical path (`failurePolicy: Fail` bricks the
  namespace when the webhook is down; `Ignore` voids the guarantee).
  Operationally hostile.

### 8. PodDisruptionBudgets

Worth adding per node group (`maxUnavailable: 1`) for node drains anyway,
but PDBs do **not** apply to StatefulSet rolling updates (the controller
deletes pods directly rather than through the eviction API), so they don't
solve this.

### 9. A real operator

The textbook long-term answer (cf. MySQL's ndb-operator): a reconcile loop
owning cluster-aware restarts, upgrade order across tiers, and failure
recovery. A product-scale investment. Note the recommended design *is* a
minimal reconcile loop — frozen manifests plus a level-triggered walker —
so it inherits an operator's key robustness properties and is the natural
seed of one.

## Decision summary

| Approach | Ordering | Fail-safe default | Survives tens-of-hours walks | Rollback | Main cost |
|---|---|---|---|---|---|
| Partition + CronJob reconciler (**recommended**) | Yes | Frozen — failure = nothing moves | Yes — no long-lived process exists | Level-triggered, automatic | Release ≠ rollout (mitigate: metrics / CI rollout-status check) |
| Partition + awaited post-upgrade hooks (Rev 2) | Yes | Frozen | **No** — helm must span the walk | Sequenced via `post-rollback` | Multi-hour blocking release; `pending-upgrade` on process death |
| Pre-upgrade apply hook (Rev 1) | Yes | No — applies immediately | No | Unsequenced, loses MGMd ordering | Dual-writer divergence; hook coupling |
| Plain release Job walker | Yes | Frozen | No — one pod spans the walk | Nondeterministic (TTL GC) | Silent failures |
| Always-on sequencer Deployment | Yes | Frozen | Yes | Level-triggered | Steady-state component |
| OnDelete + pod-deleting Job | Yes | No | No | Manual | Reimplements the controller |
| Single StatefulSet | Yes (native) | — | Yes | Native | Breaks per-group scheduling/storage |
| Argo sync waves | Yes | — | Poorly (long sync operations) | Argo-managed | Tool-coupled |
| Pod-level gating | Partial/none | — | — | — | Can't order terminations / hostile |

The freeze (partition rendering, flag, in-place gate, Argo
`ignoreDifferences`) is common to every partition-based row — it is the
stable foundation. The walker's runtime is the only variable, and
Requirement 5 (tens-of-hours walks) forces it to be level-triggered.
