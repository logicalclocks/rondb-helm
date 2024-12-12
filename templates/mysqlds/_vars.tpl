{{- define "rondb.mysqldDataDir" -}}
{{ include "rondb.dataDir" $ }}/mysql
{{- end -}}

{{/*
    For binlog servers, we place binlogs in a different directory for easier
    access. However, if deciding to persist binlog files, one must also persist
    the data directory. This is because the data directory contains the
    (local) ndb_binlog_index table which references the binlog files. The
    binlog files are useless if they are not referenced in this table.

    The data dir has to empty at startup - it cannot contain an
    empty binlog directory. Therefore, the data directory and the
    binlog directory must be separate. When persisting both of these,
    we use the parent directory of the two.    
*/}}

{{- define "rondb.mysqld.binlogServers.dataDir" -}}
{{ include "rondb.mysqldDataDir" $ }}/data
{{- end -}}

{{- define "rondb.mysqld.binlogServers.binlogDir" -}}
{{ include "rondb.mysqldDataDir" $ }}/binlogs
{{- end -}}

{{- define "rondb.mysqldRelayLogDir" -}}
{{ include "rondb.dataDir" $ }}/mysql-relay-logs
{{- end -}}

---

{{- define "rondb.helmSqlInitFile" -}}
helm-user-supplied.sql
{{- end -}}

---

{{- define "rondb.sqlInitScriptsDir" -}}
/srv/hops/docker/rondb_standalone/sql_init_scripts
{{- end -}}

{{- define "rondb.sqlRestoreScriptsDir" -}}
/srv/hops/docker/rondb_standalone/sql_init_scripts_restore
{{- end -}}

---

# A successful Pod can be removed; don't remove the successful Job itself though
{{- define "rondb.mysqldSetupJobName" -}}
setup-mysqld-dont-remove
{{- end -}}

{{- define "rondb.serviceAccount.restoreWatcher" -}}
restore-backup-watcher-sa
{{- end -}}

{{- define "rondb.role.restoreWatcher" -}}
restore-backup-watcher
{{- end -}}

{{- define "rondb.roleBinding.restoreWatcher" -}}
restore-backup-watcher-binding
{{- end -}}

---

{{- define "rondb.mysqldServiceAccountName" -}}
wait-init-jobs-sa
{{- end -}}

{{- define "rondb.mysqldRole" -}}
wait-init-jobs
{{- end -}}

{{- define "rondb.mysqldRoleBinding" -}}
wait-init-jobs-binding
{{- end -}}

---

# Easier to calculate serverIds with 100 per cluster
{{- define "rondb.maxTotalMySQLds" -}}
100
{{- end -}}
