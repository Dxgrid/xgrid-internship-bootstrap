terraform {
  backend "s3" {
    # Remote state backend values.
    bucket       = "week6-terraform-state-xgrid-1780287011"
    key          = "dev/week6/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
