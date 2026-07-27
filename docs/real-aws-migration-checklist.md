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

**Done as of 2026-07-25** — merged to `main` via PR #1.

- [x] `main.tf` refactored into `infra/modules/` + `infra/environments/` pattern
      (borrowed from `aws-serverless-app`)
- [x] Least-privilege IAM policies written into the module (even though
      LocalStack won't enforce them — this is where they get authored)
- [x] GitHub Actions workflow using `LocalStack/setup-localstack` + `tflocal`
      passing consistently on every push/PR
- [x] `LOCALSTACK_AUTH_TOKEN` (CI auth token, distinct from personal dev token)
      wired as a GitHub secret if any Pro features are used in CI

## Step 1 — Manual validation against a real AWS sandbox account (the "graduation exam")

**Done as of 2026-07-25** — validated against account `670069047744`
(`tarch` profile, `us-east-1`) using a throwaway
`infra/environments/sandbox-validation/` directory (created, used, destroyed,
and deleted — never committed). Zero `AccessDenied` errors on the first
`apply`: the least-privilege IAM policy authored against LocalStack (which
doesn't enforce IAM) turned out to be correct against real AWS enforcement.
Function URL auth was switched to `AWS_IAM` for this pass (not the `NONE`
used in `infra/environments/local/`), verified via `aws lambda invoke`
directly instead of curl, to avoid any public unauthenticated endpoint
touching the real internet.

- [x] Create or use an existing personal/sandbox AWS account (not shared with
      production workloads)
- [x] Configure real AWS CLI credentials locally (`aws configure` or SSO)
- [x] Run plain `terraform init && terraform plan` (not `tflocal`) against the
      module/environment code, targeting the sandbox account
- [x] Run `terraform apply` and fix whatever fails that LocalStack let slide —
      expect IAM `AccessDenied` errors first; add the missing policy
      statements (e.g. `dynamodb:PutItem`/`dynamodb:Scan` scoped to the table
      ARN, `logs:CreateLogStream`/`logs:PutLogEvents` scoped to the log group)
- [x] Verify the Lambda runtime string used (e.g. `python3.14`) is actually a
      published AWS Lambda runtime — confirmed via official AWS blog post
      announcing python3.14 support, and accepted without error by real AWS
- [x] Smoke-test the deployed function URL / API end-to-end, same as the local
      LocalStack smoke test
- [x] `terraform destroy` the sandbox once validated — this is a throwaway
      proof pass, not the real environment

## Step 2 — Bootstrap the real AWS account (run once, by a human, with elevated creds)

**Done as of 2026-07-25** — applied to account `670069047744`. Modeled on
`aws-serverless-app/infra/bootstrap/`, with two deliberate deviations:
no artifact bucket (not needed until the code/infra deploy split exists —
Step 4), and the OIDC provider is **referenced via a data source, not
created** — discovered during pre-flight checks that `aws-serverless-app`'s
own bootstrap had already registered `token.actions.githubusercontent.com`
in this same account, and OIDC providers are a singleton per URL per
account. Creating a second one would have failed with `EntityAlreadyExists`.

Outputs:
- `terraform_state_bucket_name = "localstack-rnd-tf-state-670069047744"`
- `github_actions_role_arn = "arn:aws:iam::670069047744:role/localstack-rnd-github-actions-role"`

- [x] S3 Terraform state bucket (versioned, SSE-encrypted, public access
      blocked), one key per environment
- [x] Native S3 state locking (`use_lockfile = true`, Terraform ≥1.10) —
      prefer this over the deprecated `dynamodb_table` lock option
- [x] IAM OIDC provider trusting `token.actions.githubusercontent.com` —
      already existed in this account; referenced, not recreated
- [x] IAM role for GitHub Actions, trust policy scoped to
      `repo:tulsirai/localstack-rnd:*` (tighten to `ref:refs/heads/main`
      later, once branch-scoped deploys matter)
- [x] Least-privilege permissions policy for that role — scoped to
      `arn:aws:lambda:...:function:localstack-rnd-*`,
      `arn:aws:iam::...:role/localstack-rnd-*`, the state bucket, and
      `arn:aws:dynamodb:...:table/*` (not yet project-scoped — see the
      DynamoDB table-naming gap noted in the README)
- [x] Commit `.terraform.lock.hcl` for this bootstrap config (don't repeat the
      gitignore gap seen in `aws-serverless-app`)
- [ ] S3 artifact bucket — deferred until Step 4 (code/infra deploy split)
      actually needs it

## Step 2.5 — Target account topology: multi-account, PROD isolated

**Clarified as of 2026-07-26 — this is the stated target, not a deferred
nice-to-have.** Per AWS's own official multi-account guidance
(Organizations / Control Tower / Well-Architected), production systems
should isolate PROD — ideally every environment — into its own AWS
account, not just a differently-named folder inside one shared account.
Single-account (what exists today) was always meant as a starting point,
not the end state.

What this changes going forward:

- `dev` staying in account `670069047744` is fine for now — not a final
  decision, just where things started.
- Step 2's bootstrap (already applied) covers exactly **one** account. Each
  additional isolated account needs its own near-identical bootstrap
  applied separately — producing its **own** OIDC provider (created fresh
  via `resource`, not referenced via `data`, since a brand-new account
  won't already have one registered) and its own distinct
  `github_actions_role_arn`.
- Step 3's GitHub Environments stop being just approval gates — each one
  (`dev`, `qa`, `uat`, `prod`) will eventually need its **own**
  environment-scoped `GH_ACTIONS_ROLE_ARN` secret, pointing at that
  environment's own account-specific role. Role ARNs embed the account ID;
  they can't be shared across accounts the way a single repo-level secret
  can today.
- PROD's protection becomes **two independent layers**, not one:
  required-reviewers on the GitHub Environment (Step 3) *and* full account
  isolation (this step). Neither substitutes for the other.

Recommended incremental sequence — deliberately not "stand up 4 accounts
at once":

- [ ] Set up AWS Organizations (if not already in place), with a
      management account distinct from any workload account
- [ ] Create a dedicated **PROD** account first — highest isolation value
      per unit of effort; `dev` keeps living in the existing account in
      the meantime, no rush to move it
- [ ] Apply a near-identical bootstrap to the new PROD account (expect the
      OIDC provider `resource` to actually create this time, not just
      reference an existing one)
- [ ] Decide whether QA/UAT get their own accounts too, or continue
      sharing the existing account with `dev` — revisit once PROD
      isolation is proven out, not before
- [ ] Move `GH_ACTIONS_ROLE_ARN` from a repo-level secret to
      environment-scoped secrets once more than one account exists — keep
      it repo-level for now, since only `dev`'s account exists today

## Step 3 — Wire up the GitHub repo

**Done as of 2026-07-26** — `dev` itself is live: deployed to account
`670069047744`, state confirmed in S3 (encrypted, versioned), verified via
`aws lambda invoke` (write + read both succeeded). `GH_ACTIONS_ROLE_ARN` is
saved as a repo-level secret, and both GitHub Environments exist (`prod`
with 1 required-reviewer protection rule, `dev` with none) — visually
confirmed on the Environments settings page. What's left is Step 4: the
workflow that actually uses this role and these environments to deploy
automatically, instead of a human running `terraform apply`.

- [x] Point `backend.tf` in the `dev` environment at the real state bucket —
      done directly (single-account, low-stakes personal project; the
      `-backend-config`-injection nuance matters more once multiple people
      or CI environments need different bucket values per run)
- [x] Add `GH_ACTIONS_ROLE_ARN` as a repository **secret** (the
      `github_actions_role_arn` output from bootstrap:
      `arn:aws:iam::670069047744:role/localstack-rnd-github-actions-role`) —
      will get a `prod`-environment-scoped override once PROD has its own
      account/role (Step 2.5)
- [ ] Add `ARTIFACT_BUCKET` as a repository **variable** — deferred along
      with the artifact bucket itself (Step 4)
- [x] Create GitHub Environments: `dev` (no gate, auto-deploy),
      `prod` (required reviewers) — `qa`/`uat` still skipped, no team-size
      need yet. Required-reviewers here is one of two protection layers
      for `prod`, not the only one — see Step 2.5 for the account-isolation
      layer

## Step 4 — Add the real-AWS deploy pipeline (separate workflow, not a modification of the LocalStack CI workflow)

**Done as of 2026-07-27** — `infra-deploy.yml` merged, triggered on merge
to `main`, and confirmed **actually working end-to-end**: OIDC role
assumption → `terraform init` → `plan` → `apply` against `dev`, no human
running commands. Deliberately scoped down: no bootstrap-placeholder-zip /
`ignore_changes` / separate `app-deploy.yml` yet, since this project
doesn't have the "frequent code changes independent of infra changes" pain
that split exists to solve. Terraform currently deploys code and infra
together in one `apply`, same as the manual runs so far — this workflow
just automates that, it doesn't change the deployment model.

Getting here surfaced two real bugs, both fixed and documented in the
README's Bootstrap section (not just patched silently):
1. **OIDC `sub` claim format** — GitHub's actual token embeds immutable
   owner/repo IDs (`repo:tulsirai@16186091/localstack-rnd@1312311804:...`),
   not the plain `repo:org/repo:...` most docs show. Trust policy needed a
   second `StringLike` value to match the real format.
2. **Missing `lambda:GetFunctionCodeSigningConfig`** on the GitHub Actions
   role — surfaced during `terraform plan`'s state refresh. A reminder that
   a new IAM role always needs its own least-privilege validation pass,
   even one built from a working template — Step 1 validated the Lambda's
   *execution* role, never this *deploy* role, since it didn't exist yet.

- [x] New workflow (`infra-deploy.yml`), triggered on push to `main` under
      **both** `infra/**` and `src/**` (not just `infra/**` — see note
      above on why), using OIDC (`aws-actions/configure-aws-credentials`)
      and plain `terraform` (not `tflocal`)
- [ ] Bootstrap-placeholder-zip pattern + `lifecycle { ignore_changes =
      [s3_key, s3_object_version, source_code_hash] }` — deferred until
      code changes actually need to ship independently of infra changes
- [ ] Separate `app-deploy.yml` for code-only changes — deferred alongside
      the above; depends on it
- [ ] Approval gate enforced on `prod` environment before `terraform apply`
      runs — moot until `infra/environments/prod` and its own
      account/bootstrap exist (Step 2.5)
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

- VPC / private networking for the Lambda
- Canary/weighted alias routing (`routing_config` on the alias, currently
  reserved via `ignore_changes` but unused)
- API Gateway in front of the function URL, if auth/throttling requirements
  grow beyond what `authorization_type = AWS_IAM` on the function URL covers
