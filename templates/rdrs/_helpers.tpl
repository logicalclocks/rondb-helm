{{- define "rdrs.gomaxprocs" -}}
{{- $cpu := .Values.resources.limits.cpus.rdrs -}}
{{- if lt $cpu 1.0 -}}
{{- $cpu = 1 -}}
{{- end -}}
{{- $cpu | int -}}
{{- end -}}