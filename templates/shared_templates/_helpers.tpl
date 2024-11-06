# Could be that there is no repository (e.g. docker.io/alpine)
{{- define "image_repository" -}}
{{- if or (not .image.repository) (eq .image.repository "") -}}
{{- else -}}
{{ .image.repository }}/
{{- end -}}
{{- end -}}

{{- define "image_address" -}}
{{ .image.registry }}/{{ include "image_repository" (dict "image" .image ) }}{{ .image.name }}:{{ .image.tag }}
{{- end -}}

{{- define "rondb.toolboxImage" -}}
{{- if and .Values.global .Values.global._hopsworks .Values.global._hopsworks.toolbox }}
{{- include "hopsworkslib.toolboxImage" (dict "Values" .Values "default" .default) }}
{{- else -}}
{{ include "image_address" (dict "image" .Values.images.toolbox) }}
{{- end -}}
{{- end -}}

{{- define "rondb.SecurityContext" }}
{{- if include "hopsworkslib.securityContextEnabled" . }}
# This corresponds to the MySQL user/group which is created in the Dockerfile
# Beware that a lot of files & directories are created in the RonDB Dockerfile, which belong
# to the MySQL user/group.
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
{{- end -}}
{{- end }}

{{ define "rondb.storageClass.default" -}}
{{ if .Values.resources.requests.storage.classes.default  }}
storageClassName: {{ .Values.resources.requests.storage.classes.default | quote }}
{{- else if and .Values.global .Values.global._hopsworks .Values.global._hopsworks.storageClassName }}
storageClassName: {{  .Values.global._hopsworks.storageClassName | quote }}
{{ end }}
{{- end }}

{{ define "rondb.storageClass.diskColumns" -}}
{{ if .Values.resources.requests.storage.classes.diskColumns }}
storageClassName: {{ .Values.resources.requests.storage.classes.diskColumns | quote }}
{{- else }}
{{ include "rondb.storageClass.default" . }}
{{ end }}
{{- end }}

{{- define "rondb.waitDatanodes" -}}
- name: wait-datanodes-dependency
  image: {{ include "image_address" (dict "image" .Values.images.rondb) }}
  {{ include "hopsworkslib.commonContainerSecurityContext" . | nindent 2 }}
  imagePullPolicy: {{ include "hopsworkslib.imagePullPolicy" . | default "IfNotPresent" }}
  command:
  - /bin/bash
  - -c
  - |
{{ tpl (.Files.Get "files/scripts/wait_ndbmtds.sh") . | indent 4 }}
  env:
  - name: MGMD_HOSTNAME
    value: {{ include "rondb.mgmdHostname" . }}
  resources:
    limits:
      cpu: 0.3
      memory: 100Mi
{{- end }}

{{- define "rondb.apiInitContainer" -}}
- name: cluster-dependency-check
  image: {{ include "image_address" (dict "image" .Values.images.rondb) }}
  imagePullPolicy: {{ include "hopsworkslib.imagePullPolicy" . | default "IfNotPresent" }}
  command:
  - /bin/bash
  - -c
  - |
{{ tpl (.Files.Get "files/scripts/apis.sh") . | indent 4 }}
  env:
  - name: MGMD_HOSTNAME
    value: {{ include "rondb.mgmdHostname" . }}
  - name: MYSQLD_SERVICE_HOSTNAME
    value: {{ include "rondb.mysqldServiceHostname" . }}
  - name: MYSQL_BENCH_USER
    value: {{ .Values.benchmarking.mysqlUsername }}
  - name: MYSQL_BENCH_PASSWORD
    valueFrom:
      secretKeyRef:
        key: {{ .Values.benchmarking.mysqlUsername }}
        name: {{ include "rondb.mysql.usersSecretName" . }}
{{- end }}

{{- define "rondb.arrayToCsv" -}}
{{- if .array }}
{{- $length := len .array -}}
{{- range $index, $element := .array -}}
{{- $element }}{{- if lt $index (sub $length 1) }},{{ end -}}
{{- end }}
{{- end }}
{{- end }}

{{- define "rondb.takeBackupPathPrefix" }}
{{- .Values.backups.pathPrefix | default "rondb_backup" }}
{{- end }}

{{- define "rondb.restoreBackupPathPrefix" }}
{{- .Values.restoreFromBackup.pathPrefix | default "rondb_backup" }}
{{- end }}
