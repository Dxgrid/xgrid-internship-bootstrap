terraform {
  backend "s3" {
    bucket       = "temporal-order-terraform-state"
    key          = "temporal/temporal/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
