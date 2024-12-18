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
enabled using `--set backups.enabled`. These will be placed into cloud object storage. Restoring from a backup
can be activated (at cluster start) using `--set restoreFromBackup.backupId=<backup-id>`. This will assume the
backup is placed in the defined object storage.

_Authentication info:_ When running Kubernetes within a cloud provider (e.g. EKS), authentication can work implicitly via IAM roles.
This is most secure and one should not have to worry about rotating them. If one is not running in the cloud
(e.g. Minikube or on-prem K8s clusters), one can create Secrets with object storage credentials.

Examples creating object storage:
* In-cluster MinIO: Install MinIO controller and run `./test_scripts/setup_minio.sh`
* S3: Create an S3 bucket and see this to have access to it: https://github.com/awslabs/mountpoint-s3-csi-driver/blob/main/docs/install.md#configure-access-to-s3.

### Run cluster

```bash
RONDB_NAMESPACE=rondb-default
kubectl create namespace $RONDB_NAMESPACE

# If periodical backups are enabled, add access to object storage.
# If using AWS S3 without IAM roles:
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

# If dependencies were set up first, take them down again
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
    ```bash
    mysqladmin -h rondb.com \
        --protocol=tcp \
        --connect-timeout=3 \
        --ssl-mode=REQUIRED \
        ping
    ```

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

## Internal startup

See [Internal startup steps](docs/internal_startup.md) for this.
