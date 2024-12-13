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
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
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

{{ define "rondb.storageClass.diskColumns" -}}
{{ if .Values.resources.requests.storage.classes.diskColumns }}
storageClassName: {{ .Values.resources.requests.storage.classes.diskColumns | quote }}
{{- else }}
{{ include "rondb.storageClass.default" . }}
{{ end }}
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
      memory: 30Mi
{{- end }}
{{- end }}

{{- define "rondb.apiInitContainer" -}}
- name: cluster-dependency-check
  image: {{ include "image_address" (dict "image" .Values.images.rondb) }}
  imagePullPolicy: {{ $.Values.imagePullPolicy }}
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
