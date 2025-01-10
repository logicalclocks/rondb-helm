#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

CERT_MANAGER_URL=https://github.com/cert-manager/cert-manager/releases/download/v1.14.3/cert-manager.yaml
HELM_NGINX_NAME=ingress-nginx
HELM_NGINX_INSTANCE_NAME=rondb-ingress-nginx

setup_deps() {
    (
        set -e
        RONDB_NAMESPACE=$1

        echo "Setting up dependencies for standalone RonDB deployment in namespace $RONDB_NAMESPACE"

        # Note:
        # This is not placed entirely in Helm dependencies because
        #   1. Helm will not install the CRDs
        #   2. We need to know the namespace to install the Ingress controller (see below)

        # Deploy cert-manager
        kubectl apply -f $CERT_MANAGER_URL

        echo "Created cert-manager"

        # The Ingress in the Helmchart requires the nginx Ingress controller
        # to run (admission webhook).
        # Setting TCP parameters since raw TCP connections are not supported by default;
        #   see https://kubernetes.github.io/ingress-nginx/user-guide/exposing-tcp-udp-services/
        #   These flags will create a ConfigMap with the TCP services and ports to expose.
        # WARN: This will automatically expose the MySQLd, regardless of the values.yaml.
        # No need to also set RDRS HTTP (4406); can be defined in the actual Ingress.
        helm upgrade --install $HELM_NGINX_INSTANCE_NAME $HELM_NGINX_NAME \
            --repo https://kubernetes.github.io/ingress-nginx \
            --namespace=$RONDB_NAMESPACE \
            --set "tcp.3306"="$RONDB_NAMESPACE/mysqld:3306" \
            --set "tcp.5406"="$RONDB_NAMESPACE/rdrs:5406"

        echo "Created Nginx Ingress controller"

        kubectl wait \
            --namespace $RONDB_NAMESPACE \
            --for=condition=ready pod \
            --selector=app.kubernetes.io/component=controller \
            --timeout=300s

        echo "Nginx Ingress controller is ready - we can instantiate nginx Ingress instances now"
    )
}

destroy_deps() {
    (
        set +e
        set -x

        # Remove cert-manager
        kubectl delete -f $CERT_MANAGER_URL

        # Remove all related to Nginx-Ingress controller
        kubectl delete all --all -n $HELM_NGINX_NAME
        kubectl delete namespace $HELM_NGINX_NAME
        kubectl delete clusterrole $HELM_NGINX_INSTANCE_NAME
        kubectl delete clusterrolebinding $HELM_NGINX_INSTANCE_NAME
        kubectl delete ingressClass nginx
        kubectl delete ValidatingWebhookConfiguration $HELM_NGINX_NAME-admission
        kubectl delete ValidatingWebhookConfiguration $HELM_NGINX_INSTANCE_NAME-admission
    )
}
