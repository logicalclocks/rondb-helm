# Global Replication - Getting Started

The following shows how to replicate between two RonDB clusters.

## Active-Passive from scratch

### Minikube

Using Minikube, we replicate *between namespaces* (i.e. within the same K8s cluster).

```bash
PRIMARY_NAMESPACE=rondb-primary
SECONDARY_NAMESPACE=rondb-secondary

kubectl create namespace $PRIMARY_NAMESPACE
kubectl create namespace $SECONDARY_NAMESPACE

# IF NEEDED:
# - Create dependencies such as cert-manager or Ingress controller
# - Create object storage Secrets for each namespace

./test_scripts/active-passive-minikube.sh $PRIMARY_NAMESPACE $SECONDARY_NAMESPACE
```

Verify replication:

```bash
helm test -n $PRIMARY_NAMESPACE rondb-primary --logs --filter name=generate-data
helm test -n $SECONDARY_NAMESPACE rondb-secondary --logs --filter name=verify-data
```

Clean up:

```bash
helm delete rondb-primary --namespace=$PRIMARY_NAMESPACE
helm delete rondb-secondary --namespace=$SECONDARY_NAMESPACE
```

### Production clusters

We now replicate between two Kubernetes clusters, where each contains one RonDB cluster.

```bash
# Same namespace for both
NAMESPACE=rondb-default
PRIMARY_KUBECONFIG=<path_to_primary_config>
SECONDARY_KUBECONFIG=<path_to_secondary_config>

kubectl create namespace $NAMESPACE --kubeconfig=$PRIMARY_KUBECONFIG
kubectl create namespace $NAMESPACE --kubeconfig=$SECONDARY_KUBECONFIG

# IF NEEDED:
# - Create dependencies such as cert-manager or Ingress controller
# - Create object storage Secrets for each namespace

./test_scripts/active-passive-prod.sh $NAMESPACE $PRIMARY_KUBECONFIG $SECONDARY_KUBECONFIG
```

Verify replication:

```bash
helm test --kubeconfig=$PRIMARY_KUBECONFIG -n $NAMESPACE rondb-primary --logs --filter name=generate-data
helm test --kubeconfig=$SECONDARY_KUBECONFIG -n $NAMESPACE rondb-secondary --logs --filter name=verify-data
```

Clean up:

```bash
helm delete --kubeconfig=$PRIMARY_KUBECONFIG rondb-primary --namespace=$NAMESPACE
helm delete --kubeconfig=$SECONDARY_KUBECONFIG rondb-secondary --namespace=$NAMESPACE
```

## Active-passive with backups ("lifecycle tests")

This will test backup/restore in the context of Global Replication. There is a difference for example whether global replication is started from scratch or from a backup. There is also a difference whether the backup came from the primary cluster or an entirely different cluster. These tests will check for all cases.

### Minikube

1. Edit ./test_scripts/minio.env if needed
2. If not using cert-manager, disable all values in `values/end_to_end_tls.yaml`
3. Run:
    ```bash
    ./test_scripts/setup_minio.sh
    ./test_scripts/lifecycle-test.sh "cluster-a" "cluster-b" "cluster-c" "cluster-d"
    ```
4. Clean up MinIO:
    ```bash
    helm delete tenant -n $MINIO_TENANT_NAMESPACE
    kubectl delete namespace $MINIO_TENANT_NAMESPACE
    ```
