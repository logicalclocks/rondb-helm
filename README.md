# RonDB Helm chart

## About RonDB

[RonDB](https://docs.rondb.com) is a fork of MySQL NDB Cluster, one of the storage engines supported by the MySQL server. It is a distributed, shared-nothing storage engine with capabilities for:

- in-memory & on-disk columns
- up to 1 PiB storage
- online horizontal & vertical storage scaling
- online horizontal & vertical compute scaling (MySQL servers)

Being supported by the MySQL server, RonDB is inherently ACID compliant. In-memory data is regularly persisted to disk via a REDO log and checkpoints. RonDB is open-source, written in C++.

## Chart host

This Helmchart is hosted on [GitHub Pages](https://logicalclocks.github.io/rondb-helm/). See the `gh_pages` branch of this repository for the source code.

## Helm chart's capabilities

This Helm chart supports:

- Creating custom-size, cross-AZ cluster
- Scaling data node replicas
- Horizontal auto-scaling of MySQLds & RDRS'
- Backup & restore to and from object storage (e.g. S3)
- Global Replication (cross-cluster replication)

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

# Run this if:
# - We want to use the cert-manager for TLS certificates
# - RDRS Ingress is enabled
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

## Backups

See [Backups](docs/backups.md) for this.

## Global Replication

See [Global Replication](docs/global_replication.md) for this.

## RDRS probe port

RDRS answers `/0.1.0/ping` and `/0.1.0/health` on two ports:

- **4406**, the main REST port: shares the worker threads with data requests,
  so when a stalled data node blocks all workers these stop answering too.
- **4407** (`rdrs.probePort`, enabled by default): the same two endpoints
  from a dedicated thread that never runs data operations. `/ping` answers
  503 until the main port accepts connections and 200 from then on.
  **This port performs no authentication.** It is not published as a port
  of any Service or Ingress, but like any pod port it is reachable via pod
  IPs and the headless Service's DNS records; where isolation is required,
  enforce it with a NetworkPolicy.

The chart points the startup, liveness and readiness probes at the probe port,
which requires an RDRS image with `REST.ProbePort` support (releases **newer
than 25.10.18**; older images reject the unknown config keys at startup). For
pinned older images set `rdrs.probePort.enabled=false`: no probe keys are
emitted and all probes go back to 4406.

`rdrs.maxKeepaliveRequests` (default `0` = off) bounds the requests served on
one keep-alive connection to the main port, after which the connection is
closed gracefully. A Kubernetes Service balances per connection, so this lets
clients re-balance after a rolling restart; use a high value (1000) and only
where post-restart skew is observed. Requires releases **newer than 25.10.18**;
at `0` the key is not emitted.

`rdrs.uploadPath` (default `/tmp/rdrs-uploads`) is where RDRS buffers request
bodies larger than 64 KiB. The container's working directory is not writable,
so without it oversized bodies are silently read as empty. Requires releases
**newer than 25.10.19**; set it to the empty string for pinned older images.

## Termination grace periods

`terminationGracePeriodSeconds` is a per-component object:

```yaml
terminationGracePeriodSeconds:
  ndbmtds: 300   # min 30; add ~2 minutes per TB of data node memory
  mgmds: 30
  mysqlds: 30
  rdrs: 30
  binlogServers: 30
  replicaAppliers: 30
```

Every daemon stops on SIGTERM, so these are ceilings: a pod is removed as soon
as its processes have exited. The old integer form still validates (minimum
10) and keeps its old meaning: charts up to 25.10.20 applied it to the data
nodes only, every other pod ran with the Kubernetes default of 30s, and that is
what the integer still does. Setting only some keys of the object is fine, the
rest default.

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

## CI (GitHub Actions)

See [CI](docs/github_actions.md) for this.

## Internal startup

See [Internal startup steps](docs/internal_startup.md) for this.

## Releasing Helm chart

The Helm chart version is set in the Chart.yaml file under `version`. Helm requires semantic versioning for this, and appending text is allowed as well (e.g. `0.1.0-dev`).

Let's say our Chart.yaml now has version `0.1.0`. We have not released this version yet. The expected workflow will be as follows:
1. Commit arbitrary changes to main
2. Run one or more workflow dispatches to release the version `0.1.0-dev`. This can be referenced in other Helmcharts.
3. If the Helmchart version is deemed stable, one runs:
   1. `git tag v0.1.0` on the main branch (the same version as in the Chart.yaml, plus prepending a `v`)
   2. `git push origin tag v0.1.0`; this will trigger a Helm chart release with version `0.1.0`
4. Bump the version in the Chart.yaml to `0.1.1`

The released Helmchart will be visible on the `gh_pages` branch of this repository.

### Generating values.yaml file

We use the `values.schema.json` as a single source of truth. It is used to generate both the `values.yaml` file and the Markdown docs on [GitHub Pages](https://logicalclocks.github.io/rondb-helm/). **Publishing will fail** if the `values.yaml` file is not updated.

The docs are updated automatically, but run the following to update the `values.yaml` file:

```bash
python3 -m venv venv && source venv/bin/activate
pip3 install -r .github/requirements.txt
python3 .github/json_to_yaml.py
./.github/update_copyright.sh
```

## TODO

See [TODO](docs/todo.md) for this.
