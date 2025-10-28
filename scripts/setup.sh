#!/bin/bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="mlsecops-eks-cluster"
REGION="us-east-1"
NAMESPACE="argocd"

echo "ArgoCD EKS Access Setup"

echo "Checking required tools..."
command -v aws >/dev/null 2>&1 || { echo "AWS CLI is required but not installed. Aborting."; return 1 2>/dev/null || exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting."; return 1 2>/dev/null || exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed. Aborting."; return 1 2>/dev/null || exit 1; }
echo "All required tools are installed"

# Get caller identity
CALLER_IDENTITY=$(aws sts get-caller-identity)
ACCOUNT_ID=$(echo $CALLER_IDENTITY | jq -r '.Account')
CALLER_ARN=$(echo $CALLER_IDENTITY | jq -r '.Arn')

# Check if already using the target role
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/GithubActions"

if [[ "$CALLER_ARN" == *":assumed-role/GithubActions/"* ]]; then
    echo "Already using required role, skipping role assumption"
else
    # Assume role
    SESSION_NAME="dev-session-$(date +%s)"

    echo "Assuming role: $ROLE_ARN"
    echo "Session name: $SESSION_NAME"

    CREDENTIALS=$(aws sts assume-role \
        --role-arn $ROLE_ARN \
        --role-session-name $SESSION_NAME \
        --output json)

    if [ $? -ne 0 ]; then
        echo "Failed to assume role. Please check your permissions."
        return 1 2>/dev/null || exit 1
    fi

    echo "Role assumed successfully"

    export AWS_ACCESS_KEY_ID=$(echo $CREDENTIALS | jq -r '.Credentials.AccessKeyId')
    export AWS_SECRET_ACCESS_KEY=$(echo $CREDENTIALS | jq -r '.Credentials.SecretAccessKey')
    export AWS_SESSION_TOKEN=$(echo $CREDENTIALS | jq -r '.Credentials.SessionToken')
fi

# Update kubeconfig
echo "Updating kubeconfig for EKS cluster: $CLUSTER_NAME"
aws eks update-kubeconfig \
    --name $CLUSTER_NAME \
    --region $REGION

if [ $? -ne 0 ]; then
    echo "Failed to update kubeconfig. Please check if the cluster exists."
    return 1 2>/dev/null || exit 1
fi

echo "Kubeconfig updated"

# Check cluster access
echo "Verifying cluster access..."
kubectl get nodes

if [ $? -ne 0 ]; then
    echo "Failed to access cluster. Please check your permissions."
    return 1 2>/dev/null || exit 1
fi

echo "Successfully connected to EKS cluster"

# Check installations and set up port forwarding
echo ""
echo "Setting up port forwarding for services..."
echo ""

# Arrays to store service information
declare -a SERVICES
declare -a LINKS
declare -a STATUSES
declare -a PIDS

# Check ArgoCD
if kubectl get namespace $NAMESPACE >/dev/null 2>&1; then
    kubectl port-forward svc/argo-cd-argocd-server -n $NAMESPACE 8080:80 > /dev/null 2>&1 &
    PID=$!
    export ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret -n $NAMESPACE -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

    SERVICES+=("ArgoCD")
    LINKS+=("http://localhost:8080|User: admin|Pass: echo \$ARGOCD_PASS")
    STATUSES+=("Active")
    PIDS+=("$PID")
else
    SERVICES+=("ArgoCD")
    LINKS+=("-")
    STATUSES+=("Not Found")
    PIDS+=("-")
fi

# Check Argo Workflows
WORKFLOWS_NAMESPACE="argo-workflows"
if kubectl get namespace $WORKFLOWS_NAMESPACE >/dev/null 2>&1; then
    kubectl port-forward svc/argo-workflows-server -n $WORKFLOWS_NAMESPACE 2746:2746 > /dev/null 2>&1 &
    PID=$!

    SERVICES+=("Argo Workflows")
    LINKS+=("http://localhost:2746")
    STATUSES+=("Active")
    PIDS+=("$PID")
else
    SERVICES+=("Argo Workflows")
    LINKS+=("-")
    STATUSES+=("Not Found")
    PIDS+=("-")
fi

# Check MLflow
MLFLOW_NAMESPACE="mlflow"
if kubectl get namespace $MLFLOW_NAMESPACE >/dev/null 2>&1; then
    kubectl port-forward svc/mlflow -n $MLFLOW_NAMESPACE 5000:5000 > /dev/null 2>&1 &
    PID=$!

    SERVICES+=("MLflow")
    LINKS+=("http://localhost:5000")
    STATUSES+=("Active")
    PIDS+=("$PID")
else
    SERVICES+=("MLflow")
    LINKS+=("-")
    STATUSES+=("Not Found")
    PIDS+=("-")
fi

# Print table
echo "╔════════════════════╤════════════════════════════════════════╤════════════╤═══════╗"
echo "║ Service            │ Access                                 │ Status     │ PID   ║"
echo "╠════════════════════╪════════════════════════════════════════╪════════════╪═══════╣"

for i in "${!SERVICES[@]}"; do
    SERVICE="${SERVICES[$i]}"
    LINK="${LINKS[$i]}"
    STATUS="${STATUSES[$i]}"
    PID="${PIDS[$i]}"

    IFS='|' read -ra LINK_PARTS <<< "$LINK"

    printf "║ %-18s │ %-38s │ %-10s │ %-5s ║\n" "$SERVICE" "${LINK_PARTS[0]}" "$STATUS" "$PID"

    for ((j=1; j<${#LINK_PARTS[@]}; j++)); do
        printf "║ %-18s │ %-38s │ %-10s │ %-5s ║\n" "" "${LINK_PARTS[$j]}" "" ""
    done

    if [ $i -lt $((${#SERVICES[@]} - 1)) ]; then
        echo "╟────────────────────┼────────────────────────────────────────┼────────────┼───────╢"
    fi
done

echo "╚════════════════════╧════════════════════════════════════════╧════════════╧═══════╝"
echo ""
echo "Note: Port forwarding is running in background. To stop all port forwards:"
echo "      kill ${PIDS[@]}"
echo ""
