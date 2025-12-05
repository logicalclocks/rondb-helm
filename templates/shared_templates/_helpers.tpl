{{- define "rondb.imagePullSecrets" -}}
{{- if $.Values.imagePullSecrets }}
imagePullSecrets:
{{- range $.Values.imagePullSecrets }}
  - name: {{ .name }}
{{- end }}
{{- end }}
{{- end }}

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

{{- define "rondb.PodSecurityContext" }}
{{- if $.Values.enableSecurityContext }}
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault
{{- end }}
{{- end }}

{{- define "rondb.ContainerSecurityContext" }}
{{- if $.Values.enableSecurityContext }}
securityContext:
  allowPrivilegeEscalation: false
  privileged: false
  capabilities:
    drop:
      - ALL
{{- if .addSysNice }}
    add:
      - SYS_NICE
{{- end }}
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: null
  seccompProfile:
    type: RuntimeDefault
{{- end }}
{{- end }}

{{- define "rondb.nodeSelector" -}}
{{- if and .nodeSelector (not (empty .nodeSelector) )}}
nodeSelector: {{ .nodeSelector | toYaml | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "rondb.tolerations" -}}
{{- if and .tolerations (not (empty .tolerations) )}}
tolerations: {{ .tolerations | toYaml | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "rondb.serviceAccountAnnotations" -}}
{{- if $.Values.serviceAccountAnnotations }}
annotations: {{ $.Values.serviceAccountAnnotations | toYaml | nindent 2 }}
{{- end }}
{{- end -}}

{{ define "rondb.storageClass.default" -}}
{{ if .Values.resources.requests.storage.classes.default  }}
storageClassName: {{ .Values.resources.requests.storage.classes.default | quote }}
{{ end }}
{{- end }}

{{ define "rondb.storageClass.mgmd" -}}
{{ if .Values.resources.requests.storage.classes.mgmd }}
storageClassName: {{ .Values.resources.requests.storage.classes.mgmd | quote }}
{{- else }}
{{ include "rondb.storageClass.default" . }}
{{ end }}
{{- end }}

{{ define "rondb.storageClass.diskColumns" -}}
{{ if .Values.resources.requests.storage.classes.diskColumns }}
storageClassName: {{ .Values.resources.requests.storage.classes.diskColumns | quote }}
{{- else }}
{{ include "rondb.storageClass.default" . }}
{{ end }}
{{- end }}

{{ define "rondb.ndbmtd.storageSize" -}}
{{- $ := .root }}
{{- if include "rondb.isInstall" $ }}
{{- $memoryGiB := div $.Values.resources.limits.memory.ndbmtdsMiB 1024 | int }}
{{- $requiredStorage := add 
    (mul $memoryGiB 2.25)
    $.Values.resources.requests.storage.redoLogGiB
    (mul $.Values.resources.requests.storage.undoLogsGiB 2)
    $.Values.resources.requests.storage.logGiB
}}
{{- if not $.Values.resources.requests.storage.classes.diskColumns }}
{{- $requiredStorage := add
  $requiredStorage
  $.Values.resources.requests.storage.diskColumnGiB
}}
{{- end }}
{{- if gt $requiredStorage (int $.Values.resources.requests.storage.ndbmtdGiB) }}
# Validate that the requested storage is enough for the different components
{{ fail (printf "The requested storage size %dGiB is not enough for the ndbmtds. Required: %dGiB" (int $.Values.resources.requests.storage.ndbmtdGiB) $requiredStorage) }}
{{- end }}
  storage: {{ $.Values.resources.requests.storage.ndbmtdGiB | int }}Gi
{{- else }}
{{- $statefulSetName := printf "node-group-%d" .nodeGroup }}
{{- $sts := lookup "apps/v1" "StatefulSet" $.Release.Namespace $statefulSetName }}
{{- if $sts }}
{{- $claim := index $sts.spec.volumeClaimTemplates 0 }}
{{- $size := $claim.spec.resources.requests.storage }}
  storage: {{ $size }} # In case of an upgrade use the existing value
{{- else }}
  # Fallback to the value set via values.yaml 
  storage: {{ $.Values.resources.requests.storage.ndbmtdGiB | int }}Gi
{{- end }}
{{- end }}
{{- end }}

{{ define "rondb.storageClass.binlogs" -}}
{{ if .Values.resources.requests.storage.classes.binlogFiles }}
storageClassName: {{ .Values.resources.requests.storage.classes.binlogFiles | quote }}
{{- else }}
{{ include "rondb.storageClass.default" . }}
{{ end }}
{{- end }}

{{- define "rondb.container.waitDatanodes" -}}
- name: wait-datanodes-dependency
  image: {{ include "image_address" (dict "image" .Values.images.rondb) }}
{{ include "rondb.ContainerSecurityContext" $ | indent 2 }}
  imagePullPolicy: {{ $.Values.imagePullPolicy }}
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

{{- define "rondb.container.waitManagement" -}}
- name: wait-management-dependency
  image: {{ include "image_address" (dict "image" .Values.images.rondb) }}
{{ include "rondb.ContainerSecurityContext" $ | indent 2 }}
  imagePullPolicy: {{ $.Values.imagePullPolicy }}
  command:
  - /bin/bash
  - -c
  - |
{{ tpl (.Files.Get "files/scripts/wait_mgmd.sh") . | indent 4 }}
  env:
  - name: MGMD_HOSTNAME
    value: {{ include "rondb.mgmdHostname" . }}
  resources:
    limits:
      cpu: 0.3
      memory: 100Mi
{{- end }}

{{- define "rondb.container.waitRestore" -}}
{{- if $.Values.restoreFromBackup.backupId }}
- name: wait-restore-backup
  image: {{ include "image_address" (dict "image" $.Values.images.toolbox) }}
  imagePullPolicy: {{ $.Values.imagePullPolicy }}
  command:
  - /bin/bash
  - -c
  - |
    echo "Waiting for restore-backup Job to have completed"
    set -e

    (set -x; kubectl wait \
      -n {{ .Release.Namespace }} \
      --for=condition=complete \
      --timeout={{ .Values.timeoutsMinutes.restoreNativeBackup }}m \
      job/{{ include "rondb.restoreNativeBackupJobname" . }})          

    echo "Restore Job has completed successfully"
  resources:
    limits:
      cpu: 0.3
      memory: 100Mi
{{- end }}
{{- end }}

{{- define "rondb.apiInitContainer" -}}
- name: cluster-dependency-check
  image: {{ include "image_address" (dict "image" .Values.images.rondb) }}
  imagePullPolicy: {{ $.Values.imagePullPolicy }}
{{ include "rondb.ContainerSecurityContext" $ | indent 2 }}
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
  - name: MYSQL_CLUSTER_USER
    value: {{ .Values.mysql.clusterUser }}
  - name: MYSQL_CLUSTER_PASSWORD
    valueFrom:
      secretKeyRef:
        key: {{ .Values.mysql.clusterUser }}
        name: {{ $.Values.mysql.credentialsSecretName }}
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


# Previously JOB_NUMBER=$(echo $JOB_NAME | tr -d '[[:alpha:]]' | tr -d '-' | sed 's/^0*//' | cut -c -9)
# However, sometimes, the JOB_NAME would not contain an integer
# Now, we hash the JOB_NAME, remove alphabets and take the first 5 characters
# echo -n "$JOB_NAME" | sha1sum                     # Hash
# echo -n "$JOB_NAME" | ... | cut -d ' ' -f 1       # Remove appended whitespace
# echo -n "$JOB_NAME" | ... | xxd -p                # Hexadecimal hash
# echo -n "$JOB_NAME" | ... | tr -d '\n'            # Remove newline
# echo -n "$JOB_NAME" | ... | tr -d '[[:alpha:]]'   # Remove alphabets
# echo -n "$JOB_NAME" | ... | sed 's/^0*//'         # Remove appended zeroes
# echo -n "$JOB_NAME" | ... | cut -c 1-5            # Truncate to 5 characters
{{- define "rondb.backups.defineJobNumberEnv" }}
JOB_NUMBER=$(echo -n "$JOB_NAME" | sha1sum | cut -d ' ' -f 1 | tr -d '\n' | tr -d '[[:alpha:]]' | sed 's/^0*//' | cut -c 1-5)
if [ -z "$JOB_NUMBER" ]; then
    echo "JOB_NUMBER is not set"
    exit 1
fi
echo "Job number: $JOB_NUMBER"
{{- end }}

{{- define "rondb.certManager.certificate.endToEnd" }}
{{- if and 
    .endToEndTls.enabled 
    (not .endToEndTls.supplyOwnSecret)
}}
# Certificates will prompt the cert-manager to create a TLS Secret using the referenced
# Issuer.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ required "A Certificate must specify a name" .certName }}
  namespace: {{ $.Release.Namespace }}
spec:
  secretName: {{ .endToEndTls.secretName }}
  duration: 2160h # 90d
  renewBefore: 360h # 15d
  dnsNames:
{{ required "A Certificate must contain dnsNames" .dnsNames | toYaml | indent 4 }}
  issuerRef:
    name: {{ include "rondb.certManager.issuer" $ }}
    kind: Issuer
---
{{ end }}
{{- end }}

# This is an easy way to trigger rolling restarts of all RonDB Pods
{{- define "rondb.configIniHash" -}}
{{ mustRegexReplaceAll "NodeActive *=.*" (tpl ($.Files.Get "files/configs/config.ini") $) "" | sha256sum }}
{{- end -}}

# MaxDMLOperationsPerTransaction cannot exceed MaxNoOfConcurrentOperations
{{- define "rondb.validatedMaxDMLOperationsPerTransaction" -}}
{{- $dml := (.Values.rondbConfig.MaxDMLOperationsPerTransaction | default 32768) | int -}}
{{- $conc := (.Values.rondbConfig.MaxNoOfConcurrentOperations | default 65536) | int -}}
{{- if le $dml $conc }}
{{- $dml -}}
{{- end -}}
{{- end -}}

{{- define "rondb.isAWS" -}}
{{- if and .Values.global .Values.global._hopsworks (eq (upper .Values.global._hopsworks.cloudProvider) "AWS") -}}
true
{{- end -}}
{{- end -}}

{{- define "rondb.isExternallyManaged" -}}
{{- if and .Values.global .Values.global._hopsworks.externalServices .Values.global._hopsworks.externalServices.rondb .Values.global._hopsworks.externalServices.rondb.external -}}
true
{{- end -}}
{{- end -}}

{{- define "rondb.isInstall" -}}
{{- if .Values.mode -}}
{{- if eq .Values.mode "install" -}}
true
{{- else if and (eq .Values.mode "auto") .Release.IsInstall -}}
true
{{- end -}}
{{- else if and .Values.global  .Values.global._hopsworks .Values.global._hopsworks.mode -}}
{{- if eq .Values.global._hopsworks.mode "install" -}}
true
{{- else if and (eq .Values.global._hopsworks.mode "auto") .Release.IsInstall -}}
true
{{- end -}}
{{- else -}}
{{- if .Release.IsInstall -}}
true
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "rondb.isUpgrade" -}}
{{- if .Values.mode -}}
{{- if eq .Values.mode "upgrade" -}}
true
{{- else if and (eq .Values.mode "auto") .Release.IsUpgrade -}}
true
{{- end -}}
{{- else if and .Values.global  .Values.global._hopsworks .Values.global._hopsworks.mode -}}
{{- if eq .Values.global._hopsworks.mode "upgrade" -}}
true
{{- else if and (eq .Values.global._hopsworks.mode "auto") .Release.IsUpgrade -}}
true
{{- end -}}
{{- else -}}
{{- if .Release.IsUpgrade -}}
true
{{- end -}}
{{- end -}}
{{- end -}}