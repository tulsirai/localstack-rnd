locals {
  project     = "localstack-rnd"
  environment = "local"

  tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_dynamodb_table" "messages" {
  name         = "Messages"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = local.tags
}

module "messages_api" {
  source = "../../modules/lambda"

  project       = local.project
  environment   = local.environment
  function_name = "messages-api"

  runtime = "python3.14"
  handler = "handler.handler"
  src_dir = "${path.module}/../../../src/messages-api"

  memory_mb       = 128
  timeout_seconds = 10

  environment_variables = {
    TABLE_NAME = aws_dynamodb_table.messages.name
  }

  # Local sandbox only — a public function URL is never appropriate against
  # real AWS without deliberately choosing that tradeoff (see AWS_IAM default).
  create_function_url    = true
  function_url_auth_type = "NONE"

  extra_iam_statements = [
    {
      sid       = "DynamoDBMessagesTableAccess"
      actions   = ["dynamodb:PutItem", "dynamodb:Scan"]
      resources = [aws_dynamodb_table.messages.arn]
    }
  ]

  tags = merge(local.tags, {
    CostCenter = "sandbox"
    Owner      = "tulsirai"
  })
}
