# Helmchart RonDB

## Capabilities

- Create custom-size, cross-AZ cluster
- Horizontal auto-scaling of MySQLds & RDRS'
- Scale data node replicas
- Create backups & restore from backups

## Backups

See [Backups](docs/backups.md) for this.

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
# - TLS Ingress/endToEnd is enabled in values
# - We are running standalone (without Hopsworks)
./setup_standalone_tls_dependencies.sh $RONDB_NAMESPACE

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
kubectl delete namespace $RONDB_NAMESPACE

# Remove cert-manager
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.3/cert-manager.yaml

# Remove PVCs manually
kubectl delete pvc --all
```

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

## Startup steps (including restoring backup)

Currently, we are running the following steps:

1. Start Data node Stateful Set:
   1. InitContainer: Download native backups on data nodes
   2. Main container: Run data nodes
2. Create Job A to:
   1. Wait for data nodes to start up
   2. Create *temporary* MySQLd that connects to the data nodes and
        creates system tables (important!). Otherwise, system tables
        will be restored by native backup.
   3. Run `ndb_restore --restore-meta --disable-indexes` on one ndbmtd
   4. Run `ndb_restore --restore-data` on all ndbmtds
   5. Run `ndb_restore --rebuild-indexes` on one ndbmtd
   6. Remove native backups on all ndbmtds
3. Create Job B to (*always* run this Job):
   1. (If available): Download MySQL metadata backup
   2. (If available): Wait for Job A
   3. Spawn *temporary* MySQLd that:
      1. (If available): Restores MySQL metadata backup
      2. Applies user-applied SQL init files
4. Start MySQLd Stateful Set:
   1. InitContainer: Initialize MySQLd data dir (no connection needed)
   2. Wait for Job B
   3. Main container: Run MySQLds with networking
