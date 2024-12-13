# Helmchart RonDB

## Capabilities

- Create custom-size, cross-AZ cluster
- Horizontal auto-scaling of MySQLds & RDRS'
- Scale data node replicas
- Create backups & restore from backups
- Global Replication

## Backups

See [Backups](docs/backups.md) for this.

## CI (GitHub Actions)

See [CI](docs/github_actions.md) for this.

## TODO

See [TODO](docs/todo.md) for this.

## Quickstart

### Optional: Set up cloud object storage for backups

Cloud object storage is required for creating backups and restoring from them. Periodical backups can be
enabled using `--set backups.enabled`. These will be placed into cloud object storage.

_Authentication info:_ When running Kubernetes within a cloud provider (e.g. EKS), authentication can work implicitly via IAM roles.
This is most secure and one should not have to worry about rotating them. If one is not running in the cloud
(e.g. Minikube or on-prem K8s clusters), one can create Secrets with object storage credentials.

_Example S3_: Create an S3 bucket and see this to have access to it: https://github.com/awslabs/mountpoint-s3-csi-driver/blob/main/docs/install.md#configure-access-to-s3.

### Run cluster

```bash
helm lint
helm template .

RONDB_NAMESPACE=rondb-default
kubectl create namespace $RONDB_NAMESPACE

# If periodical backups are enabled, add access to object storage.
# If using AWS S3:
kubectl create secret generic aws-credentials \
    --namespace=$RONDB_NAMESPACE \
    --from-literal "key_id=${AWS_ACCESS_KEY_ID}" \
    --from-literal "access_key=${AWS_SECRET_ACCESS_KEY}"

# Run this if both:
# - We want to use the cert-manager for TLS certificates
# - [RDRS Ingress is enabled] OR [Any TLS is enabled]
source ./standalone_deps.sh
setup_deps $RONDB_NAMESPACE

# Install and/or upgrade:
helm upgrade -i my-rondb \
    --namespace=$RONDB_NAMESPACE \
    --values ./values/minikube/small.yaml .
```

## Run tests

As soon as the Helmchart has been instantiated, we can run the following tests:

```bash
# Create some dummy data
helm test -n $RONDB_NAMESPACE my-rondb --logs --filter name=generate-data

# Check that data has been created correctly
helm test -n $RONDB_NAMESPACE my-rondb --logs --filter name=verify-data
```

***NOTE***: These Helm tests can also be used to verify that the backup/restore procedure was done correctly.

## Run benchmarks

See [Benchmarks](docs/benchmarks.md) for this.

## Teardown

```bash
helm delete --namespace=$RONDB_NAMESPACE my-rondb

# Remove other related resources (non-namespaced objects not removed here e.g. PriorityClass)
kubectl delete namespace $RONDB_NAMESPACE --timeout=60s

source ./standalone_deps.sh
destroy_deps
```

## Global Replication

See [Global Replication](docs/global_replication.md) for this.

## Test Ingress with Minikube

Ingress towards MySQLds or RDRSs can be tested using the following steps:

1. Run `minikube addons enable ingress`
2. Run `minikube tunnel`
3. Place `127.0.0.1 rondb.com` in your /etc/hosts file
4. Connect to RDRS from host:
    `curl -i --insecure https://rondb.com/0.1.0/ping`
    This should reach the RDRS and return 200.
5. Connect to MySQLd from host (needs MySQL client installed):
    mysqladmin -h rondb.com \
        --protocol=tcp \
        --connect-timeout=3 \
        --ssl-mode=REQUIRED \
        ping

## Optimizations

Data nodes strongly profit from being able to lock CPUs. This is possible with the
static CPU manager policy. In the case of Minikube, one can start it as follows:

```bash
minikube start \
    --driver=docker \
    --cpus=10 \
    --memory=21000MB \
    --feature-gates="CPUManager=true" \
    --extra-config=kubelet.cpu-manager-policy="static" \
    --extra-config=kubelet.cpu-manager-policy-options="full-pcpus-only=true" \
    --extra-config=kubelet.kube-reserved="cpu=500m"
```

Then in the values file, set `.Values.staticCpuManagerPolicy=true`.

## Startup steps (including restoring backup & global replication)

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
