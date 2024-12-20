{{- define "rondb.rcloneRestoreRemoteName" -}}
restoreRemote
{{- end -}}

{{- define "rondb.rcloneBackupRemoteName" -}}
backupRemote
{{- end -}}

{{- define "rondb.mgmdHostname" -}}
{{ printf "%s-0.%s.%s.svc.cluster.local"
        $.Values.meta.mgmd.statefulSetName
        $.Values.meta.mgmd.headlessClusterIp.name
        $.Release.Namespace
}}
{{- end -}}

{{- define "rondb.mysqldPodname" -}}
{{ printf "%s-0" $.Values.meta.mysqld.statefulSet.name }}
{{- end -}}

{{- define "rondb.mysqldServiceHostname" -}}
{{ printf "%s.%s.svc.cluster.local"
        $.Values.meta.mysqld.clusterIp.name
        $.Release.Namespace
}}
{{- end -}}

{{- define "rondb.rdrsServiceHostname" -}}
{{ printf "%s.%s.svc.cluster.local"
        $.Values.meta.rdrs.clusterIp.name
        $.Release.Namespace
}}
{{- end -}}

{{- define "rondb.rawRCloneConf" -}}
/home/hopsworks/rclone-raw.conf
{{- end -}}

---

{{- define "rondb.restoreNativeBackupJobname" -}}
restore-native-backup
{{- end -}}

---

{{- define "rondb.dataDir" -}}
/srv/hops/mysql-cluster
{{- end -}}

###########################
# Ndbmtd data directories #
###########################

{{- define "rondb.ndbmtd.volumeSymlinkPrefix" -}}
/default_storage
{{- end -}}

{{- define "rondb.ndbmtd.volumeSymlink" -}}
{{ include "rondb.dataDir" $ }}{{ include "rondb.ndbmtd.volumeSymlinkPrefix" $ }}
{{- end -}}

########

{{- define "rondb.ndbmtd.dataDir" -}}
{{ include "rondb.dataDir" $ }}/log
{{- end -}}

{{- define "rondb.ndbmtd.fileSystemPath" -}}
{{ include "rondb.dataDir" $ }}/ndb_data
{{- end -}}

{{- define "rondb.ndbmtd.fileSystemPathDataFiles" -}}
{{ include "rondb.dataDir" $ }}/ndb_data_files
{{- end -}}

{{- define "rondb.ndbmtd.fileSystemPathUndoFiles" -}}
{{ include "rondb.dataDir" $ }}/ndb_undo_files
{{- end -}}

{{- define "rondb.ndbmtd.backupDataDir" -}}
{{ include "rondb.dataDir" $ }}/ndb/backups
{{- end -}}

##################
# Service Labels #
##################

{{- define "rondb.labels.rondbService.mgmd" -}}
mgmd
{{- end -}}

{{- define "rondb.labels.rondbService.ndbmtd" -}}
ndbmtd
{{- end -}}

{{- define "rondb.labels.rondbService.setup-mysqld" -}}
setup-mysqld
{{- end -}}

{{- define "rondb.labels.rondbService.mysqld" -}}
mysqld
{{- end -}}

{{- define "rondb.labels.rondbService.binlog-servers" -}}
binlog-server
{{- end -}}

{{- define "rondb.labels.rondbService.replica-appliers" -}}
replica-applier
{{- end -}}

{{- define "rondb.labels.rondbService.mysqld-exporter" -}}
mysqld-exporter
{{- end -}}

{{- define "rondb.labels.rondbService.rdrs" -}}
rdrs
{{- end -}}

{{- define "rondb.labels.rondbService.benchmark" -}}
benchmark
{{- end -}}

{{- define "rondb.labels.rondbService.create-backup" -}}
create-backup
{{- end -}}

{{- define "rondb.labels.rondbService.restore-backup" -}}
restore-backup
{{- end -}}

{{- define "rondb.labels.rondbService.all" -}}
- {{ include "rondb.labels.rondbService.mgmd" $ }}
- {{ include "rondb.labels.rondbService.ndbmtd" $ }}
- {{ include "rondb.labels.rondbService.setup-mysqld" $ }}
- {{ include "rondb.labels.rondbService.mysqld" $ }}
- {{ include "rondb.labels.rondbService.binlog-servers" $ }}
- {{ include "rondb.labels.rondbService.replica-appliers" $ }}
- {{ include "rondb.labels.rondbService.mysqld-exporter" $ }}
- {{ include "rondb.labels.rondbService.rdrs" $ }}
- {{ include "rondb.labels.rondbService.benchmark" $ }}
- {{ include "rondb.labels.rondbService.create-backup" $ }}
- {{ include "rondb.labels.rondbService.restore-backup" $ }}
{{- end -}}

#######
# TLS #
#######

{{- define "rondb.certManager.issuer" -}}
rondb-cert-issuer
{{- end -}}

{{- define "rondb.tls.rdrs.ingress.secretName" -}}
rdrs-ingress-tls
{{- end -}}
