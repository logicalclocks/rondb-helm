#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for rdrs.priorityClassName. Needs only helm and bash, no cluster.
# - By default the RDRS pods set no priorityClassName, whatever the top-level
#   priorityClass is, so existing installs render unchanged.
# - Set, it lands once in the RDRS pod spec, and the MySQL servers keep the
#   top-level priorityClass.
# - The schema refuses a non-string value.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0; FAIL=0
check() { # <description> <command...>: the check holds when the command succeeds
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "  ok: $desc"
  else FAIL=$((FAIL + 1)); echo "  FAIL: $desc"; fi
}
count() { grep -c -- "$1" <<< "$out" || true; } # <pattern>: matching lines of $out

CHART="$WORK_DIR/chart"
rsync -a --exclude venv --exclude .git --exclude .claude "$REPO_ROOT/" "$CHART/"

render() { # <template> [helm args...]: the rendered template on stdout
  local tpl="$1"; shift
  helm template t "$CHART" -s "$tpl" --values "$CHART/values/minikube/small.yaml" "$@"
}

out=$(render templates/rdrs.yaml)
check "default: no priorityClassName on the RDRS pods" [ "$(count priorityClassName)" -eq 0 ]

out=$(render templates/rdrs.yaml --set priorityClass=rondb-high-priority)
check "default: the top-level priorityClass does not reach the RDRS pods" [ "$(count priorityClassName)" -eq 0 ]

out=$(render templates/rdrs.yaml --set rdrs.priorityClassName=platform-data)
check "set: the RDRS pod spec carries it once" [ "$(count 'priorityClassName: "platform-data"')" -eq 1 ]
check "set: no other priorityClassName in the RDRS template" [ "$(count priorityClassName)" -eq 1 ]

out=$(render templates/mysqlds/mysqld.yaml --set rdrs.priorityClassName=platform-data --set priorityClass=rondb-high-priority)
check "set: the MySQL servers keep the top-level priorityClass" [ "$(count 'priorityClassName: "rondb-high-priority"')" -ge 1 ]

check "schema: a non-string value fails the render" \
  bash -c '! helm template t "$1" -s templates/rdrs.yaml --values "$1/values/minikube/small.yaml" --set-json rdrs.priorityClassName=5 >/dev/null 2>&1' _ "$CHART"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
