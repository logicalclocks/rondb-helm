{{ define "config_ndbd" -}}
[NDBD]
NodeId={{ .nodeId }}
NodeGroup={{ .nodeGroup }}
NodeActive={{ .isActive }}
HostName={{ .hostname }}
{{- end }}

{{ define "config_mysqld" -}}
[MYSQLD]
NodeId={{ .nodeId }}
NodeActive={{ .isActive }}
ArbitrationRank=2
HostName={{ .hostname }}
{{- end }}

{{ define "config_api" -}}
[API]
NodeId={{ .nodeId }}
NodeActive={{ .isActive }}
ArbitrationRank=2
HostName={{ .hostname }}
{{- end }}
