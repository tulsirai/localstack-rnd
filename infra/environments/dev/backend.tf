terraform {
  backend "s3" {
    bucket       = "localstack-rnd-tf-state-670069047744"
    key          = "dev/messages-api/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
