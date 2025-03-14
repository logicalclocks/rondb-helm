# Backups

## Background info

- Backup Pod cannot be guaranteed access to volumes of data nodes (volumes can have ReadWriteOnce, depending on cloud)
- Native RonDB backups are performed on every replica of a node group
- Writing a backup directly into object storage is a bad idea; S3 has no append option; it would do unnecessarily many writes
- CSI storage drivers are neat, but less transparent and thereby tricky to handle

## Backup structure

Backups are stored with the following file structure. `backup-id` is a 32-bit uint, used by RonDB natively.

```bash
<backup-id>
    users.sql  # MySQL user metadata
    databases.sql  # MySQL table metadata (including procedures & views)
    rondb  # Native RonDB data backup
        <datanode-node-id>
            BACKUP-<backup-id>-PART-1-OF-2/
            BACKUP-<backup-id>-PART-2-OF-2/
        <datanode-node-id>
            BACKUP-<backup-id>-PART-1-OF-2/
            BACKUP-<backup-id>-PART-2-OF-2/
        ...
```

The SQL files are generated by the MySQL servers whilst the native backups are created by the data nodes. The latter is triggered by the RonDB management client. The SQL files are not strictly necessary to restore the backup but can be helpful in the event of bugs. Also, the native backup does not contain MySQL views and procedures.

## Adding support for a new object storage

We use `rclone` to upload backups to object storage. `Rclone` is installed in the `hopsworks/hwutils` image and it works for many different object storages, including OVH. To add support for a new object storage type, you need to add a configuration setting to rclone. For S3, this can look as follows:

```yaml
[myS3Remote]
type = s3
provider = AWS

# If using a credentials Secret:
access_key_id = blabla
secret_access_key = foofoo

# If using IAM roles (and running in cloud K8s):
env_auth = true
```

An easy way of creating this file is to run `docker run --rm -it --entrypoint=/bin/sh rclone/rclone:latest` which will open a terminal in a rclone image. There you can run:

```bash
# This will open an interactive process where you can specify your object storage 
rclone config
# After this is done, run this to see where your config file is placed
rclone config file
```

## MySQL Users

MySQL users are backed up, but their passwords can optionally be overwritten on
cluster startup. This is **not** recommended for Global Replication with
active-passive + fail-over or active-active.

Reasoning:
- It is technically possible to exclude users from backups, but not from Global Replication
  - In Global Replication, one can only exclude databases or tables
- A cluster can be made a secondary cluster on Helm upgrade. The only difference is that
  it will start its replica appliers. At that point, it will have run all of its MySQL init
  scripts.
- If we ALTER password of a user in cluster B, this will propagate back to cluster A
  in active-active. Cluster A will lose access to this user then.
- If we restore a backup cluster for Global Replication, one can place existing MySQL
  passwords into Secrets themselves and pass that to values.yaml

## Testing backup/restore

1. Edit ./test_scripts/minio.env if needed
2. Run these scripts; will test backup/restore:
    ```bash
    ./test_scripts/setup_minio.sh
    ./test_scripts/test_backup_restore.sh
    ```
3. Clean up MinIO:
    ```bash
    helm delete tenant -n $MINIO_TENANT_NAMESPACE
    kubectl delete namespace $MINIO_TENANT_NAMESPACE
    ```
