{{- define "rdrs.gomaxprocs" -}}
{{- $cpu := .Values.rdrs.internal.gomaxprocs -}}
{{- if not $cpu -}}
    {{- $cpu = .Values.resources.limits.cpus.rdrs -}}
    {{- if lt $cpu 1.0 -}}
        {{- $cpu = 1 -}}
    {{- end -}}
{{- end -}}
{{- $cpu | int -}}
{{- end -}}