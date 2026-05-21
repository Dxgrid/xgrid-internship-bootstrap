terraform {
  backend "s3" {
    # Remote state backend values.
    bucket       = "wordpress-ecs-tfstate-xgrid-1779080592"
    key          = "dev/week5/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
