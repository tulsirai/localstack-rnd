resource "aws_s3_bucket" "tf_state" {
  bucket = var.terraform_state_bucket_name
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─── IAM OIDC: GitHub Actions identity provider ──────────────────────────────
# Account-wide and already exists (created by another project's bootstrap in
# this same account) — reference it, don't recreate it. Only one OIDC
# provider per URL is allowed per AWS account; a second `resource` here
# would fail with EntityAlreadyExists.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ─── IAM Role: assumed by GitHub Actions workflows ───────────────────────────
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scope trust to this specific repo only.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project}-github-actions-role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

# ─── IAM Policy: what GitHub Actions is allowed to do ────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "github_actions_permissions" {
  # Terraform state bucket: read/write state files + native S3 locking.
  statement {
    sid    = "TerraformStateBucketAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.tf_state.arn,
      "${aws_s3_bucket.tf_state.arn}/*",
    ]
  }

  # Lambda lifecycle management — scoped to this project's resources by name
  # prefix. Read actions (Get*/List*/Describe*) are required by Terraform to
  # refresh state.
  statement {
    sid    = "LambdaManagement"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:DeleteFunction",
      "lambda:PublishVersion",
      "lambda:CreateFunctionUrlConfig",
      "lambda:UpdateFunctionUrlConfig",
      "lambda:DeleteFunctionUrlConfig",
      "lambda:GetFunctionUrlConfig",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetPolicy",
      "lambda:ListVersionsByFunction",
      "lambda:ListTags",
    ]
    resources = [
      "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${var.project}-*"
    ]
  }

  # IAM: manage the Lambda execution role scoped to this project.
  statement {
    sid    = "IAMRoleManagement"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:PassRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-*"
    ]
  }

  # CloudWatch Logs list/describe actions cannot be scoped to specific log
  # groups — AWS requires these on * or they return AccessDenied regardless
  # of the resource ARN.
  statement {
    sid    = "CloudWatchLogsReadOnly"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:ListTagsForResource",
    ]
    resources = ["*"]
  }

  # CloudWatch Logs: create/delete/tag scoped to this project's log groups.
  statement {
    sid    = "CloudWatchLogsManage"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
    ]
    resources = [
      "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project}-*"
    ]
  }

  # DynamoDB: table lifecycle management, scoped to tables this project
  # creates. Table names aren't currently environment-prefixed the way the
  # Lambda/IAM role names are (see note in environments/dev/main.tf) — worth
  # fixing before a second real-AWS environment (e.g. prod) shares this
  # account, to avoid a table-name collision.
  statement {
    sid    = "DynamoDBTableManagement"
    effect = "Allow"
    actions = [
      "dynamodb:CreateTable",
      "dynamodb:DeleteTable",
      "dynamodb:DescribeTable",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
      "dynamodb:ListTagsOfResource",
    ]
    resources = [
      "arn:aws:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/*"
    ]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${var.project}-github-actions-policy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}
