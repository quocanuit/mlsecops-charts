#!/bin/bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="mlsecops-eks-cluster"
REGION="us-east-1"
NAMESPACE="argocd"

echo "ArgoCD EKS Access Setup"
echo ""

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

# Check installations and provide access information
echo ""
echo "Available Services"
echo ""

# Arrays to store service information - clear them first
SERVICES=()
PORT_FORWARDS=()
ACCESS_INFO=()

# Check ArgoCD
if kubectl get namespace $NAMESPACE >/dev/null 2>&1; then
    export ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret -n $NAMESPACE -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

    SERVICES+=("ArgoCD")
    PORT_FORWARDS+=("kubectl port-forward svc/argo-cd-argocd-server -n $NAMESPACE 8080:80 > /dev/null 2>&1 &")
    ACCESS_INFO+=("http://localhost:8080|User: admin|Pass: echo \$ARGOCD_PASS")
else
    SERVICES+=("ArgoCD")
    PORT_FORWARDS+=("")
    ACCESS_INFO+=("Not installed")
fi

# Check Argo Workflows
WORKFLOWS_NAMESPACE="argo-workflows"
if kubectl get namespace $WORKFLOWS_NAMESPACE >/dev/null 2>&1; then
    SERVICES+=("Argo Workflows")
    PORT_FORWARDS+=("kubectl port-forward svc/argo-workflows-server -n $WORKFLOWS_NAMESPACE 2746:2746 > /dev/null 2>&1 &")
    ACCESS_INFO+=("http://localhost:2746")
else
    SERVICES+=("Argo Workflows")
    PORT_FORWARDS+=("")
    ACCESS_INFO+=("Not installed")
fi

# Check MLflow
MLFLOW_NAMESPACE="mlflow"
if kubectl get namespace $MLFLOW_NAMESPACE >/dev/null 2>&1; then
    SERVICES+=("MLflow")
    PORT_FORWARDS+=("kubectl port-forward svc/mlflow -n $MLFLOW_NAMESPACE 5000:80 > /dev/null 2>&1 &")
    ACCESS_INFO+=("http://localhost:5000")
else
    SERVICES+=("MLflow")
    PORT_FORWARDS+=("")
    ACCESS_INFO+=("Not installed")
fi

# Print table
echo "╔════════════════════╤════════════════════════════════════════╗"
echo "║ Service            │ Access                                 ║"
echo "╠════════════════════╪════════════════════════════════════════╣"

for i in "${!SERVICES[@]}"; do
    SERVICE="${SERVICES[$i]}"
    ACCESS="${ACCESS_INFO[$i]}"

    IFS='|' read -ra ACCESS_PARTS <<< "$ACCESS"

    printf "║ %-18s │ %-38s ║\n" "$SERVICE" "${ACCESS_PARTS[0]}"

    for ((j=1; j<${#ACCESS_PARTS[@]}; j++)); do
        printf "║ %-18s │ %-38s ║\n" "" "${ACCESS_PARTS[$j]}"
    done

    if [ $i -lt $((${#SERVICES[@]} - 1)) ]; then
        echo "╟────────────────────┼────────────────────────────────────────╢"
    fi
done

echo "╚════════════════════╧════════════════════════════════════════╝"
echo ""
echo "Port-forward commands:"

# Print port-forward commands
for i in "${!SERVICES[@]}"; do
    if [ -n "${PORT_FORWARDS[$i]}" ]; then
        echo "${SERVICES[$i]}:"
        echo "  ${PORT_FORWARDS[$i]}"
    fi
done

echo ""
echo "Note: Run the port-forward commands before accessing the service"
echo ""
