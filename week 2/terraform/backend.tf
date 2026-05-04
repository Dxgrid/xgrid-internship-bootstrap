// Remote State Backend Configuration
// This ensures Terraform state is stored remotely and protected from loss
// Prevents the "state out of sync with AWS resources" problem

terraform {
  backend "s3" {
    bucket         = "xgrid-terraform-state"  # S3 bucket name (must be globally unique)
    key            = "week2/terraform.tfstate" # Path within bucket
    region         = "us-east-1"
    encrypt        = true                      # Enable encryption at rest
    dynamodb_table = "terraform-locks"         # DynamoDB table for state locking

    # State locking ensures only ONE person can apply at a time
    # Prevents concurrent modifications that could corrupt state
  }
}

// NOTE: Before first use, run the bootstrap script:
// bash ../bootstrap-remote-state.sh
//
// This creates:
// ✅ S3 bucket for state storage
// ✅ DynamoDB table for state locking
// ✅ IAM policies for security
