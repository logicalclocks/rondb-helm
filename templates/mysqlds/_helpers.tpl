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

{{- define "rondb.container.waitSingleSetup" -}}
{{- if .Release.IsInstall }}
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
{{- if .Values.restoreFromBackup.backupId }}
    {{- $waitTimeoutMinutes := (add $waitTimeoutMinutes .Values.timeoutsMinutes.restoreNativeBackup) }}
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
{{ include "rondb.checkDnsResolvable" (dict
    "namespace" $.Release.Namespace
    "statefulSetName" .statefulSetName
    "headlessClusterIpName" .headlessClusterIpName
) | indent 6 }}
  env:
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
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
{{- if (required "Required to specify whether SELCT probe is for startup" .isStartup) }}
failureThreshold: 100
periodSeconds: 10
{{- else }}
failureThreshold: 4
periodSeconds: 5
{{- end }}
{{- end -}}

{{ define "rondb.mysqld.probes" -}}
startupProbe:
{{ include "rondb.mysqld.selectProbe" (dict "isStartup" true) | indent 2 }}
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
