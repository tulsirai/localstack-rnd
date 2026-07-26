locals {
  full_name = "${var.project}-${var.environment}-${var.function_name}"

  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      Function    = var.function_name
      ManagedBy   = "terraform"
    },
    var.tags
  )
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = var.src_dir
  output_path = "${path.module}/.build/${var.function_name}.zip"
}

# Explicit resource prevents Lambda from auto-creating an unmanaged log group
# with no retention, which would accumulate logs indefinitely.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.full_name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${local.full_name}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = local.tags
}

# Scoped to this function's own log group, plus whatever the caller passes
# via extra_iam_statements — never a wildcard on /aws/lambda/* or similar.
data "aws_iam_policy_document" "permissions" {
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  dynamic "statement" {
    for_each = var.extra_iam_statements
    content {
      sid       = statement.value.sid
      effect    = "Allow"
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${local.full_name}-policy"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_lambda_function" "this" {
  function_name = local.full_name
  role          = aws_iam_role.this.arn
  runtime       = var.runtime
  handler       = var.handler
  memory_size   = var.memory_mb
  timeout       = var.timeout_seconds

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  reserved_concurrent_executions = var.reserved_concurrency

  dynamic "environment" {
    for_each = length(var.environment_variables) > 0 ? [1] : []
    content {
      variables = var.environment_variables
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.this,
  ]

  tags = local.tags
}

resource "aws_lambda_function_url" "this" {
  count = var.create_function_url ? 1 : 0

  function_name      = aws_lambda_function.this.function_name
  authorization_type = var.function_url_auth_type
}
