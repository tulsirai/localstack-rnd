# Migration checklist — LocalStack sandbox → real AWS

Context for when this project is ready to deploy to a real AWS account, after
the LocalStack CI pipeline is green and stable. Written as a forward-looking
plan on 2026-07-25 — re-verify current tool/doc behavior before executing,
since this reflects LocalStack/Terraform/GitHub Actions guidance as of that date.

## Guiding principle

Same Terraform code, same modules. Nothing in `.tf` files should ever say
"LocalStack" — local/CI validation uses a wrapper (`tflocal` / `lstk terraform`)
that injects endpoint overrides at runtime; the real-AWS pipeline uses plain
`terraform` with real credentials. The two pipelines (LocalStack CI, real-AWS
deploy) run side by side permanently afterward — LocalStack CI doesn't get
retired once real AWS exists, it stays as the fast pre-flight check on every
PR.

## Prerequisite: don't trust LocalStack as proof of AWS-correctness

LocalStack does not enforce IAM permissions by default — confirmed firsthand
in this project (a Lambda with zero attached permissions successfully wrote
to and scanned a DynamoDB table locally). Missing least-privilege policies,
unsupported Lambda runtimes, quota/concurrency behavior, and some newer
service features can all diverge from real AWS. Do not skip the manual
sandbox-account validation pass below.

## Step 0 — Prerequisite: LocalStack CI must be green and stable first

- [ ] `main.tf` refactored into `infra/modules/` + `infra/environments/` pattern
      (borrowed from `aws-serverless-app`)
- [ ] Least-privilege IAM policies written into the module (even though
      LocalStack won't enforce them — this is where they get authored)
- [ ] GitHub Actions workflow using `LocalStack/setup-localstack` + `tflocal`
      passing consistently on every push/PR
- [ ] `LOCALSTACK_AUTH_TOKEN` (CI auth token, distinct from personal dev token)
      wired as a GitHub secret if any Pro features are used in CI

## Step 1 — Manual validation against a real AWS sandbox account (the "graduation exam")

Do this by hand, outside CI, before building any real pipeline:

- [ ] Create or use an existing personal/sandbox AWS account (not shared with
      production workloads)
- [ ] Configure real AWS CLI credentials locally (`aws configure` or SSO)
- [ ] Run plain `terraform init && terraform plan` (not `tflocal`) against the
      module/environment code, targeting the sandbox account
- [ ] Run `terraform apply` and fix whatever fails that LocalStack let slide —
      expect IAM `AccessDenied` errors first; add the missing policy
      statements (e.g. `dynamodb:PutItem`/`dynamodb:Scan` scoped to the table
      ARN, `logs:CreateLogStream`/`logs:PutLogEvents` scoped to the log group)
- [ ] Verify the Lambda runtime string used (e.g. `python3.14`) is actually a
      published AWS Lambda runtime — check `aws lambda list-runtimes` or
      current AWS docs rather than assuming
- [ ] Smoke-test the deployed function URL / API end-to-end, same as the local
      LocalStack smoke test
- [ ] `terraform destroy` the sandbox once validated — this is a throwaway
      proof pass, not the real environment

## Step 2 — Bootstrap the real AWS account (run once, by a human, with elevated creds)

Modeled directly on `aws-serverless-app/infra/bootstrap/`:

- [ ] S3 artifact bucket (versioned, SSE-encrypted, public access blocked) —
      CI/CD uploads Lambda zips here
- [ ] S3 Terraform state bucket (versioned, SSE-encrypted, public access
      blocked), one key per environment
- [ ] Native S3 state locking (`use_lockfile = true`, Terraform ≥1.10) —
      prefer this over the deprecated `dynamodb_table` lock option
- [ ] IAM OIDC provider trusting `token.actions.githubusercontent.com`
- [ ] IAM role for GitHub Actions, trust policy scoped to
      `repo:<org>/<repo>:*` (tighten to `ref:refs/heads/main` to block
      feature-branch deploys)
- [ ] Least-privilege permissions policy for that role — scoped to
      `arn:aws:lambda:...:function:<project>-*` and
      `arn:aws:iam::...:role/<project>-*`, not wildcards
- [ ] Commit `.terraform.lock.hcl` for this bootstrap config (don't repeat the
      gitignore gap seen in `aws-serverless-app`)

## Step 3 — Wire up the GitHub repo

- [ ] Add `GH_ACTIONS_ROLE_ARN` as a repository **secret** (contains account
      ID/role path — sensitive)
- [ ] Add `ARTIFACT_BUCKET` as a repository **variable** (non-sensitive,
      needs to be visible in workflow logs for debugging)
- [ ] Create GitHub Environments: `dev` (no gate, auto-deploy),
      `prod` (required reviewers) — add `qa`/`uat` only if the team size
      justifies the extra promotion stages
- [ ] Point `backend.tf` in each environment at the real state bucket —
      inject via `-backend-config` in CI rather than hardcoding a real
      account ID directly into a committed file

## Step 4 — Add the real-AWS deploy pipeline (separate workflow, not a modification of the LocalStack CI workflow)

- [ ] New workflow (e.g. `infra-deploy.yml`), triggered on push to `main`
      under `infra/**`, using OIDC (`aws-actions/configure-aws-credentials`)
      and plain `terraform` (not `tflocal`)
- [ ] Bootstrap-placeholder-zip pattern for first Lambda creation, with
      `lifecycle { ignore_changes = [s3_key, s3_object_version,
      source_code_hash] }` so Terraform never fights the app-code pipeline
      over the deployed code
- [ ] Separate `app-deploy.yml` for code-only changes under `src/**` —
      `aws lambda update-function-code` → `publish-version` →
      `update-alias --name live` — no `terraform apply` involved
- [ ] Approval gate enforced on `prod` environment before `terraform apply`
      runs
- [ ] Explicit rule: never run `terraform destroy` against `prod` via
      automation — manual execution only, with explicit confirmation

## Step 5 — Steady state

- [ ] LocalStack CI workflow keeps running on every PR (fast, free,
      no real credentials) — the pre-flight check
- [ ] Real-AWS deploy workflow runs on merge to `main` — the actual
      deployment, gated by environment protection rules
- [ ] Both pipelines coexist permanently; LocalStack CI is not retired once
      real AWS exists

## Things intentionally deferred until there's an actual need

- Multi-account setup (separate AWS account per environment)
- VPC / private networking for the Lambda
- Canary/weighted alias routing (`routing_config` on the alias, currently
  reserved via `ignore_changes` but unused)
- API Gateway in front of the function URL, if auth/throttling requirements
  grow beyond what `authorization_type = AWS_IAM` on the function URL covers
