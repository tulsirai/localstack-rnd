terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

# No backend block yet — state is local for now. A real S3 remote backend
# requires the state bucket to exist first (the bootstrap step), which
# hasn't been built. Don't add a backend "s3" block here until that exists,
# or `terraform init` will fail looking for a bucket that isn't there.
