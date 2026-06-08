#!/usr/bin/env bash
# Creates the S3 bucket required by backend.tf before terraform init.
# Uses Terraform's native S3 locking (use_lockfile = true, Terraform >= 1.9).
# No DynamoDB table needed.
# Safe to run multiple times — skips resources that already exist.

set -euo pipefail

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required but not installed."
  exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
BUCKET_NAME="temporal-order-terraform-state"

echo "=== Temporal Order Management — Remote State Bootstrap ==="
echo "Bucket : $BUCKET_NAME"
echo "Region : $AWS_REGION"
echo

# ── S3 bucket ──────────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
  echo "[SKIP] S3 bucket '$BUCKET_NAME' already exists."
else
  echo "[CREATE] S3 bucket '$BUCKET_NAME'..."
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
fi

aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" }
    }]
  }'

aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "[OK] S3 bucket ready."
echo
echo "Locking: Terraform native S3 locking via use_lockfile = true"
echo "  State file : s3://$BUCKET_NAME/temporal/temporal/dev/terraform.tfstate"
echo "  Lock file  : s3://$BUCKET_NAME/temporal/temporal/dev/terraform.tfstate.tflock"
echo
echo "=== Backend ready. Run next: ==="
echo "  cd temporal-order-management-demo/terraform/environments/dev"
echo "  terraform init"
echo "  terraform plan -out=tfplan"
