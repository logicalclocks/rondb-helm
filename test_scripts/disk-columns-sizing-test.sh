#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for disk-column (tablespace) storage sizing (RONDB-1154). Needs only
# helm and bash — no cluster.
#
# Part 1 — dedicated volume: with classes.diskColumns set, the volume is
#   sized diskColumnGiB + 3% + 2 GiB so the initial tablespace file fits
#   after filesystem overhead. The non-install render without a cluster
#   falls back to the same formula, unless diskColumnVolumeGiB states the
#   size of the existing claim: charts before 26.2.25 sized it differently.
# Part 2 — InitialTablespaceSizeGiB: unset, zero and negative default to
#   diskColumnGiB; values up to diskColumnGiB render; larger values fail.
# Part 3 — shared volume: without classes.diskColumns the tablespace lands
#   on the ndbmtd volume, so the install-time storage check counts
#   diskColumnGiB there (and only there), plus the same 3% + 2 GiB
#   filesystem margin the dedicated volume gets. The check runs on install
#   only; upgrades of existing clusters are never blocked by it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0; FAIL=0
assert() { # <description> <command>
  if eval "$2"; then PASS=$((PASS + 1)); echo "  ok: $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL: $1"; echo "    check: $2"; fi
}
count() { grep -c "$1" "$2" || true; }
# Requests of the rondb-ndbmtd-dc claim templates in a render, one per node
# group. A claim template reads "name: rondb-ndbmtd-dc", a volume mount
# "- name: rondb-ndbmtd-dc"; only a "storage:" one level under "requests:"
# counts, with nothing but comments in between.
dc_claim_sizes() {
  awk '
    /^ +name: rondb-ndbmtd-dc$/ { claim = 1; requests = 0; next }
    claim && /^ +requests: *$/ { match($0, /^ +/); requests = RLENGTH; next }
    claim && requests && /^ +#/ { next }
    claim && requests && /^ +storage: / {
      match($0, /^ +/)
      if (RLENGTH == requests + 2) print $2
      claim = 0
    }
    { requests = 0 }
  ' "$1" | paste -sd' ' -
}

# Render from a copy without venv/.git: helm loads every file in the chart
# directory, and a local venv makes each render take minutes.
CHART="$WORK_DIR/chart"
rsync -a --exclude venv --exclude .git --exclude .claude "$REPO_ROOT/" "$CHART/"

# The small.yaml preset sets diskColumnGiB: 4, so every size case sets
# diskColumnGiB explicitly.
render() { # <output-file> [helm --set flags...]
  local out=$1; shift
  helm template t "$CHART" --values "$CHART/values/minikube/small.yaml" \
    --set resources.requests.storage.classes.diskColumns=csi-rbd "$@" \
    > "$out" 2> "$out.err" || { echo "helm template failed:"; tail -5 "$out.err"; exit 1; }
}

# Succeeds only when the render fails AND the failure comes from the
# tablespace validation (not some unrelated render error)
render_fails() { # <expected-message-fragment> [helm --set flags...]
  local fragment=$1 err; shift
  if err=$(helm template t "$CHART" --values "$CHART/values/minikube/small.yaml" \
      "$@" 2>&1 > /dev/null); then
    return 1
  fi
  grep -q "$fragment" <<< "$err"
}

echo "Part 1 — dedicated disk-column volume sizing"

render "$WORK_DIR/install.yaml" --set mode=install \
  --set resources.requests.storage.diskColumnGiB=250
assert "install: 250 GiB tablespace gets a 259Gi volume (3% + 2 GiB overhead)" \
  "grep -q 'storage: 259Gi' '$WORK_DIR/install.yaml'"
assert "install: initial tablespace file stays at diskColumnGiB" \
  "grep -Eq 'ts_1_data_file_0\.dat:250G$' '$WORK_DIR/install.yaml'"
assert "install: dc volume uses the diskColumns storage class" \
  "grep -q 'storageClassName: \"csi-rbd\"' '$WORK_DIR/install.yaml'"

render "$WORK_DIR/small.yaml" --set mode=install \
  --set resources.requests.storage.diskColumnGiB=2
assert "install: the 2 GiB default gets a 4Gi volume" \
  "grep -q 'storage: 4Gi' '$WORK_DIR/small.yaml'"

render "$WORK_DIR/tiny.yaml" --set mode=install \
  --set resources.requests.storage.diskColumnGiB=1
assert "install: 1 GiB gets a 3Gi volume (truncating 3% division)" \
  "grep -q 'storage: 3Gi' '$WORK_DIR/tiny.yaml'"

render "$WORK_DIR/groups.yaml" --set mode=install \
  --set resources.requests.storage.diskColumnGiB=250 \
  --set clusterSize.numNodeGroups=2 \
  --set clusterSize.minNumRdrs=0 --set clusterSize.maxNumRdrs=0
assert "install: every node group gets the sized dc claim" \
  "[ \$(count 'storage: 259Gi' '$WORK_DIR/groups.yaml') -eq 2 ]"
assert "install: every node group mounts the dc volume (claim + mount per group)" \
  "[ \$(count 'name: rondb-ndbmtd-dc' '$WORK_DIR/groups.yaml') -eq 4 ]"

# mode=upgrade is the ArgoCD convention: no lookup, deterministic render.
# Plain default-mode templates take the install path and --is-upgrade aborts
# in topology-immutability.yaml, so this is the offline non-install branch.
render "$WORK_DIR/upgrade.yaml" --set mode=upgrade \
  --set resources.requests.storage.diskColumnGiB=250
assert "upgrade without a cluster: falls back to the formula" \
  "grep -q 'storage: 259Gi' '$WORK_DIR/upgrade.yaml'"

# A cluster installed before 26.2.25 has a smaller volume here (26.2.24:
# 252Gi), which a render without a cluster cannot read, and Kubernetes rejects
# any other size. diskColumnVolumeGiB states the size of the existing claim.
render "$WORK_DIR/pinned-upgrade.yaml" --set mode=upgrade \
  --set resources.requests.storage.diskColumnGiB=250 \
  --set resources.requests.storage.diskColumnVolumeGiB=252
assert "upgrade without a cluster: diskColumnVolumeGiB is the dc claim size" \
  "[ \"\$(dc_claim_sizes '$WORK_DIR/pinned-upgrade.yaml')\" = 252Gi ]"
assert "upgrade without a cluster: diskColumnVolumeGiB leaves the tablespace file at diskColumnGiB" \
  "grep -Eq 'ts_1_data_file_0\.dat:250G$' '$WORK_DIR/pinned-upgrade.yaml'"

render "$WORK_DIR/pinned-groups.yaml" --set mode=upgrade \
  --set resources.requests.storage.diskColumnGiB=250 \
  --set resources.requests.storage.diskColumnVolumeGiB=252 \
  --set clusterSize.numNodeGroups=2 \
  --set clusterSize.minNumRdrs=0 --set clusterSize.maxNumRdrs=0
assert "upgrade without a cluster: diskColumnVolumeGiB is the dc claim size of every node group" \
  "[ \"\$(dc_claim_sizes '$WORK_DIR/pinned-groups.yaml')\" = '252Gi 252Gi' ]"

# Setting it must not restart the data nodes: apart from the claim size and
# the rollout target on the StatefulSet itself (four spaces deep; in a pod
# template it would restart the pods), the node groups render the same.
render "$WORK_DIR/ndbd-formula.yaml" --set mode=upgrade \
  --set resources.requests.storage.diskColumnGiB=250 \
  --show-only templates/ndbd.yaml
render "$WORK_DIR/ndbd-pinned.yaml" --set mode=upgrade \
  --set resources.requests.storage.diskColumnGiB=250 \
  --set resources.requests.storage.diskColumnVolumeGiB=252 \
  --show-only templates/ndbd.yaml
without_size_and_target() {
  grep -v -e '^    rondb\.hopsworks\.ai/rollout-target: ' -e '^            storage: 25[29]Gi$' "$1"
}
assert "upgrade without a cluster: diskColumnVolumeGiB changes the node group StatefulSets" \
  "! diff -q '$WORK_DIR/ndbd-formula.yaml' '$WORK_DIR/ndbd-pinned.yaml' > /dev/null"
assert "upgrade without a cluster: only in the claim size and the rollout target (no data node restart)" \
  "grep -q configIniHash '$WORK_DIR/ndbd-pinned.yaml' && diff <(without_size_and_target '$WORK_DIR/ndbd-formula.yaml') <(without_size_and_target '$WORK_DIR/ndbd-pinned.yaml') > /dev/null"

# An existing claim has whatever size it was installed with, so a render that
# is not an install takes any size.
render "$WORK_DIR/pinned-small-upgrade.yaml" --set mode=upgrade \
  --set resources.requests.storage.diskColumnGiB=250 \
  --set resources.requests.storage.diskColumnVolumeGiB=249
assert "upgrade without a cluster: a size below diskColumnGiB is taken as the existing claim" \
  "[ \"\$(dc_claim_sizes '$WORK_DIR/pinned-small-upgrade.yaml')\" = 249Gi ]"

# An install creates the volume, so there the value can only enlarge it: a
# size copied from an older cluster (252) would not hold the 250 GiB file.
# --set-json passes the number as a values file does (a float), --set as an integer.
render "$WORK_DIR/pinned-install.yaml" --set mode=install \
  --set resources.requests.storage.diskColumnGiB=250 \
  --set-json resources.requests.storage.diskColumnVolumeGiB=300
assert "install: a diskColumnVolumeGiB above the formula is the dc claim size" \
  "[ \"\$(dc_claim_sizes '$WORK_DIR/pinned-install.yaml')\" = 300Gi ]"

render "$WORK_DIR/pinned-equal.yaml" --set mode=install \
  --set resources.requests.storage.diskColumnGiB=250 \
  --set resources.requests.storage.diskColumnVolumeGiB=259
assert "install: a diskColumnVolumeGiB equal to the formula renders" \
  "[ \"\$(dc_claim_sizes '$WORK_DIR/pinned-equal.yaml')\" = 259Gi ]"

assert "install: a diskColumnVolumeGiB below the formula fails the render" \
  "render_fails 'diskColumnVolumeGiB (252) is smaller than the 259 GiB a new disk column volume needs' \
    --set mode=install \
    --set resources.requests.storage.classes.diskColumns=csi-rbd \
    --set resources.requests.storage.diskColumnGiB=250 \
    --set resources.requests.storage.diskColumnVolumeGiB=252"

echo "Part 2 — InitialTablespaceSizeGiB validation"

render "$WORK_DIR/explicit.yaml" --set mode=install \
  --set resources.requests.storage.diskColumnGiB=250 \
  --set rondbConfig.InitialTablespaceSizeGiB=100
assert "explicit value below diskColumnGiB renders that size" \
  "grep -Eq 'ts_1_data_file_0\.dat:100G$' '$WORK_DIR/explicit.yaml'"

render "$WORK_DIR/equal.yaml" --set mode=install \
  --set resources.requests.storage.diskColumnGiB=250 \
  --set rondbConfig.InitialTablespaceSizeGiB=250
assert "explicit value equal to diskColumnGiB renders" \
  "grep -Eq 'ts_1_data_file_0\.dat:250G$' '$WORK_DIR/equal.yaml'"

render "$WORK_DIR/zero.yaml" --set mode=install \
  --set resources.requests.storage.diskColumnGiB=250 \
  --set rondbConfig.InitialTablespaceSizeGiB=0
assert "zero defaults to diskColumnGiB" \
  "grep -Eq 'ts_1_data_file_0\.dat:250G$' '$WORK_DIR/zero.yaml'"

render "$WORK_DIR/negative.yaml" --set mode=install \
  --set resources.requests.storage.diskColumnGiB=250 \
  --set rondbConfig.InitialTablespaceSizeGiB=-1
assert "negative defaults to diskColumnGiB" \
  "grep -Eq 'ts_1_data_file_0\.dat:250G$' '$WORK_DIR/negative.yaml'"

assert "explicit value above diskColumnGiB fails the render" \
  "render_fails 'InitialTablespaceSizeGiB cannot be greater' \
    --set mode=install \
    --set resources.requests.storage.classes.diskColumns=csi-rbd \
    --set resources.requests.storage.diskColumnGiB=250 \
    --set rondbConfig.InitialTablespaceSizeGiB=300"

echo "Part 3 — shared-volume storage check"

# With the small preset the non-disk-column components need 21 GiB
# (the check's own failure message reports the total).
assert "install: shared volume too small for the tablespace fails the render" \
  "render_fails 'is not enough for the ndbmtds' \
    --set mode=install \
    --set resources.requests.storage.diskColumnGiB=100"

render "$WORK_DIR/dedicated.yaml" --set mode=install \
  --set resources.requests.storage.diskColumnGiB=100
assert "install: the same values render once the tablespace has its own volume" \
  "grep -q 'name: rondb-ndbmtd-dc' '$WORK_DIR/dedicated.yaml'"

# small.yaml's 3300 MiB of memory is 3 GiB, so the LCP budget is
# ceil(3 x 2.25) = 7 GiB (6 before the mulf fix); with redo 4, undo 2x4,
# log 2 and the 100 GiB tablespace the components need 121 GiB. The exact
# numbers in the message pin both review fixes: the ceil'd LCP budget and
# the filesystem margin (3% of 121 truncates to 3, plus 2).
assert "install: a volume matching the components but not the margin fails" \
  "render_fails 'Required: 121GiB plus 5GiB filesystem overhead' \
    --set mode=install \
    --set resources.requests.storage.diskColumnGiB=100 \
    --set resources.requests.storage.ndbmtdGiB=121"

helm template t "$CHART" --values "$CHART/values/minikube/small.yaml" \
  --set mode=install \
  --set resources.requests.storage.diskColumnGiB=100 \
  --set resources.requests.storage.ndbmtdGiB=126 \
  > "$WORK_DIR/exactfit.yaml" 2> "$WORK_DIR/exactfit.yaml.err" \
  || { echo "helm template failed:"; tail -5 "$WORK_DIR/exactfit.yaml.err"; exit 1; }
assert "install: a shared volume covering components plus the margin renders" \
  "grep -q 'storage: 126Gi' '$WORK_DIR/exactfit.yaml'"

helm template t "$CHART" --values "$CHART/values/minikube/small.yaml" \
  --set mode=upgrade \
  --set resources.requests.storage.diskColumnGiB=100 \
  > "$WORK_DIR/sharedupgrade.yaml" 2> "$WORK_DIR/sharedupgrade.yaml.err" \
  || { echo "helm template failed:"; tail -5 "$WORK_DIR/sharedupgrade.yaml.err"; exit 1; }
assert "upgrade: the check never blocks an existing undersized cluster" \
  "grep -q 'kind: StatefulSet' '$WORK_DIR/sharedupgrade.yaml'"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
