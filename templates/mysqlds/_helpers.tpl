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
