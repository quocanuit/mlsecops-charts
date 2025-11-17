#!/bin/bash
set -e

REGION="us-east-1"
RDS_ID="mlsecopsmlflowbackend"
SECRET_ID="mlflow/backend/psqlpassword"
DB_USER="mlflowadmin"
DB_NAME="mlflowbackend"
NAMESPACE="mlflow"
SECRET_NAME="mlflow-secrets"
S3_BUCKET="s3://mlsecops-mlflow-artifacts"

echo "Getting RDS endpoint..."
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --region "$REGION" \
  --db-instance-identifier "$RDS_ID" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

echo "Getting DB password..."
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --region "$REGION" \
  --secret-id "$SECRET_ID" \
  --query 'SecretString' \
  --output text | jq -r '.mlflowbackendpw')

MLFLOW_BACKEND_URI="postgresql+psycopg2://${DB_USER}:${DB_PASSWORD}@${RDS_ENDPOINT}:5432/${DB_NAME}?sslmode=require"

echo "Creating secret in Kubernetes..."
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=MLFLOW_BACKEND_URI="$MLFLOW_BACKEND_URI" \
  --from-literal=MLFLOW_S3_BUCKET="$S3_BUCKET" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret '$SECRET_NAME' created in namespace '$NAMESPACE'."
