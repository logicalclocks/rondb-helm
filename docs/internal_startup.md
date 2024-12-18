# Internal startup steps (including restoring backup & global replication)

Currently, we are running the following steps:

1. **Stateful Set** - Run data nodes:
   1. (If restoring) InitContainer: Download native backups on data nodes (TODO: Do this in Job A)
   2. Main container: Run data nodes
2. (If restoring) **Job A** - Restore binary data:
   1. Wait for data nodes to start up
   2. Create *temporary* MySQLd that connects to the data nodes and
        creates system tables (important!). Otherwise, system tables
        will be restored by native backup.
   3. TODO: Download native backups on data nodes here instead
   4. Run `ndb_restore --restore-meta --disable-indexes` on one ndbmtd
   5. Run `ndb_restore --restore-data` on all ndbmtds
   6. Run `ndb_restore --rebuild-indexes` on one ndbmtd
   7. (If global secondary cluster) Run `ndb_restore --restore-epoch` on one ndbmtd
   8. Remove native backups on all ndbmtds
3. (If global primary cluster) **Stateful Set** - Run MySQL binlog servers:
   1. InitContainer: Initialize MySQLd data dir (no connection needed)
   2. Wait for data nodes to start up
   3. (If restoring) Wait for Job A
   4. Main container: Run MySQLd replication servers with networking
       - Allow listening to the restore of a backup
4.  **Job B** - Initialize MySQLds:
    1. (If restoring) Download MySQL metadata backup
    2. Wait for data nodes to start up
    3. (If restoring) Wait for Job A
    4. (If global primary cluster) Wait for binlog servers
    5. Spawn *temporary* MySQLd that:
       1. (If restoring) Restores MySQL metadata backup
       2. Applies Helm deployment SQL init files
       3. Applies user-applied SQL init files
5. (If global secondary cluster) **Stateful Set** - Run MySQL replica applier
   1. InitContainer: Initialize MySQLd data dir (no connection needed)
   2. Wait for Job B
   3. Main containers:
      * MySQLd
      * Replication operator; script to choose binlog server & start/stop replication
6. **Stateful Set** - Run MySQL servers:
   1. InitContainer: Initialize MySQLd data dir (no connection needed)
   2. Wait for Job B
   3. Main container: Run MySQLds with networking

*Note:* Global primary and secondary cluster refer to global replication. This is asynchronous
replication between MySQL replication servers of two clusters. MySQL binlog servers in the
primary cluster replicate towards the MySQL replica appliers in the secondary cluster.
