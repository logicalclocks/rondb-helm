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

The commands in this README run from a clone of this repository. The helper scripts, example values files and
docs they use are not part of the packaged chart.

```bash
git clone --branch branch-26.02 https://github.com/logicalclocks/rondb-helm.git
cd rondb-helm
```

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
which requires an RDRS image with `REST.ProbePort` support (releases **26.02.11
and newer on the 26.02 line**; older images reject the unknown config keys at
startup). For pinned older images set `rdrs.probePort.enabled=false`: no probe
keys are emitted and all probes go back to 4406.

`rdrs.maxKeepaliveRequests` (default `0` = off) bounds the requests served on
one keep-alive connection to the main port, after which the connection is
closed gracefully. A Kubernetes Service balances per connection, so this lets
clients re-balance after a rolling restart; use a high value (1000) and only
where post-restart skew is observed. Requires releases **26.02.11 and newer on the 26.02 line**;
at `0` the key is not emitted.

`rdrs.uploadPath` (default `/tmp/rdrs-uploads`) is where RDRS buffers request
bodies larger than 64 KiB. The container's working directory is not writable,
so without it oversized bodies are silently read as empty. Requires releases
**26.02.11 and newer on the 26.02 line**; set it to the empty string for pinned older images.

## RDRS and transparent huge pages

On nodes with `/sys/kernel/mm/transparent_hugepage/enabled` set to `always`
(the RHEL default), the kernel's khugepaged collapses the sparse memory of an
idle RDRS (glibc arenas, thread stacks, request buffers) into resident 2 MiB
pages. The pod's memory usage climbs from about 300 MiB to its limit in a
quarter of an hour with no traffic, the probes time out and the kubelet
restarts it (exit 137, reason `Error`, not `OOMKilled`), indefinitely.

An RDRS with RONDB-1144 opts its own process out of THP at startup
(`prctl(PR_SET_THP_DISABLE)`); on nodes set to `madvise` or `never` that
changes nothing. `rdrs.internal.disableTransparentHugePages` (default `null`,
nothing rendered, RDRS default `true`) keeps it that way; `false` renders
`Internal.DisableTransparentHugePages: false`, which tells RDRS to allow THP
again. Leave it unset unless THP is wanted. Images before RONDB-1144 do not opt
out and reject that key, so with them leave it unset and set the nodes to
`madvise`.

## RDRS configuration

**Upgrading values from older charts.** Remove `rdrs.internal.bufferSize`,
`rdrs.internal.gomaxprocs` and `rdrs.internal.maxAllocatedBuffers` (under
`rondb.rondb.rdrs.internal` when installed through the Hopsworks chart) before
upgrading to a chart that pairs with RONDB-1144. They were settings of the old
Go REST server, and no chart release since 25.10.5 reads them, so removing
them changes nothing on a running cluster. This chart validates
`rdrs.internal` strictly, and `helm upgrade` fails with "at '/rdrs/internal':
additional properties ... not allowed", naming the keys still present (in no
fixed order); the cluster keeps running on its current release. The buffer
pool now sizes itself from the pod's memory limit. To tune it, use
`rdrs.internal.maxBuffers`, `preAllocatedBuffers` and `bufferPoolSharePercent`
below.

**Defaults that change with this chart and a RONDB-1144 image.** Nothing needs
editing for these, but a running cluster notices them:

- The RDRS memory request and limit default to 2 GiB per pod (the request was
  100 MiB). On a tight node pool, pods may not schedule until nodes are freed
  or `resources.requests.memory.rdrsMiB` is lowered. The profiles under
  `values/minikube/` and `values/ovh.yaml` keep 500 to 800 MiB on purpose, for
  small test machines; RDRS logs a warning below 2 GiB and runs with a smaller
  buffer pool. 2 GiB suits typical traffic. Workloads that read large batches
  (thousands of operations or feature vectors per request, wide rows, feature
  views with many feature groups) need a higher limit: one such batch can
  take most of a 2 GiB pod's buffer pool, and concurrent requests are then
  answered 503 until it completes. Raise `resources.limits.memory.rdrsMiB`
  (and the request) for them; the pool grows with the limit.
- A request body above 1 MiB is answered 413. That was already the effective
  limit (the HTTP server's default; the old 4 MiB setting was never reached),
  and it is now one setting: raise `rdrs.internal.maxHttpReqSize` if clients
  send larger bodies.
- A batch request with more than 4096 operations (for batch feature store
  requests: entries) is answered 413 (`maxOperationsPerBatchRequest`). 4096 is
  the batch size the Go REST server accepted. The 1 MiB body limit also bounds
  a batch: about 4000 batch pk-read operations of 250 bytes fit in one body.
- A BLOB or TEXT value larger than 2 MiB is not returned; its operation is
  answered 413 (`maxBlobTextValueBytes`, 0 = no limit).
- RDRS preallocates 128 buffer pairs (was 32) and returns idle buffers above
  that after 15 minutes (`preAllocatedBuffers`, `bufferShrinkAfterS`; the chart
  sets 900 seconds, RDRS's own default is 300).

Every `rdrs2` setting that the chart does not manage itself is a value under
`rdrs.*` (under `rondb.rondb.rdrs.*` when installed through the Hopsworks
chart), rendered into the pods' `rest_api.json` under its `rdrs2` key. The
rule for all of them: **a key is rendered only when set, and a section that
only carries such keys only when at least one of them is set.** An RDRS image
older than RONDB-1144 rejects config keys it does not know ("Unexpected key")
and does not start; newer images log a warning and ignore them. Leaving a key
`null` keeps every image starting with the RDRS default. The one exception is
`rdrs.internal.bufferShrinkAfterS`, which the chart sets to 900 by default; set
it to `null` for images older than RONDB-1144. A change to the
rendered file rolls the RDRS pods (the pod template carries its hash);
`rdrs2 --config /srv/hops/mysql-cluster/rest_api.json --print-limits` in an
RDRS pod shows the values in effect (without `--config` it reads no file and
shows the RDRS defaults).

The exposed values, per section of `rest_api.json`:

**REST** (the HTTP server; `ServerIP`, `ServerPort`, `ProbeEnable` and
`ProbePort` are chart-managed, see [RDRS probe port](#rdrs-probe-port))

| value | rest_api.json key | RDRS default | meaning |
|---|---|---|---|
| `rdrs.rest.numThreads` | `REST.NumThreads` | 64 | Worker threads; each holds a parse buffer of `maxHttpReqSize` bytes. 2 to 991. |
| `rdrs.rest.useCompression` | `REST.UseCompression` | true | Send responses gzip-compressed. |
| `rdrs.rest.useSingleTransaction` | `REST.UseSingleTransaction` | true | One NDB transaction for a whole batch request. |
| `rdrs.rest.idleConnectionTimeoutS` | `REST.IdleConnectionTimeoutS` | 0 (built-in 60 s) | Close a keep-alive connection idle for this long. 26.02.11 and newer. |
| `rdrs.maxKeepaliveRequests` | `REST.MaxKeepaliveRequests` | 0 (off) | Requests per keep-alive connection; rendered when not 0. 26.02.11 and newer. |
| `rdrs.uploadPath` | `REST.UploadPath` | `./uploads` | Directory for oversized request bodies; rendered when not empty. 26.02.11 and newer. |

**RonDB and RonDBMetadataCluster** (the cluster connections; `Mgmds`,
`ConnectionPoolSize` and `NodeIDs` are chart-managed). Both sections have the
same retry keys, so each set value is rendered into **both**, the data and the
metadata cluster section, including an external metadata cluster
(`rdrs.externalMetadataCluster`).

| value | rest_api.json key | RDRS default | meaning |
|---|---|---|---|
| `rdrs.rondb.connectionRetries` | `ConnectionRetries` | 5 | Connection attempts before giving up. |
| `rdrs.rondb.connectionRetryDelayInSec` | `ConnectionRetryDelayInSec` | 5 | Seconds between connection attempts. |
| `rdrs.rondb.opRetryOnTransientErrorsCount` | `OpRetryOnTransientErrorsCount` | 3 | Retries of an operation on a transient NDB error. |
| `rdrs.rondb.opRetryInitialDelayInMS` | `OpRetryInitialDelayInMS` | 500 | Delay before the first retry. |
| `rdrs.rondb.opRetryJitterInMS` | `OpRetryJitterInMS` | 100 | Random jitter added to each retry delay. |

**Security and FeatureStore** (the caches preloaded at startup; the startup
probe passes only once preloading is done)

| value | rest_api.json key | RDRS default | meaning |
|---|---|---|---|
| `rdrs.security.apiKey.cacheRefreshIntervalMS` | `Security.APIKey.CacheRefreshIntervalMS` | 180000 | API key cache refresh interval; always rendered. |
| `rdrs.security.apiKey.preloadThreads` | `Security.APIKey.PreloadThreads` | 3 | Threads preloading the API key cache. |
| `rdrs.featureStore.metadataCachePreloadThreads` | `FeatureStore.FeatureStoreMetadataCache.PreloadThreads` | 3 | Threads preloading the feature view metadata cache. |

**Internal** (request handling and memory). An RDRS with RONDB-1144 bounds its
memory: the request and response buffer sizes are computed from the RonDB row
limits (there is no setting for them), the number of buffers is capped from
the pod's memory limit, buffers that sit idle are returned to the OS, and a
batch request may carry at most a fixed number of operations. `MaxBuffers`,
`MaxHttpReqSize` (older images call it `maxReqSize`), `MaxBlobTextValueBytes`,
`BufferPoolSharePercent`, `BufferShrinkAfterS`, `DisableTransparentHugePages`,
`MaxOperationsPerBatchRequest` and `MaxOperationsPerNdbExecute` need an RDRS
with RONDB-1144.

| value | rest_api.json key | RDRS default | meaning |
|---|---|---|---|
| `rdrs.internal.maxHttpReqSize` | `Internal.MaxHttpReqSize` | 1048576 | Largest request body in bytes; also each thread's parse buffer. At least 256. |
| `rdrs.internal.maxBlobTextValueBytes` | `Internal.MaxBlobTextValueBytes` | 2097152 | Largest BLOB or TEXT value a read returns, in stored bytes; a larger one fails that operation with 413. 0 = no limit. |
| `rdrs.internal.scanRespBufferSize` | `Internal.ScanRespBufferSize` | 262144 | Initial scan response buffer in bytes; grows as needed. At least 1024. |
| `rdrs.internal.scanTimingEnabled` | `Internal.ScanTimingEnabled` | false | Per-scan timing metrics and a slow scan buffer. |
| `rdrs.internal.slowScanThresholdUs` | `Internal.SlowScanThresholdUs` | 10000 | Scans slower than this (µs) are recorded. |
| `rdrs.internal.slowScanBufferSize` | `Internal.SlowScanBufferSize` | 1000 | Slow scan entries kept. |
| `rdrs.internal.preAllocatedBuffers` | `Internal.PreAllocatedBuffers` | 128 | Buffers of each kind mapped at startup and kept through the idle shrink. |
| `rdrs.internal.disableTransparentHugePages` | `Internal.DisableTransparentHugePages` | true | RDRS opts out of transparent huge pages at startup; `false` allows them again. See [RDRS and transparent huge pages](#rdrs-and-transparent-huge-pages). |
| `rdrs.internal.maxBuffers` | `Internal.MaxBuffers` | derived from the memory limit | Cap on buffers of each kind; beyond it requests get 503. When non-zero, at least 2 and at least `preAllocatedBuffers`; the chart fails the render otherwise. |
| `rdrs.internal.bufferPoolSharePercent` | `Internal.BufferPoolSharePercent` | 50 | Share of the memory limit for the buffer pools and the JSON responses written from them when `maxBuffers` is derived. 1 to 90. Keep `resources.limits.memory.rdrsMiB` at 2 GiB or more; RDRS warns below that. |
| `rdrs.internal.bufferShrinkAfterS` | `Internal.BufferShrinkAfterS` | 300 (chart default 900) | Idle seconds before surplus buffers are unmapped; 0 disables. The chart renders 900 (15 minutes) unless set to `null`. |
| `rdrs.internal.maxOperationsPerBatchRequest` | `Internal.MaxOperationsPerBatchRequest` | 4096 | Largest batch request, in operations (batch feature store: entries); larger ones get 413. Large batches of wide rows need more than 2 GiB of RDRS memory. |
| `rdrs.internal.maxOperationsPerNdbExecute` | `Internal.MaxOperationsPerNdbExecute` | 128 | Batch operations sent to NDB per execute round; not a cap. 50 to 512. |
| `rdrs.internal.operationIdMaxSize` | `Internal.OperationIDMaxSize` | 256 | Longest operation ID in a batch request. At most 4096. |

**TTLPurge** (the purge of expired rows in TTL tables; needs **26.02.9 and newer**)

| value | rest_api.json key | RDRS default | meaning |
|---|---|---|---|
| `rdrs.ttlPurge.enable` | `TTLPurge.Enable` | true | Whether the pods run the TTL purge worker at startup; changeable per pod at runtime through `/ttl-purge/config`. |
| `rdrs.ttlPurge.activeWindow` | `TTLPurge.ActiveWindow` | empty (around the clock) | Daily UTC window `HH:MM-HH:MM`, may wrap past midnight; start and end must differ. A window in `mysql.ttl_purge_ctrl` takes precedence. |

**RateLimit** (USER rate limiting of the pods' NDB traffic, RONDB-978)

| value | rest_api.json key | RDRS default | meaning |
|---|---|---|---|
| `rdrs.rateLimit.enable` | `RateLimit.Enable` | false | Tag NDB transactions with the request's API key so the data nodes (run with `ActivateRateLimits`) enforce USER limits. |
| `rdrs.rateLimit.fullApiKey` | `RateLimit.FullAPIKey` | false | Use the full API key as identity instead of its prefix. |

**Log**

| value | rest_api.json key | RDRS default | meaning |
|---|---|---|---|
| `rdrs.log.level` | `Log.Level` | `warn` | One of `panic`, `fatal`, `error`, `warn`, `warning`, `info`, `debug`, `trace`. Earlier charts always rendered `info`. Note: current `rdrs2` releases parse the key but do not act on it (logging goes through the NDB event logger at a fixed level); it is exposed for the day it does. |

Not exposed, and why:

- `PIDFile`: the pod has no use for a pid file.
- `REST.Enable`, `ServerIP`, `ServerPort`, `ProbeEnable`, `ProbePort`: chart-managed
  (the Services, the container ports and the probes depend on them).
- `Internal.BatchMaxSize`, `ReqBufferSize`, `RespBufferSize` and `maxReqSize`:
  removed from RDRS in RONDB-1144. `maxOperationsPerBatchRequest` and
  `maxOperationsPerNdbExecute` replace `BatchMaxSize`, `maxHttpReqSize`
  replaces `maxReqSize`, and the buffer sizes are computed from the RonDB row
  limits.
- `Internal.StartReserveOverride`: a testing knob.
- `REST.PingRequiresAuth`, `REST.HealthRequiresAuth`: the chart's readiness,
  startup and liveness probes call `/ping` and `/health` without credentials,
  so requiring authentication would fail them; with the probe port on, rdrs2
  also refuses to start on that combination.
- `RonDB.Mgmds`, `ConnectionPoolSize`, `NodeIDs` and the same keys of
  `RonDBMetadataCluster`: chart-managed from `rondbConfig` and
  `rdrs.externalMetadataCluster`.
- `Security.InsecureAllowAll`, `Security.APIKey.UseHopsworksAPIKeys`: the chart
  always authenticates with Hopsworks API keys.
- `Security.TLS.*`: from `meta.rdrs.statefulSet.endToEndTls`.
- `RateLimit.Identity`: `apikey` is its only legal value.
- `Log.FilePath`, `MaxSizeMb`, `MaxBackups`, `MaxAge`: the pod logs to stdout.
- `GRPC`: not supported by `rdrs2`.
- `Rondis`: not deployed by this chart.
- `Testing.*`: test-only connectivity that `rdrs2` validates but never uses.

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
10) and keeps its old meaning: charts up to 26.2.19 applied it to the data
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
