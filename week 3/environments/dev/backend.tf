terraform {
  backend "s3" {
    # Remote state backend values.
    bucket       = "wordpress-ecs-tfstate-xgrid-1777960641"
    key          = "dev/wordpress/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
