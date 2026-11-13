#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for disk-column (tablespace) storage sizing (RONDB-1154). Needs only
# helm and bash — no cluster.
#
# Part 1 — dedicated volume: with classes.diskColumns set, the volume is
#   sized diskColumnGiB + 3% + 2 GiB so the initial tablespace file fits
#   after filesystem overhead. The non-install render without a cluster
#   falls back to the same formula.
# Part 2 — InitialTablespaceSizeGiB: unset, zero and negative default to
#   diskColumnGiB; values up to diskColumnGiB render; larger values fail.
# Part 3 — shared volume: without classes.diskColumns the tablespace lands
#   on the ndbmtd volume, so the install-time storage check counts
#   diskColumnGiB there (and only there). The check runs on install only;
#   upgrades of existing clusters are never blocked by it.

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

# With the small preset the non-disk-column components need 20 GiB
# (the check's own failure message reports the total).
assert "install: shared volume too small for the tablespace fails the render" \
  "render_fails 'is not enough for the ndbmtds' \
    --set mode=install \
    --set resources.requests.storage.diskColumnGiB=100"

render "$WORK_DIR/dedicated.yaml" --set mode=install \
  --set resources.requests.storage.diskColumnGiB=100
assert "install: the same values render once the tablespace has its own volume" \
  "grep -q 'name: rondb-ndbmtd-dc' '$WORK_DIR/dedicated.yaml'"

helm template t "$CHART" --values "$CHART/values/minikube/small.yaml" \
  --set mode=install \
  --set resources.requests.storage.diskColumnGiB=100 \
  --set resources.requests.storage.ndbmtdGiB=120 \
  > "$WORK_DIR/exactfit.yaml" 2> "$WORK_DIR/exactfit.yaml.err" \
  || { echo "helm template failed:"; tail -5 "$WORK_DIR/exactfit.yaml.err"; exit 1; }
assert "install: a shared volume exactly matching the requirement renders" \
  "grep -q 'storage: 120Gi' '$WORK_DIR/exactfit.yaml'"

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
