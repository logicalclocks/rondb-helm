# TODO

## Restore

### Problem stored database logic:

*Examples*: Routines (procedures and functions), triggers & views

These database objects are not replicated; hence they won't be restored properly by the Job. We would have to run the
MySQL restore for every single Pod startup. It might be risky though to restore everything *over and over again*.

Potential solutions:
- Split up database objects into separate SQL backup files
- Consider restoring database objects in separate Job at the end using LoadBalancer
- Consider replicating non-ndb-binlogs between MySQL servers of the same cluster

## Backups

- Remove `DROP TABLE` from backups (?)
- Test with OVH object storage
- Consider writing backup epoch to backup metadata.json (currently not being used)
  - Possible to output epoch as part of Backup Job?

## Global Replication

### Next steps

1. Add test for fail-overs
2. Allow only writing certain databases to the binlog
3. Create Stateful Set per cluster we are replicating from
4. Look into implementing multiple replica appliers
   1. Replication channel cutover only happens if replica applier server dies
   2. Have multiple replica appliers running but use Lease/Mutex, so only one replicates
5. Consider placing binlog servers behind a LoadBalancer (might not work)
6. Fix error with multiple binlog files at startup
7. Add API for users (e.g. hopsworksroot)
8. Consider disabling running user-defined init scripts (and relying on replication)

### Query heartbeat table

Run this SQL from the replica applier:
```sql
-- Liveness probe on replica applier can check how long ago HB was run
-- Time stays relative to the binlog server
SELECT id, 
       TIMESTAMPDIFF(SECOND, updated_at, NOW()) AS seconds_since_update
FROM your_table_name;
```

### Setup active-active without conflict detection

One may want to have active-active replication for quicker fail-overs. However,
if conflict detection is not in place, one may risk conflicts.

- Can disallow *writing* in MySQLds with:
  - `SET GLOBAL read_only = ON;` and
  - `GRANT SUPER, REPLICATION SLAVE ON *.* TO 'replication_user'@'host';`

### Avoiding running out of binlogs

- Spin up another binlog server (do this early enough)
- DON'T KILL the primary binlog server
  - Just wait for command to remove binlogs

### Error handling

Handle:
- Binlogs run out
  - Idea: Try finding LOST_EVENTS programmatically (try `mysqlbinlog` program)

### Purging binlogs

How do we signal the binlog servers to purge their binlogs?

Idea:
- The primary cluster always knows about the secondary cluster
  - Otherwise, if it doesn't know about it, it becomes difficult for it to
    decide when to purge its binlogs (especially if it isn't even actively replicating)

Idea for active-active:
- Create entry in Heartbeat table PER server_id. Each MySQL replication server can then
    write its applied epoch into this HB table. Every MySQLd can then regularly look
    into this table, and hence decide which binlogs it can purge.

### Debugging binlog files

Commands:
- mysqlbinlog mysql-cluster/mysql-binlogs/binlog.0000* | grep "LOST"
- mysql -uroot -p$MYSQL_ROOT_PASSWORD
- SELECT * from ndb_binlog_index;
- SHOW MASTER STATUS;
- ls -l /srv/hops/mysql-cluster/mysql/binlog*
- PURGE BINARY LOGS TO binlog.000003;
- SHOW BINARY LOGS;
- SELECT @file:=SUBSTRING_INDEX(next_file, '/', -1),
    @pos:=next_position
    FROM mysql.ndb_binlog_index
    ORDER BY epoch DESC LIMIT 1;

## Other

- Operator: Add REDO log & UNDO log usage to CRD status
- Create more values.yaml files for production settings
- Make data node memory changeable
- Add YCSB to benchmark options
- Figure out how to run `SELECT count(*) FROM ndbinfo.nodes` as MySQL readiness check.
  - Using  `--defaults-file=$RONDB_DATA_DIR/my.cnf` and `GRANT SELECT ON ndbinfo.nodes TO 'hopsworks'@'%';` does not work
  - Error: `ERROR 1356 (HY000): View 'ndbinfo.nodes' references invalid table(s) or column(s) or function(s) or definer/invoker of view lack rights to use them`

Kubernetes Jobs to add:
- Increasing logfile group sizes
