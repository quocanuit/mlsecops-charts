#!/bin/bash

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="argocd"
CHART_PATH="${ROOT}/charts/argo-cd"

echo "Installing ArgoCD..."

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

helm dependency update $CHART_PATH

helm upgrade --install argo-cd $CHART_PATH \
    --namespace $NAMESPACE \
    --wait \
    --timeout 10m

echo "ArgoCD installed!"
