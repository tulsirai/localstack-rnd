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

# No explicit `provider "aws" {}` block here, deliberately. `tflocal` (and
# `lstk terraform`) generate their own provider override file at apply time
# with the LocalStack endpoint/region — declaring one ourselves would
# collide with it ("duplicate provider configuration"). Terraform resolves
# the AWS provider from that generated config plus the active AWS profile.
