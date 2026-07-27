# localstack-rnd — AWS Serverless Sandbox with LocalStack, Terraform, and CI/CD

A `messages-api` serverless app (DynamoDB + Lambda + function URL) used to learn
LocalStack, build it with production-minded Terraform, and progressively wire up
real CI/CD to a real AWS account — without ever needing to hand-roll a separate
"LocalStack version" of the infrastructure code.

---

## Goals

1. Use LocalStack to develop and test an AWS serverless app entirely locally.
2. Build it with Terraform following industry best practices (least-privilege
   IAM, reusable modules, environment separation), not just a working demo.
3. Wire up real CI/CD with GitHub Actions — both a fast LocalStack validation
   loop, and eventually automated deployment to real AWS.
4. Borrow patterns from a reviewed production reference architecture
   (`aws-serverless-app`) where they genuinely apply, and skip the ones that
   solve problems this project doesn't have yet.
5. Target end state: `local` (LocalStack) → `DEV` → `QA` → `UAT` → `PROD`,
   with `PROD` fully isolated in its own AWS account and requiring strict
   manual approval for any deploy or destructive action. Not built yet —
   see `docs/real-aws-migration-checklist.md`, Step 2.5, for the reasoning
   and incremental path there.

## Core design principle

**Same Terraform code everywhere. Only the wrapper and the surrounding
scaffolding change.** Nothing in any `.tf` file branches on "am I running
against LocalStack or real AWS." Local/CI validation uses a wrapper
(`tflocal` / `lstk terraform`) that injects endpoint overrides at runtime;
real AWS uses plain `terraform` with real credentials. If a change ever
requires an `if localstack` branch in the code, that's a sign something is
structured wrong.

---

## Architecture

```
src/messages-api/handler.py
  Plain Python — the app logic. No AWS/Terraform coupling.
        │
        │ zipped and deployed by
        ▼
infra/modules/lambda/
  Reusable module: Lambda + log group + least-privilege IAM role/policy +
  optional function URL. Knows nothing about DynamoDB or this specific app —
  callers pass in extra IAM statements for their own app-specific grants.
        │
        ├── infra/environments/local/     targets YOUR LocalStack container
        │     • DynamoDB table + calls the module
        │     • no provider "aws" block (tflocal/lstk inject their own)
        │     • function_url_auth = NONE (fine — never leaves your machine)
        │
        └── infra/environments/dev/       targets REAL AWS (670069047744)
              • DynamoDB table + calls the module
              • explicit provider "aws" block
              • function_url_auth = AWS_IAM (never NONE against real AWS)
              • state: in S3 (infra/bootstrap's bucket) — see Bootstrap below

infra/bootstrap/
  Account-wide, shared within one account — NOT per-environment.
  Today: one account (670069047744), one bootstrap, shared by `dev` (and
  `qa`/`uat` if they land here too). Creates:
    • S3 state bucket (versioned, encrypted, public access blocked)
    • GitHub OIDC provider (trusts token.actions.githubusercontent.com)
    • GitHub Actions IAM role, scoped to this repo + this project's resources

  Target (not yet built): PROD gets its OWN separate AWS account for full
  isolation — its own bootstrap, its own OIDC provider (created fresh, not
  referenced), its own distinct role ARN. See
  docs/real-aws-migration-checklist.md, Step 2.5, for the reasoning and
  incremental sequence.
```

## Bootstrap: what it is, why it exists, and when it must run

`infra/bootstrap/` is a small, separate Terraform config — not a module, not
an environment. It creates account-*wide* scaffolding — everything that
depends on it lives in the same AWS account as the bootstrap itself:

- An S3 bucket to hold Terraform state remotely (versioned, encrypted,
  public access blocked)
- A reference to the GitHub OIDC identity provider (see gotcha below)
- An IAM role GitHub Actions will assume, scoped to this repo and this
  project's resources only

**Why it's separate from `infra/environments/`:** none of the above belongs
to any one environment folder — it runs once per AWS account, full stop,
regardless of how many environments get built on top of it *in that
account*.

**Important — this is per-account, not universal.** Today there's exactly
one bootstrap, in account `670069047744`, and `dev` uses it. That does
**not** mean `prod` will automatically share it. The target architecture
(see `docs/real-aws-migration-checklist.md`, Step 2.5) puts PROD in its
**own separate AWS account** for real isolation — which means PROD needs
its **own** bootstrap applied there too: its own state bucket, its own
freshly-created OIDC provider (this account's one was *referenced* because
it already existed; a new account won't have one yet, so that same
`data` block would need to become a `resource` there), and its own
distinct `github_actions_role_arn`. "One bootstrap total" only holds if
you deliberately choose single-account for every environment — it isn't a
property of bootstrap itself.

**Why the sequencing matters — this has to run *before* any environment's
`backend.tf` can work:** a `backend "s3" { bucket = "..." }` block in an
environment config only tells Terraform where to *look* for its state — it
doesn't create that bucket. If you point an environment at a bucket that
doesn't exist yet, `terraform init` fails immediately (`NoSuchBucket` or
similar). So the order is fixed: bootstrap must be applied first, and only
then can an environment's `backend.tf` reference something real. This is
exactly why `dev/backend.tf` didn't exist until after bootstrap was applied
— it would have been a reference to nothing.

**How to run it** (once, by a human with real AWS credentials — not
automated, and not meant to be):
```bash
cd infra/bootstrap
export AWS_PROFILE=<your-profile>
terraform init
terraform plan  -var="terraform_state_bucket_name=<globally-unique-name>"
terraform apply -var="terraform_state_bucket_name=<globally-unique-name>"
```

**Gotcha discovered while building this — check before you ever touch
bootstrap again:** the GitHub OIDC provider (`token.actions.githubusercontent.com`)
is a *singleton per AWS account* — only one can exist, regardless of how
many projects/repos use it. This account already had one, created by a
different project's bootstrap. Trying to `resource`-create a second one
fails with `EntityAlreadyExists`. That's why `infra/bootstrap/main.tf` uses
`data "aws_iam_openid_connect_provider" "github"` (a lookup) instead of
`resource` (a creation) — if you ever rewrite this file, keep it that way,
or check `aws iam list-open-id-connect-providers` first if you're not sure.

**Second gotcha discovered while building this — the OIDC `sub` claim
format is not what most docs/tutorials show.** The first deploy attempt
failed with `Not authorized to perform sts:AssumeRoleWithWebIdentity` even
though the trust policy looked correct. Decoding the actual token GitHub
sent (via a temporary debug step in the workflow) revealed the real `sub`
claim:
```
repo:tulsirai@16186091/localstack-rnd@1312311804:environment:dev
```
Not the plain `repo:tulsirai/localstack-rnd:environment:dev` the classic
docs describe — GitHub embeds immutable owner/repo IDs directly in the
claim using `@ID` suffixes. A trust policy condition of
`repo:tulsirai/localstack-rnd:*` never matches this, since it requires a
literal `/` right after `tulsirai`, but the real claim has `@16186091`
there instead. Fixed by adding a second `StringLike` value covering the ID
form: `repo:tulsirai@*/localstack-rnd@*:*` (both patterns are kept, since
`StringLike` matches if *any* listed value matches — defensive in case
GitHub ever sends the classic format too). If you ever see this exact
error with a trust policy that "looks right," decode a real token first
before assuming the policy logic is wrong — see the debug snippet in git
history (`fix/oidc-sub-claim-format` branch) for how.

**Third gotcha — the GitHub Actions role needed a permission Step 1 never
tested.** Step 1 validated the *Lambda's own execution role* against real
AWS. It never exercised the *GitHub Actions deploy role*, since that role
didn't exist yet. The first real `infra-deploy.yml` run got past OIDC and
`terraform init`, then failed during `terraform plan`'s state refresh:
```
AccessDeniedException: ...GitHubActions is not authorized to perform:
lambda:GetFunctionCodeSigningConfig
```
The AWS provider calls this during every `aws_lambda_function` refresh —
even when no code-signing config is attached — just to check. It wasn't in
the original `LambdaManagement` statement's read-action list. Added
`lambda:GetFunctionCodeSigningConfig` and it resolved. Worth remembering:
**a new IAM role always needs its own "expect AccessDenied, add the
missing statement" pass**, even one built from a reviewed, working
template — Step 1's validation doesn't automatically extend to every role
that comes after it.

**Bootstrap's own state is local, deliberately** — the one exception to
"everything real uses remote state." The bucket it creates can't hold its
own state on its very first run (chicken-and-egg). That local state file is
the only record of exactly what bootstrap created — don't delete it, and
don't casually re-run `apply` here without knowing what you're changing.

**Current real values** (from the last apply, so nobody has to re-derive
them):
- State bucket: `localstack-rnd-tf-state-670069047744`
- GitHub Actions role: `arn:aws:iam::670069047744:role/localstack-rnd-github-actions-role`

**Teardown order, if this ever needs to be undone:** destroy every
environment first (`dev`, `prod`, whatever exists), *then* destroy
bootstrap last. Bootstrap owns the bucket and role that environments
depend on — destroying it first would strand them.

## Repository structure

```
.
├── src/
│   └── messages-api/
│       ├── handler.py           # Lambda source, standalone and testable
│       └── requirements.txt
├── infra/
│   ├── modules/
│   │   └── lambda/              # Reusable Lambda module (see Architecture)
│   ├── bootstrap/                # Run once per AWS account, by a human
│   └── environments/
│       ├── local/                # LocalStack — validated by CI on every PR
│       └── dev/                  # Real AWS — deployed automatically on merge
├── .github/workflows/
│   ├── localstack-ci.yml         # Automated: spins up ephemeral LocalStack
│   │                              # per PR, applies infra/environments/local
│   └── infra-deploy.yml          # Automated: OIDC + terraform apply against
│                                  # infra/environments/dev, on merge to main
├── docs/
│   └── real-aws-migration-checklist.md   # Forward-looking plan, step by step
└── README.md                     # This file — current state, not the plan
```

`docs/real-aws-migration-checklist.md` is where the step-by-step forward plan
and its rationale live. This README describes how the system works *today*;
the checklist tracks what's *next*. Keep decisions in one place, not both —
if something here and the checklist ever disagree, the checklist's dated
entries win (they're the most recently reasoned-through).

---

## Status

| Piece | State |
|---|---|
| LocalStack local dev (`lstk`) | ✅ Working |
| `infra/modules/lambda` + `infra/environments/local` | ✅ Built, refactored from an initial single-file version |
| LocalStack CI (`localstack-ci.yml`) | ✅ Automated, green on every PR to `main` |
| Real-AWS validation pass (Step 1) | ✅ Done manually — zero `AccessDenied` errors, confirming the least-privilege IAM policy (authored against LocalStack, which doesn't enforce IAM) is correct against real enforcement |
| `infra/environments/dev` | ✅ **Live** — deployed to account `670069047744`, verified via `aws lambda invoke` (write + read) |
| `infra/bootstrap` (state bucket + OIDC + GitHub Actions role) | ✅ Applied — real state bucket + IAM role exist in account `670069047744` |
| `dev/backend.tf` (real S3 remote state) | ✅ Applied — state confirmed living in S3 (encrypted, versioned), not on any laptop |
| GitHub repo wiring (secrets, Environments with approval gates) | ✅ `GH_ACTIONS_ROLE_ARN` secret set; `dev` (no gate) and `prod` (1 required reviewer) Environments created |
| Automated real-AWS deploy workflow (`infra-deploy.yml`) | ✅ **Working** — merge to `main` triggers OIDC-authenticated `terraform apply` against `dev`, no human running commands |
| Code/infra deploy split (`aws-serverless-app` pattern) | ⏳ Not started |

**In plain terms: both CI (automated LocalStack validation) and CD
(automated real-AWS deployment) exist today.** Getting CD working surfaced
two real gotchas along the way — see the Bootstrap section above for the
OIDC `sub` claim format issue, and the note below for a missing
least-privilege permission on the GitHub Actions role itself (distinct
from the Lambda execution role's permissions, which Step 1 already
validated) — both are fixed and documented, not just worked around.

---

## Working locally

```bash
lstk start
cd infra/environments/local
tflocal init
tflocal apply -auto-approve
```

## Known gaps / things to fix before they bite

- **DynamoDB table naming isn't environment-prefixed.** The Lambda function
  and IAM role are (`localstack-rnd-dev-messages-api`), but the table is
  hardcoded to `Messages` in each environment's `main.tf`. Fine with only
  `dev` existing; will collide the moment a second real-AWS environment
  (e.g. `prod`) shares this account. Fix before creating one.
