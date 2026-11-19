#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for the rondb.hopsworks.ai/rollout-target annotation
# (rondb.rolloutTarget). Needs only helm and bash — no cluster.
#
# A chart that depends on this one reads the target from the mysqld-configs
# ConfigMap and waits until each StatefulSet carries it before trusting
# `kubectl rollout status`. That only holds when every render that changes a
# pod template also changes the target.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0; FAIL=0
assert() { # <description> <command>
  if eval "$2"; then PASS=$((PASS + 1)); echo "  ok: $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL: $1"; echo "    check: $2"; fi
}

# Render from a copy without venv/.git: helm loads every file in the chart
# directory, and a local venv makes each render take minutes.
CHART="$WORK_DIR/chart"
rsync -a --exclude venv --exclude .git --exclude .claude --exclude .agents "$REPO_ROOT/" "$CHART/"

render() { # <output-file> [helm args...]
  local out="$1"; shift
  # forceNodeGroupChange skips the node group count check, which reads the
  # cluster on upgrade.
  helm template t "$CHART" \
    --values "$CHART/values/minikube/small.yaml" \
    --set clusterSize.numNodeGroups=2 \
    --set meta.ddlMySQLd.enabled=true \
    --set forceNodeGroupChange=true \
    "$@" > "$out" 2> "$out.err" \
    || { echo "helm template failed:"; tail -5 "$out.err"; exit 1; }
}

# targets <rendered-file>: the distinct rollout targets in the render.
targets() {
  grep 'rondb.hopsworks.ai/rollout-target:' "$1" | sed 's/.*rollout-target: *//' | sort -u
}

# stamped <rendered-file>: "<kind>/<name>" of every object carrying a target.
stamped() {
  awk '
    /^---/ {kind=""; name=""}
    /^kind:/ {kind=$2}
    /^  name:/ && name == "" {name=$2}
    /rondb.hopsworks.ai\/rollout-target:/ {print kind "/" name}
  ' "$1" | sort | tr '\n' ' '
}

render "$WORK_DIR/install.yaml"
render "$WORK_DIR/upgrade.yaml" --is-upgrade
render "$WORK_DIR/upgrade_again.yaml" --is-upgrade
render "$WORK_DIR/upgrade_changed.yaml" --is-upgrade --set resources.limits.cpus.mysqlds=4

echo "Rollout target"
assert "stamped on the ConfigMap and every guarded StatefulSet" \
  '[ "$(stamped "$WORK_DIR/upgrade.yaml")" = "ConfigMap/mysqld-configs StatefulSet/ddl-mysqld StatefulSet/mysqlds StatefulSet/node-group-0 StatefulSet/node-group-1 " ]'
assert "one target per render" \
  '[ "$(targets "$WORK_DIR/upgrade.yaml" | wc -l)" -eq 1 ]'
assert "not in a pod template, where it would restart RonDB on every change" \
  '! grep -q "^        rondb.hopsworks.ai/rollout-target:" "$WORK_DIR/upgrade.yaml"'
assert "two upgrades with the same values share a target" \
  '[ "$(targets "$WORK_DIR/upgrade.yaml")" = "$(targets "$WORK_DIR/upgrade_again.yaml")" ]'
assert "a values change gives a new target" \
  '[ "$(targets "$WORK_DIR/upgrade.yaml")" != "$(targets "$WORK_DIR/upgrade_changed.yaml")" ]'
# The MySQL servers carry wait-single-setup-job on install only, so the first
# upgrade restarts them with the chart version and values unchanged.
assert "install renders wait-single-setup-job, upgrade does not" \
  'grep -q "name: wait-single-setup-job" "$WORK_DIR/install.yaml" && ! grep -q "name: wait-single-setup-job" "$WORK_DIR/upgrade.yaml"'
assert "the first upgrade after an install gets a new target" \
  '[ "$(targets "$WORK_DIR/install.yaml")" != "$(targets "$WORK_DIR/upgrade.yaml")" ]'

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
