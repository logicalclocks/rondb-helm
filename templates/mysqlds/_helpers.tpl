{{/*
- Run all custom SQL init files
*/}}
{{- define "rondb.sqlInitContent" -}}
{{- range $k, $v := .Values.mysql.sqlInitContent }}
{{ $v | indent 4 }}
{{- end }}
{{- end -}}

{{ define "rondb.mysql.getPasswordEnvVarName" -}}
{{- printf "MYSQL_%s_PASSWORD" (required "Username is required" .username) | upper | replace "-" "_" -}}
{{- end -}}

{{/*
    Emits the env var carrying a mysql.users entry's password.
    Users with `existingSecret` read their password from a customer-provided
    Secret (no key for them is generated in mysql.credentialsSecretName).
    Context: dict "user" <mysql.users entry> "credentialsSecretName" <string>
*/}}
{{- define "rondb.mysql.userPasswordEnvVar" -}}
- name: {{ include "rondb.mysql.getPasswordEnvVarName" .user }}
  valueFrom:
    secretKeyRef:
{{- if .user.existingSecret }}
      name: {{ .user.existingSecret.name }}
      key: {{ .user.existingSecret.key }}
{{- else }}
      name: {{ .credentialsSecretName }}
      key: {{ .user.username }}
{{- end }}
{{- end -}}

{{/*
    Validates mysql.users at render time. Called from every template that
    consumes mysql.users so misconfigurations fail the render, not the Jobs.
    Context: root ($)
*/}}
{{- define "rondb.mysql.validateUsers" -}}
{{- $reserved := list "root" .Values.mysql.clusterUser }}
{{- if .Values.mysql.exporter.enabled }}
{{- $reserved = append $reserved .Values.mysql.exporter.username }}
{{- end }}
{{- /* Env var names of the chart-managed passwords; the username-derived
       names must never collide with them (duplicate env names in a Pod are
       resolved last-wins, silently wiring the wrong password) */}}
{{- $reservedEnvNames := list "MYSQL_ROOT_PASSWORD" "MYSQL_CLUSTER_PASSWORD" "MYSQL_EXPORTER_PASSWORD" }}
{{- $seenEnvNames := dict }}
{{- range .Values.mysql.users }}
{{- if has .username $reserved }}
{{- fail (printf "mysql.users: username '%s' collides with a chart-managed user (root, cluster user or exporter)" .username) }}
{{- end }}
{{- if or (contains "'" .username) (contains "\\" .username) (contains "'" .host) (contains "\\" .host) }}
{{- fail (printf "mysql.users: username/host of user '%s' must not contain quotes or backslashes" .username) }}
{{- end }}
{{- $envName := include "rondb.mysql.getPasswordEnvVarName" . }}
{{- if not (regexMatch "^[A-Z0-9_]+$" $envName) }}
{{- fail (printf "mysql.users: username '%s' produces invalid env var name '%s'; usernames may only contain letters, digits, '_' and '-'" .username $envName) }}
{{- end }}
{{- if has $envName $reservedEnvNames }}
{{- fail (printf "mysql.users: username '%s' produces reserved env var name '%s'" .username $envName) }}
{{- end }}
{{- if hasKey $seenEnvNames $envName }}
{{- fail (printf "mysql.users: usernames '%s' and '%s' both produce env var name '%s'" (get $seenEnvNames $envName) .username $envName) }}
{{- end }}
{{- $_ := set $seenEnvNames $envName .username }}
{{- if and .existingSecret (not $.Values.mysql.supplyOwnSecret) (eq .existingSecret.name $.Values.mysql.credentialsSecretName) }}
{{- fail (printf "mysql.users: user '%s' sets existingSecret.name to mysql.credentialsSecretName ('%s'), but the generated Secret holds no key for users with existingSecret; point it at a Secret you create yourself" .username .existingSecret.name) }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
    Shell fragment that creates all user-supplied MySQL users (mysql.users)
    and applies their grants. Assumes a `mysql` shell function connecting as
    root is defined in the surrounding script. Safe to re-run: CREATE USER is
    idempotent and GRANTs are additive.
    Context: root ($)
*/}}
{{- define "rondb.mysql.setupUsersShell" -}}
{{- range $.Values.mysql.users }}
MY_PW=${{ include "rondb.mysql.getPasswordEnvVarName" . }}
# Escape backslashes and single quotes so the password is a safe MySQL string
# literal; passwords from customer Secrets (existingSecret, supplyOwnSecret)
# may contain any characters
MY_PW="${MY_PW//\\/\\\\}"
MY_PW="${MY_PW//\'/\\\'}"
{{- $mysqlUser := printf "'%s'@'%s'" .username .host }}
{{- /* printf, not echo: echo may interpret backslashes (xpg_echo/sh),
       which would undo the escaping above */}}
printf '%s\n' "CREATE USER IF NOT EXISTS {{ $mysqlUser }} IDENTIFIED BY '${MY_PW}';" | mysql
{{- if .existingSecret }}
# Externally-managed password: converge to the Secret's current value so
# rotations in the customer's Secret are applied on upgrade. Chart-generated
# passwords are never ALTERed (template-only renders regenerate them).
printf '%s\n' "ALTER USER {{ $mysqlUser }} IDENTIFIED BY '${MY_PW}';" | mysql
{{- end }}
{{- /* NDB_STORED_USER is a dynamic privilege: it can only be granted ON *.*
       (granting it per database.table fails with ERROR 3619) and marks the
       whole user as stored in NDB, so grant it once per user */}}
mysql <<EOF
GRANT NDB_STORED_USER ON *.* TO {{ $mysqlUser }};
FLUSH PRIVILEGES;
EOF
{{- range .privileges }}
{{- $databaseTable := printf "%s.%s" .database .table }}
mysql <<EOF
GRANT {{ .privileges | join ", " }}
    ON {{ $databaseTable }}
    TO {{ $mysqlUser }}
{{- if .withGrantOption}}
    WITH GRANT OPTION
{{- end }}
;
FLUSH PRIVILEGES;
EOF
{{- end }}
{{- end }}
{{- end -}}

{{- define "rondb.container.waitOneBinlogServer" -}}
{{- if $.Values.globalReplication.primary.enabled }}
- name: wait-one-binlog-server
  image: {{ include "image_address" (dict "image" $.Values.images.rondb) }}
  imagePullPolicy: {{ $.Values.imagePullPolicy }}
  command:
  - /bin/bash
  - -c
  - |
    until nslookup $BINLOG_SERVER_HOSTNAME; do
        echo "Waiting for $BINLOG_SERVER_HOSTNAME to be resolvable..."
        sleep $(((RANDOM % 2) + 2))
    done

    while true; do
        mysqladmin \
            -h $BINLOG_SERVER_HOSTNAME \
            --port=3306 \
            --connect-timeout=2 \
            ping

        if [ $? -eq 0 ]; then
            echo "Successfully pinged to MySQL binlog server"
            break
        fi
        echo "MySQL ping failed, retrying in a bit..."
        sleep 2
    done
  env:
# The Binlog servers need to be running before any SQL has been run.
# This means that its readinessProbe will be failing at first since
# the MySQL passwords have not been set yet. Therefore, we try to
# contact the headless ClusterIP directly here, which is registered
# before the readinessProbe is successul.
{{- $firstBinlogHostname := (printf "%s-%d.%s.%s.svc.cluster.local"
    $.Values.meta.binlogServers.statefulSet.name
    0
    $.Values.meta.binlogServers.headlessClusterIp.name
    $.Release.Namespace
)}}
  - name: BINLOG_SERVER_HOSTNAME
    value: {{ $firstBinlogHostname }}
{{- end }}
{{- end }}

{{- define "rondb.container.waitSingleSetup" -}}
{{- if include "rondb.isInstall" . }}
- name: wait-single-setup-job
  image: {{ include "image_address" (dict "image" $.Values.images.toolbox) }}
  imagePullPolicy: {{ $.Values.imagePullPolicy }}
{{ include "rondb.ContainerSecurityContext" $ | indent 2 }}
  command:
  - /bin/bash
  - -c
  - |
    set -e
    echo "Waiting for {{ include "rondb.mysqldSetupJobName" . }} Job to have completed"

{{- $waitTimeoutMinutes := .Values.timeoutsMinutes.singleSetupMySQLds }}
{{- if include "rondb.restoreFromBackup.backupId" . }}
    {{- $waitTimeoutMinutes = (add $waitTimeoutMinutes .Values.timeoutsMinutes.restoreNativeBackup) }}
{{- end }}
    (
        set -x
        kubectl wait \
            -n {{ .Release.Namespace }} \
            --for=condition=complete \
            --timeout={{ $waitTimeoutMinutes }}m \
            job/{{ include "rondb.mysqldSetupJobName" . }}
    )

    echo "Setup Job has completed successfully"
{{- end }}
{{- end }}

{{- define "rondb.container.isDnsResolvable" -}}
- name: check-dns-resolvable
  image: {{ include "image_address" (dict "image" $.Values.images.toolbox) }}
  imagePullPolicy: {{ $.Values.imagePullPolicy }}
{{ include "rondb.ContainerSecurityContext" $ | indent 2 }}
  command:
  - /bin/bash
  - -c
  - |
{{ include "rondb.resolveOwnIp" $ | indent 6}}
  resources:
    limits:
      cpu: 0.3
      memory: 100Mi
{{- end }}

{{- define "rondb.mysqld.adminProbe" -}}
exec:
  command:
  # An "Access Denied" will still return error code 0 because the server is up
  # Alternatively, one can use the command "status"
  - /bin/bash
  - -c
  - |
    mysqladmin \
      --defaults-file=$RONDB_DATA_DIR/my.cnf \
      ping \
      --protocol=tcp \
{{- if (required "Required to set TLS for mysqldadmin probes" .tls) }}
      --ssl-mode=REQUIRED
{{- else }}
      --ssl-mode=PREFERRED
{{- end }}
timeoutSeconds: 2
failureThreshold: 4
periodSeconds: 5
{{- end -}}

{{- define "rondb.mysqld.selectProbe" -}}
exec:
  command:
  - /bin/bash
  - -c
  - |
    set -e
    mysql \
      --defaults-file=$RONDB_DATA_DIR/my.cnf \
      --protocol=tcp \
      -e "SELECT 1"
timeoutSeconds: 2
{{- if (required "Required to specify whether SELECT probe is for startup" .isStartup) }}
# Total startup timeout = failureThreshold * periodSeconds
failureThreshold: {{ mul (required "Required to set startupTimeoutMinutes for startup probes" .startupTimeoutMinutes) 6 }}
periodSeconds: 10
{{- else }}
failureThreshold: 4
periodSeconds: 5
{{- end }}
{{- end -}}

{{ define "rondb.mysqld.probes" -}}
startupProbe:
{{ include "rondb.mysqld.selectProbe" (dict "isStartup" true "startupTimeoutMinutes" .startupTimeoutMinutes) | indent 2 }}
livenessProbe:
{{ include "rondb.mysqld.adminProbe" (dict "tls" .tls) | indent 2 }}
readinessProbe:
{{ include "rondb.mysqld.selectProbe" (dict "isStartup" false) | indent 2 }}
{{- end }}

{{/*
    Place all databases used for Helm operation here.
*/}}

{{- define "rondb.tables.heartbeat" -}}
heartbeat
{{- end -}}

{{- define "rondb.databases.heartbeat" -}}
heartbeat
{{- end -}}

{{- define "rondb.databases.benchmarking" -}}
- ycsb
- dbt2
{{- end -}}

{{/*
    This database should be persisted across backup/restore and global
    replications. This is because we test whether the data in the database
    can still be accessed & verified after a restore or replication.
*/}}
{{- define "rondb.databases.helmTests" -}}
helmtest
{{- end -}}

{{- define "rondb.databases.all" -}}
{{- include "rondb.databases.benchmarking" . }}
- {{ include "rondb.databases.helmTests" . }}
- {{ include "rondb.databases.heartbeat" . }}
{{- end -}}

{{- define "mysqld.loadBalancersEnabled" -}}
{{- if and .Values.meta .Values.meta.mysqld .Values.meta.mysqld.externalLoadBalancer .Values.meta.mysqld.externalLoadBalancer.enabled -}}
true
{{- end -}}
{{- end -}}

{{- define "mysqld.managedLoadBalancers" -}}
{{- if include "mysqld.loadBalancersEnabled" . -}}
{{- if .Values.meta.mysqld.externalLoadBalancer.managed -}}
true
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mysqld.unmanagedLoadBalancers" -}}
{{- if include "mysqld.loadBalancersEnabled" . -}}
{{- if not .Values.meta.mysqld.externalLoadBalancer.managed -}}
true
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "rdrs.loadBalancersEnabled" -}}
{{- if and .Values.meta .Values.meta.rdrs .Values.meta.rdrs.externalLoadBalancer .Values.meta.rdrs.externalLoadBalancer.enabled -}}
true
{{- end -}}
{{- end -}}

{{- define "rdrs.managedLoadBalancers" -}}
{{- if include "rdrs.loadBalancersEnabled" . -}}
{{- if .Values.meta.rdrs.externalLoadBalancer.managed -}}
true
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "rdrs.unmanagedLoadBalancers" -}}
{{- if include "rdrs.loadBalancersEnabled" . -}}
{{- if not .Values.meta.rdrs.externalLoadBalancer.managed -}}
true
{{- end -}}
{{- end -}}
{{- end -}}