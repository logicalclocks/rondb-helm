#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.



# Tests for user-supplied MySQL users (mysql.users), in particular passwords
# read from customer-provided Secrets (mysql.users[].existingSecret) and the
# upgrade-time user-creation Job. Needs only helm and bash — no cluster.
#
# Part 1 — password sourcing: chart-generated users get a key in the
#   generated Secret; existingSecret users don't, and their env vars point
#   at the customer's Secret instead. ALTER USER (password convergence)
#   renders only for existingSecret users.
# Part 2 — upgrade Job: setup-mysql-users renders only on upgrades with
#   users declared, and its name changes with the user list.
# Part 3 — restore upgrade: the users Job waits on the native restore Job and
#   runs under the ServiceAccount whose Role may read that Job.
# Part 4 — validation: colliding/duplicate usernames and self-referencing
#   existingSecret fail the render.

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

GENERATED_USER='{"username":"importantuser","host":"%","privileges":[{"database":"*","table":"*","privileges":["ALL"],"withGrantOption":true}]}'
EXTERNAL_USER='{"username":"reportinguser","host":"%","existingSecret":{"name":"my-app-passwords","key":"reporting-password"},"privileges":[{"database":"helmtest","table":"*","privileges":["SELECT"]}]}'

render() { # <output-file> [helm --set flags...]
  local out=$1; shift
  helm template t "$CHART" --values "$CHART/values/minikube/small.yaml" "$@" \
    > "$out" 2> "$out.err" || { echo "helm template failed:"; tail -5 "$out.err"; exit 1; }
}

# Succeeds only when the render fails AND the failure comes from the
# mysql.users validation (not some unrelated render error)
render_fails() { # <users-json>
  local users=$1 err
  if err=$(helm template t "$CHART" --values "$CHART/values/minikube/small.yaml" \
      --set-json "mysql.users=$users" 2>&1 > /dev/null); then
    return 1
  fi
  grep -q "mysql.users:" <<< "$err"
}

# Extract the generated passwords Secret manifest from a render
secret_manifest() { # <render-file> <output-file>
  awk '/^# Source: rondb\/templates\/mysqlds\/secrets.yaml/,/^---/' "$1" > "$2"
}

echo "=== install: generated + existingSecret users ==="
render "$WORK_DIR/install.yaml" --set-json "mysql.users=[$GENERATED_USER,$EXTERNAL_USER]"
secret_manifest "$WORK_DIR/install.yaml" "$WORK_DIR/secret.yaml"
assert "generated Secret has a key for the generated user" '[[ $(count "^  importantuser:" $WORK_DIR/secret.yaml) == 1 ]]'
assert "generated Secret has no key for the existingSecret user" '[[ $(count "reportinguser" $WORK_DIR/secret.yaml) == 0 ]]'
assert "generated user env reads from the generated Secret" 'grep -A4 "name: MYSQL_IMPORTANTUSER_PASSWORD" $WORK_DIR/install.yaml | grep -q "key: importantuser"'
assert "existingSecret user env reads from the customer Secret" 'grep -A4 "name: MYSQL_REPORTINGUSER_PASSWORD" $WORK_DIR/install.yaml | grep -q "name: my-app-passwords"'
assert "existingSecret user env reads the customer key" 'grep -A4 "name: MYSQL_REPORTINGUSER_PASSWORD" $WORK_DIR/install.yaml | grep -q "key: reporting-password"'
assert "both users are created in the setup script" '[[ $(count "CREATE USER IF NOT EXISTS" $WORK_DIR/install.yaml) -ge 2 ]]'
assert "ALTER USER only for the existingSecret user" '[[ $(count "ALTER USER .reportinguser" $WORK_DIR/install.yaml) -ge 1 && $(count "ALTER USER .importantuser" $WORK_DIR/install.yaml) == 0 ]]'
assert "passwords are SQL-escaped before CREATE USER (both users)" '[[ $(count "MY_PW//" $WORK_DIR/install.yaml) -ge 4 ]]'
# NDB_STORED_USER is a dynamic privilege: granting it per database.table
# fails with ERROR 3619; it must always be granted ON *.*
assert "NDB_STORED_USER only ever granted ON *.*" '[[ $(count "GRANT NDB_STORED_USER" $WORK_DIR/install.yaml) == $(count "GRANT NDB_STORED_USER ON \*\.\* TO" $WORK_DIR/install.yaml) ]]'
assert "NDB_STORED_USER granted to both users" '[[ $(count "GRANT NDB_STORED_USER ON \*\.\* TO .importantuser" $WORK_DIR/install.yaml) -ge 1 && $(count "GRANT NDB_STORED_USER ON \*\.\* TO .reportinguser" $WORK_DIR/install.yaml) -ge 1 ]]'
assert "no users Job on install" '[[ $(count "name: setup-mysql-users" $WORK_DIR/install.yaml) == 0 ]]'
assert "install setup Job present on install" '[[ $(count "name: setup-mysqld-dont-remove" $WORK_DIR/install.yaml) -ge 1 ]]'

echo "=== upgrade: users Job renders, setup Job does not ==="
render "$WORK_DIR/upgrade.yaml" --set mode=upgrade --set-json "mysql.users=[$GENERATED_USER,$EXTERNAL_USER]"
assert "users Job renders on upgrade" '[[ $(count "name: setup-mysql-users-" $WORK_DIR/upgrade.yaml) == 1 ]]'
assert "install setup Job absent on upgrade" '[[ $(count "name: setup-mysqld-dont-remove" $WORK_DIR/upgrade.yaml) == 0 ]]'
awk "/name: setup-mysql-users-/,0" "$WORK_DIR/upgrade.yaml" > "$WORK_DIR/usersjob.yaml"
assert "users Job reads root password from generated Secret" 'grep -A4 "name: MYSQL_ROOT_PASSWORD" $WORK_DIR/usersjob.yaml | grep -q "key: root"'
assert "users Job reads existingSecret user from customer Secret" 'grep -A4 "name: MYSQL_REPORTINGUSER_PASSWORD" $WORK_DIR/usersjob.yaml | grep -q "name: my-app-passwords"'
assert "users Job creates users" '[[ $(count "CREATE USER IF NOT EXISTS" $WORK_DIR/usersjob.yaml) -ge 2 ]]'
assert "users Job SQL-escapes passwords" '[[ $(count "MY_PW//" $WORK_DIR/usersjob.yaml) -ge 4 ]]'

echo "=== upgrade: Job name changes with the user list (Argo immutable Jobs) ==="
render "$WORK_DIR/upgrade2.yaml" --set mode=upgrade --set-json "mysql.users=[$GENERATED_USER]"
NAME1=$(grep -o "setup-mysql-users-[0-9]*-[a-f0-9]*" "$WORK_DIR/upgrade.yaml" | head -1)
NAME2=$(grep -o "setup-mysql-users-[0-9]*-[a-f0-9]*" "$WORK_DIR/upgrade2.yaml" | head -1)
assert "different user lists yield different Job names" '[[ -n "$NAME1" && -n "$NAME2" && "$NAME1" != "$NAME2" ]]'

echo "=== upgrade: rotationId bump changes the Job name (Argo secret rotation) ==="
# Same users, same (constant) revision — only existingSecret.rotationId differs
ROTATED_USER=${EXTERNAL_USER/'"key":"reporting-password"'/'"key":"reporting-password","rotationId":"r2"'}
render "$WORK_DIR/rot.yaml" --set mode=upgrade --set-json "mysql.users=[$ROTATED_USER]"
render "$WORK_DIR/rot-base.yaml" --set mode=upgrade --set-json "mysql.users=[$EXTERNAL_USER]"
NAME_ROT=$(grep -o "setup-mysql-users-[0-9]*-[a-f0-9]*" "$WORK_DIR/rot.yaml" | head -1)
NAME_BASE=$(grep -o "setup-mysql-users-[0-9]*-[a-f0-9]*" "$WORK_DIR/rot-base.yaml" | head -1)
assert "rotationId alone yields a different Job name" '[[ -n "$NAME_ROT" && -n "$NAME_BASE" && "$NAME_ROT" != "$NAME_BASE" ]]'

echo "=== upgrade: no users -> no users Job ==="
render "$WORK_DIR/upgrade-nousers.yaml" --set mode=upgrade
assert "no users Job without mysql.users" '[[ $(count "name: setup-mysql-users" $WORK_DIR/upgrade-nousers.yaml) == 0 ]]'

echo "=== restore upgrade: users Job waits on the restore Job under the restore-watcher SA ==="
# With a backup ID set, the wait-restore-backup init container does `kubectl wait`
# on the restore Job. Only restore-backup-watcher-sa is bound to a Role that may
# read it; wait-init-jobs-sa (the Job's SA without a restore) may read the mysqld
# setup Job alone, and a Job left on it crash-loops on Forbidden forever.
RESTORE_FLAGS=(--set-string restoreFromBackup.backupId=123
  --set restoreFromBackup.inPlace=true --set restoreFromBackup.forceDataClear=true
  --set restoreFromBackup.s3.bucketName=b --set restoreFromBackup.s3.endpoint=http://minio:9000
  --set restoreFromBackup.s3.provider=Minio --set restoreFromBackup.s3.region=r
  --set restoreFromBackup.s3.keyCredentialsSecret.name=c --set restoreFromBackup.s3.keyCredentialsSecret.key=k
  --set restoreFromBackup.s3.secretCredentialsSecret.name=c --set restoreFromBackup.s3.secretCredentialsSecret.key=s)
render "$WORK_DIR/restore.yaml" --set mode=upgrade --set-json "mysql.users=[$GENERATED_USER]" "${RESTORE_FLAGS[@]}"
users_job_manifest() { # <render-file> <output-file>
  awk '/^# Source: rondb\/templates\/mysqlds\/setup_users_job.yaml/,/^---/' "$1" > "$2"
}
users_job_manifest "$WORK_DIR/restore.yaml" "$WORK_DIR/restorejob.yaml"
users_job_manifest "$WORK_DIR/upgrade.yaml" "$WORK_DIR/plainjob.yaml"
assert "users Job renders on a restore upgrade" '[[ $(count "name: setup-mysql-users-" $WORK_DIR/restorejob.yaml) == 1 ]]'
assert "users Job waits for the restore Job" '[[ $(count "name: wait-restore-backup" $WORK_DIR/restorejob.yaml) == 1 ]]'
assert "users Job waits on the restore Job by name" 'grep -q "job/restore-native-backup-123" $WORK_DIR/restorejob.yaml'
assert "users Job runs as the restore-watcher SA" '[[ $(count "serviceAccountName: restore-backup-watcher-sa" $WORK_DIR/restorejob.yaml) == 1 ]]'
assert "restore-watcher Role may read the restore Job" 'awk "/name: restore-backup-watcher$/,/^---/" $WORK_DIR/restore.yaml | grep -q "resourceNames: \[restore-native-backup-123\]"'
assert "users Job keeps wait-init-jobs-sa without a restore" '[[ $(count "serviceAccountName: wait-init-jobs-sa" $WORK_DIR/plainjob.yaml) == 1 ]]'
assert "users Job has no restore wait without a restore" '[[ $(count "name: wait-restore-backup" $WORK_DIR/plainjob.yaml) == 0 ]]'

echo "=== validation failures ==="
assert "username 'root' is rejected" 'render_fails "[{\"username\":\"root\",\"host\":\"%\",\"privileges\":[{\"database\":\"*\",\"table\":\"*\",\"privileges\":[\"ALL\"]}]}]"'
assert "cluster user collision is rejected" 'render_fails "[{\"username\":\"helm\",\"host\":\"%\",\"privileges\":[{\"database\":\"*\",\"table\":\"*\",\"privileges\":[\"ALL\"]}]}]"'
assert "duplicate usernames are rejected" 'render_fails "[$GENERATED_USER,$GENERATED_USER]"'
assert "env var collision with built-in env is rejected (username cluster)" 'render_fails "[{\"username\":\"cluster\",\"host\":\"%\",\"privileges\":[{\"database\":\"*\",\"table\":\"*\",\"privileges\":[\"ALL\"]}]}]"'
assert "env var collision between users is rejected (my-user vs my_user)" 'render_fails "[{\"username\":\"my-user\",\"host\":\"%\",\"privileges\":[{\"database\":\"*\",\"table\":\"*\",\"privileges\":[\"ALL\"]}]},{\"username\":\"my_user\",\"host\":\"%\",\"privileges\":[{\"database\":\"*\",\"table\":\"*\",\"privileges\":[\"ALL\"]}]}]"'
assert "username producing an invalid env var name is rejected" 'render_fails "[{\"username\":\"a.b\",\"host\":\"%\",\"privileges\":[{\"database\":\"*\",\"table\":\"*\",\"privileges\":[\"ALL\"]}]}]"'
assert "quote in username is rejected" 'render_fails "[{\"username\":\"it'\''s\",\"host\":\"%\",\"privileges\":[{\"database\":\"*\",\"table\":\"*\",\"privileges\":[\"ALL\"]}]}]"'
assert "existingSecret pointing at credentialsSecretName is rejected" 'render_fails "[{\"username\":\"b\",\"host\":\"%\",\"existingSecret\":{\"name\":\"mysql-passwords\",\"key\":\"b\"},\"privileges\":[{\"database\":\"*\",\"table\":\"*\",\"privileges\":[\"ALL\"]}]}]"'

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL == 0 ]]
