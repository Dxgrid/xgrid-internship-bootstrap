#!/bin/bash
# Bootstrap Script: Create Remote State Infrastructure
# Purpose: Set up S3 bucket and DynamoDB table for Terraform state management
# Run ONCE before first terraform init

set -e

echo "🔧 Terraform Remote State Bootstrap"
echo "===================================="
echo ""

# Configuration
BUCKET_NAME="xgrid-terraform-state"
TABLE_NAME="terraform-locks"
REGION="us-east-1"
PROJECT_TAG="xgrid-sre-sprint"

echo "📌 Configuration:"
echo "  S3 Bucket: $BUCKET_NAME"
echo "  DynamoDB Table: $TABLE_NAME"
echo "  Region: $REGION"
echo ""

# Step 1: Create S3 Bucket
echo "📦 Step 1: Creating S3 bucket for state storage..."

if aws s3 ls "s3://$BUCKET_NAME" 2>&1 | grep -q 'NoSuchBucket'; then
    echo "Bucket doesn't exist - creating..."
    aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        $(if [ "$REGION" != "us-east-1" ]; then echo "--create-bucket-configuration LocationConstraint=$REGION"; fi)
    echo "✅ S3 bucket created"
else
    echo "✅ S3 bucket already exists"
fi

# Step 2: Enable Versioning
echo ""
echo "🔄 Step 2: Enabling versioning on S3 bucket..."
aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled
echo "✅ Versioning enabled (protects against accidental deletion)"

# Step 3: Enable Encryption
echo ""
echo "🔐 Step 3: Enabling encryption on S3 bucket..."
aws s3api put-bucket-encryption \
    --bucket "$BUCKET_NAME" \
    --server-side-encryption-configuration '{
        "Rules": [{
            "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "AES256"
            }
        }]
    }'
echo "✅ Encryption enabled (S3 default encryption)"

# Step 4: Block Public Access
echo ""
echo "🚫 Step 4: Blocking all public access to S3 bucket..."
aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "✅ Public access blocked (security best practice)"

# Step 5: Create DynamoDB Table for State Locking
echo ""
echo "🔒 Step 5: Creating DynamoDB table for state locking..."

TABLE_EXISTS=$(aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" 2>/dev/null || echo "")

if [ -z "$TABLE_EXISTS" ]; then
    echo "Table doesn't exist - creating..."
    aws dynamodb create-table \
        --table-name "$TABLE_NAME" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$REGION"
    
    # Wait for table to be created
    echo "Waiting for table to be created (this may take 10-30 seconds)..."
    aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
    echo "✅ DynamoDB table created and active"
else
    echo "✅ DynamoDB table already exists"
fi

# Step 6: Tag Resources
echo ""
echo "🏷️  Step 6: Tagging resources for cost tracking..."
BUCKET_ARN="arn:aws:s3:::$BUCKET_NAME"
aws s3api put-bucket-tagging \
    --bucket "$BUCKET_NAME" \
    --tagging 'TagSet=[{Key=Project,Value='"$PROJECT_TAG"'},{Key=Purpose,Value=TerraformState},{Key=ManagedBy,Value=Bootstrap}]' || true
echo "✅ Tags applied"

echo ""
echo "✅ Bootstrap Complete!"
echo ""
echo "Next steps:"
echo "1. Delete local terraform state (optional):"
echo "   cd week\ 2/terraform"
echo "   rm -rf .terraform/"
echo ""
echo "2. Initialize Terraform with remote state:"
echo "   terraform init"
echo ""
echo "3. Verify state is remote:"
echo "   terraform state list"
echo ""
echo "🎉 Now your Terraform state is:"
echo "   ✅ Stored remotely (survives local machine deletion)"
echo "   ✅ Protected with versioning (can recover old states)"
echo "   ✅ Encrypted at rest (secure)"
echo "   ✅ Locked during apply (prevents conflicts)"
echo "   ✅ Backed up (S3 versioning)"
echo ""
echo "The 'state out of sync' problem is SOLVED! 🚀"
