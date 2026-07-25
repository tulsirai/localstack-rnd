terraform {
  required_providers {
    aws     = { source = "hashicorp/aws" }
    archive = { source = "hashicorp/archive" }
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
}

data "archive_file" "lambda" {
  type        = "zip"
  output_path = "${path.module}/handler.zip"
  source {
    filename = "handler.py"
    content  = <<-EOF
    import json, boto3, os, uuid
    def handler(event, context):
        table = boto3.resource('dynamodb').Table(os.environ['TABLE_NAME'])
        method = event.get('requestContext', {}).get('http', {}).get('method', 'GET')
        # Function URL POST, or direct invoke (e.g. Resource Browser) with a message
        if method == 'POST' or 'message' in event:
            data = json.loads(event.get('body', '{}')) if method == 'POST' else event
            item = {'id': str(uuid.uuid4()), **data}
            table.put_item(Item=item)
            return {'statusCode': 200, 'body': json.dumps(item)}
        result = table.scan()
        return {'statusCode': 200, 'body': json.dumps(result['Items'])}
    EOF
  }
}

resource "aws_iam_role" "lambda_role" {
  name = "lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_lambda_function" "messages_api" {
  function_name    = "messages-api"
  runtime          = "python3.14"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  role             = aws_iam_role.lambda_role.arn
  environment {
    variables = { TABLE_NAME = aws_dynamodb_table.messages.name }
  }
}

resource "aws_lambda_function_url" "messages_api" {
  function_name      = aws_lambda_function.messages_api.function_name
  authorization_type = "NONE"
}

output "function_url" {
  value = aws_lambda_function_url.messages_api.function_url
}