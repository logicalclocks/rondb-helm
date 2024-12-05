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

{{- define "rondb.SecurityContext" }}
{{- if $.Values.securityContext }}
securityContext: {{ $.Values.securityContext | toYaml | nindent 2 }}
{{- else }}
securityContext: {}
{{- end }}
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

{{- define "rondb.affinity.preferred.ndbdAZs" }}
# Try to place Pods into same AZs as data nodes for low latency
- weight: 90
  podAffinityTerm:
    topologyKey: topology.kubernetes.io/zone
    labelSelector:
      matchExpressions:
      - key: nodeGroup
        operator: In
        values:
{{- range $nodeGroup := until ($.Values.clusterSize.numNodeGroups | int) }}
        - {{ $nodeGroup | quote }}
{{ end }}
{{- end }}
