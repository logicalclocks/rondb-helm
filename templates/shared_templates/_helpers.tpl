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
{{- if include "rondb.restoreFromBackup.backupId" $ }}
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

{{- define "rondb.backups.backupIdFile" -}}
/home/hopsworks/backup-id/id
{{- end -}}

# Backup Id format $(date +'%y%V%u%H%M')
# %y Last two digits of the year
# %V ISO week number (01–53)
# %u Day of the week (1 = Monday, 7 = Sunday)
# %H Hour (00–23)
# %M Minute (00–59)
{{- define "rondb.backups.defineBackupIdEnv" }}
BACKUP_FILE={{ include "rondb.backups.backupIdFile" . | quote}}
if [ -f "$BACKUP_FILE" ]; then
  BACKUP_ID=$(cat "$BACKUP_FILE")
  echo "Reusing existing backup ID: $BACKUP_ID"
else
  BACKUP_ID=$(date +'%y%V%u%H%M')
  echo "$BACKUP_ID" > "$BACKUP_FILE"
  echo "Generated new backup ID: $BACKUP_ID"
fi
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

{{- define "rondb.canUseLookupFunc" -}}
{{- if .mode -}}
{{- if eq .mode "auto" -}}
true
{{- end -}}
{{- else if and .global .global._hopsworks .global._hopsworks.mode -}}
{{- if eq .global._hopsworks.mode "auto" -}}
true
{{- end -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{- define "rondb.backup.credentials" -}}
{{- if or (eq .backupConfig.objectStorageProvider "s3") (include "rondb.global.managedObjectStorage.s3" .) (include "rondb.global.minio" .)}}
{{- $secretName := "" }}
{{- $key := "" }}
{{- if and .backupConfig.s3.keyCredentialsSecret.name .backupConfig.s3.keyCredentialsSecret.key }}
{{- $secretName = .backupConfig.s3.keyCredentialsSecret.name }}
{{- $key = .backupConfig.s3.keyCredentialsSecret.key  }}
{{- else if and (include "rondb.global.managedObjectStorage.s3" .) .global._hopsworks.managedObjectStorage.s3.secret .global._hopsworks.managedObjectStorage.s3.secret.name .global._hopsworks.managedObjectStorage.s3.secret.access_key_id}}
{{- $secretName = .global._hopsworks.managedObjectStorage.s3.secret.name }}
{{- $key = .global._hopsworks.managedObjectStorage.s3.secret.access_key_id }}
{{- end }}
{{- $setEnv := and $secretName $key }}
{{- if include "rondb.canUseLookupFunc" . }}
{{- $setEnv = and $setEnv (lookup "v1" "Secret" .namespace $secretName ) }}
{{- end }}
{{- if $setEnv }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $key }}
{{- else if include "rondb.global.minio" . }}
- name: AWS_ACCESS_KEY_ID
  value: {{ .global._hopsworks.minio.user }}
{{- end }}
{{- if and .backupConfig.s3.secretCredentialsSecret.name .backupConfig.s3.secretCredentialsSecret.key }}
{{- $secretName = .backupConfig.s3.secretCredentialsSecret.name }}
{{- $key = .backupConfig.s3.secretCredentialsSecret.key  }}
{{- else if and (include "rondb.global.managedObjectStorage.s3" .) .global._hopsworks.managedObjectStorage.s3.secret .global._hopsworks.managedObjectStorage.s3.secret.name .global._hopsworks.managedObjectStorage.s3.secret.secret_key_id}}
{{- $secretName = .global._hopsworks.managedObjectStorage.s3.secret.name }}
{{- $key = .global._hopsworks.managedObjectStorage.s3.secret.secret_key_id }}
{{- else if include "rondb.global.minio" . }}
{{- $secretName = "aws-credentials" }}
{{- $key = "secret-access-key" }}
{{- end }}
{{- $setEnv = and $secretName $key }}
{{- if include "rondb.canUseLookupFunc" . }}
{{- $setEnv = and $setEnv (lookup "v1" "Secret" .namespace $secretName ) }}
{{- end }}
{{- if $setEnv }}
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $key }}
{{- else if include "rondb.global.minio" . }}
- name: AWS_SECRET_ACCESS_KEY
  value: {{ .global._hopsworks.minio.password }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "rondb.global.managedObjectStorage" -}}
{{- if and .global .global._hopsworks .global._hopsworks.managedObjectStorage .global._hopsworks.managedObjectStorage.enabled -}}
true
{{- end -}}
{{- end -}}

{{- define "rondb.global.minio" -}}
{{- if and .global .global._hopsworks .global._hopsworks.minio .global._hopsworks.minio.enabled .global._hopsworks.minio.hopsfs .global._hopsworks.minio.hopsfs.enabled -}}
true
{{- end -}}
{{- end -}}

{{- define "rondb.global.managedObjectStorage.s3" -}}
{{- if and (include "rondb.global.managedObjectStorage" .) .global._hopsworks.managedObjectStorage.s3  -}}
true
{{- end -}}
{{- end -}}

{{- define "rondb.global.backupsEnabled" -}}
{{- if and ( or (include  "rondb.global.managedObjectStorage" (dict "global" .Values.global))  (include  "rondb.global.minio" (dict "global" .Values.global))) .Values.global._hopsworks.backups (hasKey .Values.global._hopsworks.backups "enabled" ) -}}
{{- if .Values.global._hopsworks.backups.enabled -}}
true
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "rondb.backups.isEnabled" -}}
{{- if hasKey .Values.backups "enabled" -}}
{{- if .Values.backups.enabled -}}
true
{{- end -}}
{{- else if include "rondb.global.backupsEnabled" . -}}
true
{{- end -}}
{{- end -}}

{{- define "rondb.backups.schedule" -}}
{{- if and .Values.backups.enabled .Values.backups.schedule -}}
{{- .Values.backups.schedule -}}
{{- else if and (include "rondb.global.backupsEnabled" .) .Values.global._hopsworks.backups.schedule -}}
{{- .Values.global._hopsworks.backups.schedule -}}
{{- else -}}
@weekly
{{- end -}}
{{- end -}}

# FIXME should be changed when supporting multiple storage backends
{{- define "rondb.backups.bucketName" -}}
{{- if .backupConfig.s3.bucketName -}}
{{- .backupConfig.s3.bucketName -}}
{{- else if and (include "rondb.global.managedObjectStorage.s3" .) .global._hopsworks.managedObjectStorage.s3.bucket.name -}}
{{- .global._hopsworks.managedObjectStorage.s3.bucket.name -}}
{{- else if and (include "rondb.global.minio" .) .global._hopsworks.minio.hopsfs.bucket -}}
{{- .global._hopsworks.minio.hopsfs.bucket -}}
{{- else -}}
{{- fail "Missing bucket name configuration for backups. Please specify the bucket name either in the Rondb subchart or under global._hopsworks.managedObjectStorage." }}
{{- end -}}
{{- end -}}


{{- define "rondb.rcloneConfig" -}}
{{- if include "rondb.global.minio" . }}
type = s3
env_auth = true
storage_class = STANDARD
region = {{ .global._hopsworks.minio.region }}
provider = Other
endpoint = http://minio.service.consul:9000
{{- else if or (eq .backupConfig.objectStorageProvider "s3") (include "rondb.global.managedObjectStorage.s3" .) }}
type = s3
env_auth = true
storage_class = STANDARD
{{- if .backupConfig.s3.provider }}
provider = {{ .backupConfig.s3.provider }}
{{- else if and .global .global._hopsworks (eq (upper .global._hopsworks.cloudProvider) "AWS")}}
provider = AWS
{{- else }}
provider = Other
{{- end }}
{{- if .backupConfig.s3.region }}
region = {{ .backupConfig.s3.region }}
{{- else if and (include "rondb.global.managedObjectStorage.s3" .) .global._hopsworks.managedObjectStorage.s3.region }}
region = {{ .global._hopsworks.managedObjectStorage.s3.region }}
{{- end }}
{{- if .backupConfig.s3.serverSideEncryption }}
server_side_encryption = {{ .backupConfig.s3.serverSideEncryption }}
{{- else if and (include "rondb.global.managedObjectStorage.s3" .) .global._hopsworks.managedObjectStorage.s3.serverSideEncryption }}
server_side_encryption = {{ .global._hopsworks.managedObjectStorage.s3.serverSideEncryption }}
{{- end }}
{{- if .backupConfig.s3.endpoint }}
endpoint = {{ .backupConfig.s3.endpoint }}
{{- else if and (include "rondb.global.managedObjectStorage.s3" .) .global._hopsworks.managedObjectStorage.s3.endpoint }}
endpoint = {{ .global._hopsworks.managedObjectStorage.s3.endpoint }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "rondb.restoreFromBackup.backupId" -}}
{{- if .Values.restoreFromBackup.backupId -}}
{{- .Values.restoreFromBackup.backupId  -}}
{{- else if and (include  "rondb.global.managedObjectStorage" (dict "global" .Values.global)) .Values.global._hopsworks.restoreFromBackup .Values.global._hopsworks.restoreFromBackup.backupId -}}
{{- .Values.global._hopsworks.restoreFromBackup.backupId -}}
{{- end -}}
{{- end -}}

{{- define "rondb.backups.metadataStore.configMapName" -}}
{{- if .Values.backups.metadataConfigmapName -}}
{{- .Values.backups.metadataConfigmapName  -}}
{{- else if and (include "rondb.global.backupsEnabled" .) .Values.global._hopsworks.backups.metadataStore.configMap.ronDB -}}
{{- .Values.global._hopsworks.backups.metadataStore.configMap.ronDB -}}
{{- end -}}
{{- end -}}

{{- define "rondb.backups.pathScheme" -}}
{{- if or (eq .Values.backups.objectStorageProvider "s3") (include "rondb.global.managedObjectStorage.s3" (dict "global" .Values.global)) (include "rondb.global.minio"  (dict "global" .Values.global)) -}}
{{- "s3:/" -}}
{{- end -}}
{{- end -}}

{{- define "rondb.backups.ttl" -}}
{{- if .Values.backups.ttl -}}
{{- .Values.backups.ttl  -}}
{{- else if and (include "rondb.global.backupsEnabled" .) .Values.global._hopsworks.backups.ttl -}}
{{- .Values.global._hopsworks.backups.ttl -}}
{{- end -}}
{{- end -}}
