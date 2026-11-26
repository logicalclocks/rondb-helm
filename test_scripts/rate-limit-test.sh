#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for the data node and MySQL server settings of rate limit groups
# (RONDB-1158). Needs only helm and bash, no cluster.
#
# Part 1, defaults: none of the settings reaches config.ini or my.cnf.
# Part 2, rondbConfig.MaxNoOfUserObjects: required once
#   mysql.config.ndbUserRateLimits, rdrs.rateLimit.enable or
#   rondbConfig.ActivateRateLimits is on, and rendered whenever set, whatever
#   those say, together with a MaxNoOfSchemaObjects that covers it:
#   max(20320, MaxNoOfTables (8000 when unset) + 128 ordered indexes + 2300
#   unique hash indexes + MaxNoOfUserObjects), unless MaxNoOfSchemaObjects is
#   set; an explicit MaxNoOfSchemaObjects below that sum fails the render.
# Part 3, mysql.config.ndbUserRateLimits: needs rondbConfig.ActivateRateLimits
#   and lands in every my.cnf.
# Part 4, rondbConfig.RateLimitBudgetPercent: rendered only when set, 1 to 100.

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

OUT="$WORK_DIR/out.yaml"
render() { # [helm args...]
  helm template t "$CHART" "$@" > "$OUT" 2> "$OUT.err" \
    || { echo "helm template failed:"; tail -5 "$OUT.err"; exit 1; }
}

# Succeeds only when the render fails AND the message carries the fragment,
# so an unrelated render error does not pass.
render_fails() { # <expected-message-fragment> [helm args...]
  local fragment=$1 err; shift
  if err=$(helm template t "$CHART" "$@" 2>&1 > /dev/null); then
    return 1
  fi
  grep -qF -- "$fragment" <<< "$err"
}

# ini <key>: the values of a config.ini key in the last render, space separated.
ini() { sed -nE "s/^ +$1=(.*)$/\1/p" "$OUT" | paste -sd' ' -; }

echo "Part 1 - defaults"

render
assert "no MaxNoOfUserObjects" '[ -z "$(ini MaxNoOfUserObjects)" ]'
assert "no MaxNoOfSchemaObjects" '[ -z "$(ini MaxNoOfSchemaObjects)" ]'
assert "no RateLimitBudgetPercent" '[ -z "$(ini RateLimitBudgetPercent)" ]'
assert "ActivateRateLimits=0" '[ "$(ini ActivateRateLimits)" = 0 ]'
assert "no ndb-user-rate-limits in my.cnf" '! grep -q "ndb-user-rate-limits" "$OUT"'

echo "Part 2 - MaxNoOfUserObjects"

assert "ActivateRateLimits=1 without it fails, naming the key" \
  'render_fails "rondbConfig.MaxNoOfUserObjects" --set rondbConfig.ActivateRateLimits=1'
assert "rdrs.rateLimit.enable=true without it fails, naming the key" \
  'render_fails "rondbConfig.MaxNoOfUserObjects" --set rdrs.rateLimit.enable=true'
assert "mysql.config.ndbUserRateLimits=true without it fails, naming the key" \
  'render_fails "rondbConfig.MaxNoOfUserObjects" --set mysql.config.ndbUserRateLimits=true --set rondbConfig.ActivateRateLimits=1'

render --set rdrs.rateLimit.enable=false
assert "rdrs.rateLimit.enable=false does not require it" '[ -z "$(ini MaxNoOfUserObjects)" ]'

render --set rdrs.rateLimit.enable=true --set rondbConfig.MaxNoOfUserObjects=100
assert "rdrs.rateLimit.enable=true renders with it" '[ "$(ini MaxNoOfUserObjects)" = 100 ]'

# Helm drops a null-valued key before rendering, so the whole section can be absent.
assert "rdrs.rateLimit=null renders" 'helm template t "$CHART" --set rdrs.rateLimit=null > /dev/null 2>&1'

# max(20320, 8000 + 128 + 2300 + 5000 = 15428) = 20320
render --set rondbConfig.ActivateRateLimits=1 --set rondbConfig.MaxNoOfUserObjects=5000
assert "renders MaxNoOfUserObjects=5000" '[ "$(ini MaxNoOfUserObjects)" = 5000 ]'
assert "a sum below 20320 renders MaxNoOfSchemaObjects=20320" '[ "$(ini MaxNoOfSchemaObjects)" = 20320 ]'

# max(20320, 8000 + 128 + 2300 + 20000 = 30428) = 30428
render --set rondbConfig.ActivateRateLimits=1 --set rondbConfig.MaxNoOfUserObjects=20000
assert "with the kernel's 8000 tables: MaxNoOfSchemaObjects=30428" '[ "$(ini MaxNoOfSchemaObjects)" = 30428 ]'

# max(20320, 12000 + 128 + 2300 + 20000 = 34428) = 34428
render --set rondbConfig.ActivateRateLimits=1 --set rondbConfig.MaxNoOfUserObjects=20000 \
  --set rondbConfig.MaxNoOfTables=12000
assert "with MaxNoOfTables=12000: MaxNoOfSchemaObjects=34428" \
  '[ "$(ini MaxNoOfTables)" = 12000 ] && [ "$(ini MaxNoOfSchemaObjects)" = 34428 ]'

render --set rondbConfig.ActivateRateLimits=1 --set rondbConfig.MaxNoOfUserObjects=20000 \
  --set rondbConfig.MaxNoOfSchemaObjects=40000
assert "an explicit MaxNoOfSchemaObjects is rendered as set" \
  '[ "$(ini MaxNoOfSchemaObjects)" = 40000 ] && [ "$(ini MaxNoOfUserObjects)" = 20000 ]'

# The data nodes refuse to start below the sum (Configuration.cpp, "increase
# MaxNoOfSchemaObjects"), so the render fails first, naming both numbers.
assert "an explicit MaxNoOfSchemaObjects below the sum fails the render" \
  'render_fails "rondbConfig.MaxNoOfSchemaObjects (25000) is below the 30428" --set rondbConfig.ActivateRateLimits=1 --set rondbConfig.MaxNoOfUserObjects=20000 --set rondbConfig.MaxNoOfSchemaObjects=25000'
render --set rondbConfig.MaxNoOfUserObjects=20000 --set rondbConfig.MaxNoOfSchemaObjects=30428
assert "an explicit MaxNoOfSchemaObjects equal to the sum renders" '[ "$(ini MaxNoOfSchemaObjects)" = 30428 ]'

# The ceiling on an explicit MaxNoOfSchemaObjects, 1200000, is the previous
# 200000 for tables and indexes plus the 1000000 user objects the chart allows,
# so a value the chart generated can be pinned explicitly.
assert "the sum generated for MaxNoOfUserObjects=1000000, 1010428, round-trips as an integer" \
  'helm template t "$CHART" --set-json rondbConfig.MaxNoOfUserObjects=1000000 --set-json rondbConfig.MaxNoOfSchemaObjects=1010428 > "$OUT" 2>/dev/null && [ "$(ini MaxNoOfSchemaObjects)" = 1010428 ]'
assert "1200000 is accepted" \
  'helm template t "$CHART" --set-json rondbConfig.MaxNoOfUserObjects=1000000 --set-json rondbConfig.MaxNoOfTables=189572 --set-json rondbConfig.MaxNoOfSchemaObjects=1200000 > "$OUT" 2>/dev/null && [ "$(ini MaxNoOfSchemaObjects)" = 1200000 ]'
assert "rejects a MaxNoOfSchemaObjects above 1200000" \
  'render_fails "MaxNoOfSchemaObjects" --set-json rondbConfig.MaxNoOfSchemaObjects=1200001'

render --set rondbConfig.MaxNoOfSchemaObjects=25000
assert "an explicit MaxNoOfSchemaObjects without the allowance is rendered alone" \
  '[ "$(ini MaxNoOfSchemaObjects)" = 25000 ] && [ -z "$(ini MaxNoOfUserObjects)" ]'

# Lowering either value while user objects exist can stop a data node from
# restarting, so turning rate limiting off must not drop them.
render --set rondbConfig.MaxNoOfUserObjects=20000
assert "with every flag off both are still rendered" \
  '[ "$(ini ActivateRateLimits)" = 0 ] && [ "$(ini MaxNoOfUserObjects)" = 20000 ] && [ "$(ini MaxNoOfSchemaObjects)" = 30428 ]'

render --set rondbConfig.ActivateRateLimits=1 --set rondbConfig.MaxNoOfUserObjects=0
assert "an explicit 0 satisfies the requirement and is rendered" \
  '[ "$(ini MaxNoOfUserObjects)" = 0 ] && [ "$(ini MaxNoOfSchemaObjects)" = 20320 ]'

# --set-json passes the number as a values file does (a float), --set as an
# integer; a float of a million or more prints as 1e+06 unless converted.
render --set-json rondbConfig.MaxNoOfUserObjects=1000000
assert "a values-file number renders as an integer" \
  '[ "$(ini MaxNoOfUserObjects)" = 1000000 ] && [ "$(ini MaxNoOfSchemaObjects)" = 1010428 ]'

assert "rejects a negative MaxNoOfUserObjects" \
  'render_fails "MaxNoOfUserObjects" --set rondbConfig.MaxNoOfUserObjects=-1'
assert "rejects a string MaxNoOfUserObjects" \
  'render_fails "MaxNoOfUserObjects" --set rondbConfig.MaxNoOfUserObjects=many'
# RonDB's own maximum (ConfigInfo.cpp); the management server refuses a larger value at start.
assert "rejects a MaxNoOfUserObjects above 1000000" \
  'render_fails "MaxNoOfUserObjects" --set rondbConfig.MaxNoOfUserObjects=1000001'

echo "Part 3 - mysql.config.ndbUserRateLimits"

assert "without ActivateRateLimits fails, naming the key" \
  'render_fails "rondbConfig.ActivateRateLimits" --set mysql.config.ndbUserRateLimits=true --set rondbConfig.MaxNoOfUserObjects=100'

render --set mysql.config.ndbUserRateLimits=true --set rondbConfig.ActivateRateLimits=1 \
  --set rondbConfig.MaxNoOfUserObjects=100 --set meta.ddlMySQLd.enabled=true
assert "ndb-user-rate-limits = ON in every my.cnf" \
  '[ "$(grep -c "^ *ndb-user-rate-limits *= ON$" "$OUT")" -eq "$(grep -c "^ *max-prepared-stmt-count *=" "$OUT")" ] && [ "$(grep -c "^ *ndb-user-rate-limits" "$OUT")" -eq 4 ]'

# The flag is read at mysqld startup only and my.cnf is not hashed into the
# pod templates, so the flag itself is stamped on them: switching it either
# way changes every MySQL pod template and rolls the servers.
ANNOTATION='rondb.hopsworks.ai/ndb-user-rate-limits: "true"'
render --set mysql.config.ndbUserRateLimits=true --set rondbConfig.ActivateRateLimits=1 \
  --set rondbConfig.MaxNoOfUserObjects=100 --set meta.ddlMySQLd.enabled=true \
  --set globalReplication.primary.enabled=true --set globalReplication.secondary.enabled=true
assert "the flag is an annotation on all four MySQL pod templates" \
  '[ "$(grep -cF "$ANNOTATION" "$OUT")" -eq 4 ]'
render --set rondbConfig.ActivateRateLimits=1 --set rondbConfig.MaxNoOfUserObjects=100 \
  --set meta.ddlMySQLd.enabled=true \
  --set globalReplication.primary.enabled=true --set globalReplication.secondary.enabled=true
assert "with the flag off no pod template carries the annotation" \
  '! grep -qF "ndb-user-rate-limits" "$OUT"'

assert "rejects a string for ndbUserRateLimits" \
  'render_fails "ndbUserRateLimits" --set mysql.config.ndbUserRateLimits=yes'

echo "Part 4 - RateLimitBudgetPercent"

render --set rondbConfig.RateLimitBudgetPercent=70
assert "70 is rendered, with no other rate limit setting" \
  '[ "$(ini RateLimitBudgetPercent)" = 70 ] && [ -z "$(ini MaxNoOfUserObjects)" ]'
render --set rondbConfig.RateLimitBudgetPercent=1
assert "1 is rendered" '[ "$(ini RateLimitBudgetPercent)" = 1 ]'
render --set rondbConfig.RateLimitBudgetPercent=100
assert "100 is rendered" '[ "$(ini RateLimitBudgetPercent)" = 100 ]'
assert "rejects 0" 'render_fails "RateLimitBudgetPercent" --set rondbConfig.RateLimitBudgetPercent=0'
assert "rejects 101" 'render_fails "RateLimitBudgetPercent" --set rondbConfig.RateLimitBudgetPercent=101'

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
