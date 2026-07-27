terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# This config's own state is intentionally local, not remote — it's the
# one exception. The bucket it creates is meant to hold *other*
# environments' state (dev, prod, etc.); it can't hold its own on the very
# first run. Keep this state file safe (it's the only record of the real
# bucket/settings that exist) — don't delete it after applying.
