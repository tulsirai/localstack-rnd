variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "function_name" {
  type = string
}

variable "runtime" {
  type = string
}

variable "handler" {
  type = string
}

variable "src_dir" {
  type        = string
  description = "Directory zipped as the Lambda deployment package."
}

variable "memory_mb" {
  type    = number
  default = 128
}

variable "timeout_seconds" {
  type    = number
  default = 10
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "reserved_concurrency" {
  type    = number
  default = -1
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "create_function_url" {
  type    = bool
  default = false
}

variable "function_url_auth_type" {
  type    = string
  default = "AWS_IAM"
}

variable "extra_iam_statements" {
  description = "Additional least-privilege statements merged into the execution role's policy (e.g. table/queue access), scoped by the caller — this module stays app-agnostic."
  type = list(object({
    sid       = string
    actions   = list(string)
    resources = list(string)
  }))
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
