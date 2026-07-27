variable "terraform_state_bucket_name" {
  type        = string
  description = "Globally unique S3 bucket name for Terraform remote state. Lowercase letters, numbers, and hyphens only — no underscores. Include your AWS account ID for uniqueness."
}

variable "project" {
  type        = string
  default     = "localstack-rnd"
  description = "Used to scope the GitHub Actions IAM role's permissions to this project's resources only."
}

variable "github_org" {
  type        = string
  default     = "tulsirai"
}

variable "github_repo" {
  type        = string
  default     = "localstack-rnd"
}
