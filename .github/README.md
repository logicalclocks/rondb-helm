# Expected infrastructure on self-hosted

## Dependencies

- Docker
- kubectl
- Minikube
- Helm

## Run K8s cluster (Minikube)

1. Run Minikube:
    ```bash
    minikube start \
        --driver=docker \
        --cpus=12 \
        --memory=16000MB \
        --cni calico \
        --feature-gates="CPUManager=true" \
        --extra-config=kubelet.cpu-manager-policy="static" \
        --extra-config=kubelet.cpu-manager-policy-options="full-pcpus-only=true" \
        --extra-config=kubelet.kube-reserved="cpu=500m" \
        --addons=[metrics-server,storage-provisioner-rancher]
    ```
    * CNI Calico is needed to enable Network Policies.
    * Static CPU Manager is needed to allow fixing data nodes to host CPUs
2. Install infra:
    - Cert-manager:
        ```bash
        # Installing cert-manager for webhook
        kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.3/cert-manager.yaml
        ```
    - Nginx-Ingress controller:
      The Ingress requires the nginx Ingress controller to run (admission webhook).
      ```bash
      helm upgrade --install rondb-ingress-nginx ingress-nginx \
            --repo https://kubernetes.github.io/ingress-nginx \
            --namespace=default
      # Additional parameters:
      # Setting TCP parameters since raw TCP connections are not supported by default;
      # see https://kubernetes.github.io/ingress-nginx/user-guide/exposing-tcp-udp-services/
      # These flags will create a ConfigMap with the TCP services and ports to expose.
      # No need to also set RDRS HTTP (4406); can be defined in the actual Ingress.
      # We need to know the namespace of the RonDB cluster though for this to work.
            --set "tcp.3306"="$K8S_NAMESPACE/mysqld:3306" \
            --set "tcp.5406"="$K8S_NAMESPACE/rdrs:5406"
      ```
3. Add MinIO (to test backup/restore):
    ```bash
    curl -O https://raw.githubusercontent.com/minio/operator/master/helm-releases/operator-6.0.4.tgz
    tar -xzf operator-6.0.4.tgz
    helm upgrade -i \
        --namespace minio-operator \
        --create-namespace \
        minio-operator ./operator \
        --set operator.replicaCount=1

    # Still needed to instantiate MinIO Tenants
    helm repo add minio https://operator.min.io/
    ```
