#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for the pinned nodePort of the external MySQL and RDRS Services
# (meta.{mysqld,rdrs}.externalLoadBalancer.nodePort).
# Needs only helm and bash, no cluster.
#
# Part 1, unmanaged: a set nodePort lands on the NodePort Service; unset,
#   Kubernetes allocates one.
# Part 2, managed: the LoadBalancer Service ignores the value.
# Part 3, schema: a non-integer nodePort fails the render.

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
rsync -a --exclude venv --exclude .git --exclude .claude "$REPO_ROOT/" "$CHART/"

render() { # <output-file> <managed> [helm args...]
  local out="$1" managed="$2"; shift 2
  helm template t "$CHART" -s templates/mysqlds/mysqld.yaml -s templates/rdrs.yaml \
    --values "$CHART/values/minikube/small.yaml" \
    --set meta.mysqld.externalLoadBalancer.enabled=true \
    --set meta.mysqld.externalLoadBalancer.managed="$managed" \
    --set meta.rdrs.externalLoadBalancer.enabled=true \
    --set meta.rdrs.externalLoadBalancer.managed="$managed" \
    "$@" > "$out" 2> "$out.err"
}

# service_field <rendered-file> <service-name> <field>: the first value of the
# field inside that Service document.
service_field() {
  awk -v name="$2" -v field="$3" '
    /^---/ {doc=""; svc=0; next}
    /^kind: Service$/ {svc=1}
    svc && $1 == "name:" && $2 == name {doc=name}
    doc == name && $1 == field":" {print $2; exit}
  ' "$1"
}

PINNED="$WORK_DIR/pinned.yaml"
render "$PINNED" false \
  --set meta.mysqld.externalLoadBalancer.nodePort=31306 \
  --set meta.rdrs.externalLoadBalancer.nodePort=31406 \
  || { echo "helm template failed:"; tail -5 "$PINNED.err"; exit 1; }
UNPINNED="$WORK_DIR/unpinned.yaml"
render "$UNPINNED" false || { echo "helm template failed:"; tail -5 "$UNPINNED.err"; exit 1; }
MANAGED="$WORK_DIR/managed.yaml"
render "$MANAGED" true \
  --set meta.mysqld.externalLoadBalancer.nodePort=31306 \
  --set meta.rdrs.externalLoadBalancer.nodePort=31406 \
  || { echo "helm template failed:"; tail -5 "$MANAGED.err"; exit 1; }

echo "Part 1 - unmanaged"

for pair in mysqld-external:31306 rdrs-external:31406; do
  svc="${pair%%:*}" port="${pair##*:}"
  assert "$svc is a NodePort Service" '[ "$(service_field "$PINNED" "$svc" type)" = "NodePort" ]'
  assert "$svc pins nodePort $port" '[ "$(service_field "$PINNED" "$svc" nodePort)" = "$port" ]'
  assert "$svc leaves nodePort to Kubernetes when unset" '[ -z "$(service_field "$UNPINNED" "$svc" nodePort)" ]'
done

echo "Part 2 - managed"

for svc in mysqld-external rdrs-external; do
  assert "$svc is a LoadBalancer Service" '[ "$(service_field "$MANAGED" "$svc" type)" = "LoadBalancer" ]'
  assert "$svc ignores nodePort when managed" '[ -z "$(service_field "$MANAGED" "$svc" nodePort)" ]'
done

echo "Part 3 - schema"

REJECTED="$WORK_DIR/rejected.yaml"
assert "rejects a string mysqld nodePort" \
  '! render "$REJECTED" false --set-string meta.mysqld.externalLoadBalancer.nodePort=31306'
assert "rejects a string rdrs nodePort" \
  '! render "$REJECTED" false --set-string meta.rdrs.externalLoadBalancer.nodePort=31406'

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
