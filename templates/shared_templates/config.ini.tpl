{{ define "config_ndbd" -}}
[NDBD]
NodeId={{ .nodeId }}
NodeGroup={{ .nodeGroup }}
NodeActive={{ .isActive }}
HostName={{ .hostname }}
LocationDomainId=0
{{- end }}

{{ define "config_mysqld" -}}
[MYSQLD]
NodeId={{ .nodeId }}
LocationDomainId=0
NodeActive={{ .isActive }}
ArbitrationRank=2
HostName={{ .hostname }}
{{- end }}

{{ define "config_api" -}}
[API]
NodeId={{ .nodeId }}
LocationDomainId=0
NodeActive={{ .isActive }}
ArbitrationRank=2
HostName={{ .hostname }}
{{- end }}
