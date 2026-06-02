#!/usr/bin/env bash

set -euo pipefail

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required but not installed."
  exit 1
fi

aws_region="${AWS_REGION:-us-east-1}"
bucket_prefix="${STATE_BUCKET_PREFIX:-week6-terraform-state}"
bucket_name="${STATE_BUCKET_NAME:-${bucket_prefix}-$(whoami)-$(date +%s)}"
state_key="${STATE_KEY:-dev/wordpress/terraform.tfstate}"

echo "Setting up Terraform remote state backend..."
echo "Bucket: $bucket_name"
echo "Region: $aws_region"

if [[ "$aws_region" == "us-east-1" ]]; then
  aws s3api create-bucket \
    --bucket "$bucket_name" \
    --region "$aws_region"
else
  aws s3api create-bucket \
    --bucket "$bucket_name" \
    --region "$aws_region" \
    --create-bucket-configuration LocationConstraint="$aws_region"
fi

aws s3api put-bucket-versioning \
  --bucket "$bucket_name" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$bucket_name" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

aws s3api put-public-access-block \
  --bucket "$bucket_name" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo
echo "Remote state backend created successfully."
echo
echo "Use these values in backend.tf:"
echo "bucket      = \"$bucket_name\""
echo "key         = \"$state_key\""
echo "region      = \"$aws_region\""
echo "use_lockfile = true"
