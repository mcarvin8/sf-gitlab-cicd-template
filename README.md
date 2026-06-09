# Salesforce DX Project Template - Gitlab CI/CD

A batteries-included **Salesforce DX (SFDX) project template** for teams running the **org development model** (long-running branches per org, no scratch orgs or unlocked packages). It is the result of my work building a custom Salesforce CI/CD model on top of the Salesforce CLI (`sf`), a handful of open-source plugins (several of which I authored), and a set of reusable shell/Python helpers.

Fork or clone this repository as the starting point for a new SFDX project and you get an opinionated, end-to-end CI/CD setup out of the box - GitLab pipelines, incremental deploys via `sfdx-git-delta`, specified Apex test selection, SonarQube quality gates, rollbacks, sandbox refresh automation, Slack notifications, Einstein Bot per-org replacements, and more.

> The pipeline lives under `.gitlab/workflows/` and is wired up in `.gitlab-ci.yml`. The bash, Python, and config that power it all live under `scripts/` and at the repo root. Org-specific values (branch names like `dev`/`fullqa`, environment URLs, runner tags) are configured through CI/CD variables — see [Custom CI/CD Variables](#custom-cicd-variables).

<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>

- [What's in the Template](#whats-in-the-template)
- [Salesforce CLI Plugins](#salesforce-cli-plugins)
- [Getting Started](#getting-started)
- [CI/CD Model](#cicd-model)
- [Pipeline Stages](#pipeline-stages)
  - [Build Stage](#build-stage)
  - [Maintenance Stage (Optional Ad-Hoc Jobs)](#maintenance-stage-optional-ad-hoc-jobs)
  - [Test Stage](#test-stage)
  - [Quality Stage](#quality-stage)
  - [Destroy Stage](#destroy-stage)
  - [Deploy Stage](#deploy-stage)
- [Declare Metadata to Deploy](#declare-metadata-to-deploy)
  - [Validations and Deployment Packages](#validations-and-deployment-packages)
  - [Destructive Packages](#destructive-packages)
- [Declare Specified Apex Tests](#declare-specified-apex-tests)
  - [Validation and Deployment Apex Tests](#validation-and-deployment-apex-tests)
  - [Destructive Apex Tests](#destructive-apex-tests)
- [Connected Apps](#connected-apps)
- [Einstein Bots](#einstein-bots)
- [Slack Integration](#slack-integration)
- [Branch Protection](#branch-protection)
- [Adapting to Other CI/CD Platforms](#adapting-to-other-cicd-platforms)
  - [Pre-defined GitLab CI/CD Variables](#pre-defined-gitlab-cicd-variables)
  - [Custom CI/CD Variables](#custom-cicd-variables)

</details>

## What's in the Template

| Area | What you get |
| --- | --- |
| **SFDX project skeleton** | `sfdx-project.json`, `force-app/`, `config/`, `.forceignore`, namespace-ready packaged plugin dependencies |
| **CI/CD pipeline** | Modular GitLab pipeline split across `.gitlab/workflows/` (base templates, core jobs, test/quality, maintenance, and per-org files under `orgs/`) |
| **Deployment scripting** | `scripts/bash/` for delta package generation, incremental deploy, destroy, rollback, sandbox refresh, branch back-merge, Slack status posting, etc. |
| **Python helpers** | `scripts/python/` for Apex test annotation resolution and package validation (`package_check.py`) |
| **Reusable manifests** | Pre-made `package.xml` files in `scripts/packages/` (Apex, Automation, Bots, Objects, Security & Access, UI, etc.) for retrieves and targeted deploys |
| **Static analysis** | PMD rulesets (`scripts/pmd/enforced` + `scripts/pmd/encouraged`) and a SonarQube config (`sonar-project.properties`) |
| **Quality tooling** | ESLint, Prettier (with Apex + XML plugins), Husky pre-commit hooks, lint-staged, Jest (LWC) |
| **Docker** | `Dockerfile` and `.dockerignore` for a pipeline runner image that ships with `sf`, the plugins below, and OS deps |
| **Einstein Bot support** | `sfdx-project.json` `replacements` and `scripts/replacementFiles/` for swapping the bot run-as user per org |

## Salesforce CLI Plugins

The model relies on these Salesforce CLI plugins (I authored items 2-4):

1. [sfdx-git-delta](https://github.com/scolladon/sfdx-git-delta) - generate incremental `package.xml` / `destructiveChanges.xml` from git diffs
2. [apex-code-coverage-transformer](https://github.com/mcarvin8/apex-code-coverage-transformer) - convert Salesforce coverage JSON to JaCoCo / Cobertura / lcov
3. [sf-package-combiner](https://github.com/mcarvin8/sf-package-combiner) - merge multiple `package.xml` files
4. [sf-package-list](https://github.com/mcarvin8/sf-package-list) - declare metadata in a compact list format and convert to `package.xml`
5. [apextestlist](https://github.com/wisefoxme/apex-test-list) - resolve Apex test classes from `@tests:` / `@testsuites:` / `@isTest` annotations

All five are pre-installed in the `Dockerfile`.

## Getting Started

1. **Use this repo as a template** (GitLab fork / GitHub "Use this template" / `git clone`) and push it to your own remote.
2. **Update SFDX project metadata** in `sfdx-project.json` - clear the example `plugins.dependencies` namespaces and the `replacements` blocks if you don't need them.
3. **Configure your orgs** under `.gitlab/workflows/orgs/`. See [`.gitlab/workflows/orgs/README.md`](.gitlab/workflows/orgs/README.md) for a step-by-step guide to adding, renaming, or removing org files. The template ships with `dev.yml`, `fullqa.yml`, and `production.yml` as examples.
4. **Set CI/CD variables** in your GitLab project (see [Custom CI/CD Variables](#custom-cicd-variables)). Each org needs its own `*_AUTH_URL` secret containing an `sf org login sfdx-url` value.
5. **Pick a runner image**. The default is `$CI_REGISTRY_IMAGE:production`, built from the included `Dockerfile`. Build/push that image, or swap in your own image that has `sf` and the [plugins](#salesforce-cli-plugins) installed.
6. **Remove what you don't need.** Remove the SonarQube job, Slack hook, or maintenance jobs you don't want. The `SLACK_WEBHOOK_URL` global variable in `.gitlab-ci.yml` can be left empty to disable Slack.
7. **Push and open a merge request** against an org branch (e.g. `develop`) to see the validate pipeline run.

## CI/CD Model

The pipeline in `.gitlab-ci.yml` follows the **org branching model**: each Salesforce org has its own long-running git branch (e.g. `develop` -> Dev sandbox, `fullqa` -> Full QA, `main` -> Production). Merge requests targeting an org branch trigger validate jobs against that org; merging into the branch triggers a real deploy.

Per-org rules are isolated to one YAML file per org under `.gitlab/workflows/orgs/`, so you can customize a branching strategy (one branch per org, MR-to-`main` validates everything, fan-out to multiple orgs, etc.) without touching the shared job templates.

**There is no committed `manifest/package.xml`.** The deployment package is generated on the fly by `sfdx-git-delta` at validate and deploy time. Extra metadata not captured by the git diff can be declared in the MR description or merge commit message using the `<Package>` block format — see [Declare Metadata to Deploy](#declare-metadata-to-deploy).

## Pipeline Stages

The pipeline declares these stages in order:

```
build -> maintenance -> test -> quality -> destroy -> deploy
```

### Build Stage

Two jobs run here on different pipeline types:

- **Docker image build** (`build`) - rebuilds and pushes the runner image when `Dockerfile` or `.dockerignore` changes on a direct push to an org branch (`develop`, `fullqa`, `main`). Tags the image with the branch slug; a push to `main` also tags as `production`.
- **validate:package-list** - runs on MR pipelines targeting org branches. Validates the `<Package>` block in the MR description (if present) using `sf-package-list`, printing the parsed package list to logs. Fails fast before any org is contacted if the format is invalid.

### Maintenance Stage (Optional Ad-Hoc Jobs)

`.gitlab/workflows/maintenance-pipeline.yml` defines opt-in utility jobs. Jobs trigger via different sources — web pipelines, scheduled pipelines, push events, or merge request events — depending on their purpose:

- **rollback** - roll back a previous deployment using a `$SHA` variable. Triggered via a web pipeline. Creates a revert commit; `sfdx-git-delta` generates the correct delta automatically.
- **sandboxRefresh** - create or refresh a sandbox via the SF CLI, gated by a tag pattern (`sandbox_v*`). Triggered via a web pipeline.
- **prodBackfill** - automatically back-promotes commits from the default branch into lower org branches (e.g. `develop`, `fullqa`) on every push to `main`. Runs as part of every production push pipeline so the org branching model stays in sync. Without this, merge commits and other commits that land directly on `main` show up as unmerged changes in GitLab MRs on downstream branches. Allowed to fail so it never blocks a production deploy.

The jobs that perform git operations require a GitLab project access token with the `Maintainer` role and `api` + `write_repository` scopes. Provide it through these variables:

- `MAINTAINER_PAT_NAME` - display name of the token user
- `MAINTAINER_PAT_USER_NAME` - username of the token user
- `MAINTAINER_PAT_VALUE` - the token value itself

Remove any of these jobs you don't need.

#### Metadata Audit (`metadataAudit`)

Runs weekly on a scheduled pipeline. For each configured team, the `sf-git-ai-meta-insights` plugin generates a Markdown summary of metadata changes in the past week filtered by Jira key pattern, then uploads the result as an attachment to a Confluence page.

> **Note:** `sf-git-ai-meta-insights` is **not** pre-installed in the Docker image — the `metadataAudit` job installs it at runtime. This is intentional: the job is optional and infrequent, so there is no reason to add the plugin to the base image used by every pipeline job.

**Required CI/CD variables:**

| Variable | Purpose |
| --- | --- |
| `METADATA_AUDIT_TEAMS` | Space-separated list of teams to audit. Each entry is `team` or `team:jira-regex`. When no colon is given the team name is used as the commit-message filter. Example: `backend frontend:fe- platform` |
| `CONFLUENCE_USER` | Confluence username (email) |
| `CONFLUENCE_TOKEN` | Confluence API token |
| `CONFLUENCE_PAGE_ID` | ID of the Confluence page to attach summaries to |
| `CONFLUENCE_BASE_URL` | Confluence base URL, e.g. `https://yourorg.atlassian.net` |
The plugin (`sf-git-ai-meta-insights`) auto-detects the LLM provider from environment variables. Set credentials for whichever provider you use:

| Provider | Credential env var(s) | Default model |
| --- | --- | --- |
| `openai` | `OPENAI_API_KEY` or `LLM_API_KEY` | `gpt-4o-mini` |
| `openai-compatible` | `LLM_BASE_URL` (required); `LLM_DEFAULT_HEADERS` (optional) | `gpt-4o-mini` |
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-3-5-haiku-latest` |
| `google` | `GOOGLE_GENERATIVE_AI_API_KEY` or `GOOGLE_API_KEY` | `gemini-2.0-flash` |
| `bedrock` | Standard AWS credential chain (env / profile / role) | `anthropic.claude-3-5-haiku-20241022-v1:0` |
| `mistral` | `MISTRAL_API_KEY` | `mistral-small-latest` |
| `cohere` | `COHERE_API_KEY` | `command-r-08-2024` |
| `groq` | `GROQ_API_KEY` | `llama-3.1-8b-instant` |
| `xai` | `XAI_API_KEY` | `grok-2-latest` |
| `deepseek` | `DEEPSEEK_API_KEY` | `deepseek-chat` |

Set `LLM_PROVIDER` to force a specific provider when multiple credentials are present. Set `METADATA_AUDIT_FAIL_ON_ERROR=1` to exit on plugin failure (default: warn and continue).

#### Johnny Agent Promotion (`johnnyPromoteMR`)

When an AI triage service account (default: `svc-johnny-triage-agent`) opens a merge request targeting `main`, this job automatically creates companion MRs from the same source branch into `develop` and `fullqa`. This ensures agent-authored work flows through the full 3-branch promotion path rather than landing only in production.

The job is idempotent — if an open MR from the same source branch into the target already exists, it is skipped.

**Required CI/CD variables:**

| Variable | Purpose |
| --- | --- |
| `MAINTAINER_PAT_VALUE` | GitLab PAT with `api` scope (same token used by other maintenance jobs) |

**Optional CI/CD variables:**

| Variable | Default | Purpose |
| --- | --- | --- |
| `JOHNNY_BOT_USERNAME` | `svc-johnny-triage-agent` | GitLab username of the AI service account |
| `JOHNNY_PROMOTION_TARGETS` | `develop fullqa` | Space-separated list of branches to open companion MRs into |

Remove this job if you are not using an AI triage agent in your workflow.

### Test Stage

Validates and tests metadata changes before they merge.

- **Validate** - on a merge request, `sfdx-git-delta` generates an incremental package from `CI_MERGE_REQUEST_DIFF_BASE_SHA` to `HEAD`, merges any `<Package>` extra metadata from the MR description, and validates the combined package against the target org. One validate job per org (in `.gitlab/workflows/orgs/<org>.yml`).
- **Unit Test** - org-specific jobs (`test:unit:dev`, `test:unit:fullqa`, `test:unit:prd`) defined in each org file run all local Apex tests against that org. Each job is gated to its org branch, so scheduling a pipeline on `develop` with `$JOB_NAME=unitTest` runs tests only against the dev sandbox. Create a separate [scheduled pipeline](https://docs.gitlab.com/ci/pipelines/schedules/) per org branch and set `$JOB_NAME=unitTest` as a pipeline variable.
- **Code Coverage** - `test:postrun:<org>` runs 90 minutes after `test:unit:<org>`, retrieves results, and uses `apex-code-coverage-transformer` to produce Cobertura reports rendered natively in GitLab MR diffs.

### Quality Stage

Three jobs run here:

- **pmd-code-check** - PMD static analysis on changed Apex classes and triggers. Runs on MR pipelines targeting any org branch. Rules are in `scripts/pmd/enforced/default_apex.xml`. The enforced ruleset includes the `UnusedMethod` rule, which requires PMD to know which external namespaces call into your code — otherwise it false-positives on methods invoked by managed packages. The `plugins.dependencies` array in `sfdx-project.json` provides that namespace list. If your project has no managed package dependencies or you remove `UnusedMethod` from the ruleset, clear `plugins.dependencies` to an empty array.
- **quality** - SonarQube quality gate, consumes coverage from `apex-code-coverage-transformer`. Delete if you don't run Sonar or update for a different quality platform.
- **pre-merge-check** - MR branch compliance verification driven by `verify_branch_compliance.sh`. Posts a structured summary comment to the MR on every push. See below for full details.

#### Pre-Merge Compliance Checks (`verify_branch_compliance.sh`)

Runs on every MR pipeline targeting `main`, `fullqa`, or `develop` (configurable). Checks:

| Check | Default branch MRs | Sandbox MRs |
| --- | --- | --- |
| Branch age ≤ 30 days from default branch | ✓ | ✓ |
| Branch name matches `VALID_BRANCH_PREFIXES` | ✓ | ✓ |
| No forbidden merges from lower envs into source | ✓ | ✓ |
| Source branched from main (not from sandbox) | ✓ | ✓ |
| Merge conflict trial merge vs target | ✓ | — |
| `package_check.py` passes on delta package | ✓ | ✓ |
| Predeploy validate job passed | ✓ | ✓ |
| Source SHA merged + deployed to fullqa and develop | ✓ | — |
| Release branch: per-story deployment verification | ✓ | — |

Results are posted as a structured comment on the MR (previous comments from this script are deleted and replaced on each push).

**Configurable CI/CD variables:**

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEV_BRANCH` | `develop` | Name of the dev sandbox branch |
| `FULLQA_BRANCH` | `fullqa` | Name of the full QA branch |
| `DEV_DEPLOY_JOB` | `deploy:dev` | GitLab job name for dev deploys |
| `FULLQA_DEPLOY_JOB` | `deploy:fullqa` | GitLab job name for fullqa deploys |
| `DEV_PREDEPLOY_JOB` | `test:predeploy:dev` | GitLab job name for dev predeploy validate |
| `FULLQA_PREDEPLOY_JOB` | `test:predeploy:fullqa` | GitLab job name for fullqa predeploy validate |
| `PRD_PREDEPLOY_JOB` | `test:predeploy:prd` | GitLab job name for production predeploy validate |
| `VALID_BRANCH_PREFIXES` | _(unset)_ | Space-separated substrings required in MR source branch names. Leave unset to skip branch name enforcement. |

`MAINTAINER_PAT_VALUE` is required — the script uses it to query the GitLab API for pipeline/job status and to post/delete MR comments.

### Destroy Stage

Removes metadata from the target org. Two flavors are supported:

1. **Push-pipeline destroys** - deleting metadata files on the org branch triggers a destructive deploy generated by `sfdx-git-delta`. One destroy job per org (`destroy:*:push`). Allowed to fail when no destructive types are detected. Runs before the constructive deploy by default.
2. **Web-pipeline destroys** - trigger a web pipeline on the org branch with a `$PACKAGE` variable containing metadata in [sf-package-list](https://github.com/mcarvin8/sf-package-list) format. The pipeline converts that into `destructiveChanges.xml` before deploying. Use this for controlled, isolated destructions.

### Deploy Stage

Deploys constructive metadata to the target org once an MR merges to the org branch. One deploy job per org. `sfdx-git-delta` generates the incremental package from `CI_COMMIT_BEFORE_SHA` to `HEAD`; any `<Package>` block in the merge commit message is merged in via `sf-package-combiner`. The combined package is printed in list format to job logs via `sf-package-list` before deployment.

## Declare Metadata to Deploy

**Incremental packages are generated automatically** from the git diff using `sfdx-git-delta` — there is no `manifest/package.xml` to maintain. `sfdx-git-delta` runs at both validate and deploy time, diffing against the appropriate base SHA for each pipeline type.

### Validations and Deployment Packages

The git delta covers all metadata files changed in the MR or merge commit. To include additional metadata not captured by the diff, declare it in the **merge request description** (for validates) or **merge commit message** (for deploys) using the [sf-package-list](https://github.com/mcarvin8/sf-package-list) format. The `<Package>` tags are required:

```
<Package>
MetadataType: Member1, Member2, Member3
MetadataType2: Member1, Member2, Member3
Version: 60.0
</Package>
```

The list is converted to XML by `sf-package-list` and merged into the git-delta package by `sf-package-combiner`. The combined package is printed in list format to job logs so you can see exactly what will be deployed. Add `Version: 60.0` to force a specific API version; omit it to fall back to other API-version sources.

**Repo recommendations**

- Update the project's default MR description to include the `<Package>` template.

- Update the merge commit message template to include the MR description (`%{description}`).

### Destructive Packages

Two destroy patterns are provided per org. Use one or both depending on team size and process.

**Push pipelines** — `destroy:<org>:push`

`sfdx-git-delta` detects deleted metadata files in the commit and generates `destructiveChanges.xml` automatically. The destroy job runs as part of the normal push pipeline with no manual intervention.

- Best for small, git-savvy teams where every developer understands that deleting a file triggers a production deletion
- Risk on larger teams: any developer can accidentally destroy production metadata by deleting a file

**Web pipelines** — `destroy:<org>`

Triggered manually via **Run pipeline** in GitLab with `$PACKAGE` set to an [sf-package-list](https://github.com/mcarvin8/sf-package-list) formatted list of what to delete:

```
MetadataType: Member1, Member2, Member3
MetadataType2: Member1, Member2, Member3
```

The pipeline converts the list to `destructiveChanges.xml` before deploying.

- Best for larger teams or orgs where destructive operations need to be intentional and controlled
- Destruction requires someone to explicitly trigger a pipeline and declare what to delete — no accidental deletes from routine commits

Both jobs are included in each org file. If only one pattern fits your team, remove the other `destroy:*` job from the relevant org file.

## Declare Specified Apex Tests

Apex tests are required when a deployment includes Apex classes or triggers. The model uses **specified tests** rather than running every test in the org.

### Validation and Deployment Apex Tests

Test classes are resolved by the [apextestlist](https://github.com/wisefoxme/apex-test-list) plugin from source annotations. `package_check.py` gates whether tests are required (Apex present check, ConnectedApp secret stripping) before the plugin runs.

- Apex classes and triggers must be annotated with `@tests:` to declare their test classes.
- Use `@testsuites:` to declare Apex test suites instead of individual test classes.
- Files marked `@isTest` are automatically treated as their own test class.

### Destructive Apex Tests

Destroying Apex in production requires running Apex tests with the destructive deployment. Set `DESTRUCTIVE_TESTS` as a CI/CD variable to a space-separated list of test classes to run.

> Sandboxes do not require destructive tests.

## Connected Apps

When a Connected App is in the deployment package, its `<consumerKey>` element is stripped automatically by `package_check.py` before deploy to avoid Salesforce errors.

## Einstein Bots

To deploy Einstein Bots with this template:

- update `.forceignore` to exclude bot versions you do not want retrieved or deployed
- edit the files in `scripts/replacementFiles/` to set the running bot user per org
- update the `replacements` block in `sfdx-project.json` so each org gets the right substitution

> Remove the `replacements` block from `sfdx-project.json` if you aren't deploying bots.

## Slack Integration

Deploy, test, and destroy outcomes can be posted to a Slack channel. Set `SLACK_WEBHOOK_URL` in `.gitlab-ci.yml` (or as a CI/CD variable):

```yaml
SLACK_WEBHOOK_URL: https://hooks.slack.com/services/
```

Leave the variable empty or remove it to disable Slack notifications.

## Branch Protection

**Branches**

Protect each org branch (`develop`, `fullqa`, `main`) in **Settings → Repository → Protected branches**:

- Set "Allowed to merge" to Maintainers (or a custom role) to prevent direct deploys without review
- Enable "Pipelines must succeed" in **Settings → Merge requests** to block merges until the validate job passes

**CI/CD Environments**

Each org has two classes of environment defined in the pipeline:

| Environment | Jobs | Protect? |
| --- | --- | --- |
| `dev`, `fullqa`, `production` | deploy, destroy, unit test | Yes — restrict to Maintainers |
| `validate-dev`, `validate-fullqa`, `validate-production` | validate (MR only) | No — leave open |

Protect deploy/destroy environments in **Settings → CI/CD → Environments** by setting "Protected" and restricting access to Maintainers or a specific group. This ensures only authorised users can trigger real deployments or destructive operations.

`validate-*` environments **must remain unprotected**. Validate jobs run in merge request pipelines as the MR author. If the environment is protected and the author lacks the required role, GitLab blocks the pipeline from running entirely — contributors will be unable to validate their changes before merge.

## Adapting to Other CI/CD Platforms

The scripts in `scripts/bash/` and `scripts/python/` are not GitLab-specific - they read from environment variables. Wire up the same variables on another platform (GitHub Actions, Bitbucket Pipelines, Jenkins, Azure DevOps, etc.) and the rest of the model carries over. The plugin set and `Dockerfile` are also platform-agnostic.

### Pre-defined GitLab CI/CD Variables

| Variable | Purpose |
| --- | --- |
| `$CI_PIPELINE_SOURCE` | `push` triggers a deploy; `merge_request_event` triggers a validate |
| `$CI_ENVIRONMENT_NAME` | Salesforce org name (scripts treat `production` as production) |
| `$CI_JOB_STAGE` | `test`, `destroy`, or `deploy` |
| `$CI_JOB_STATUS` | `success` or `failure` (Slack only) |
| `$GITLAB_USER_NAME` | user who triggered the pipeline (Slack only) |
| `$CI_JOB_URL` | URL of the CI job log (Slack only) |
| `$CI_PROJECT_URL` | base URL of the repo (Slack only) |
| `$CI_MERGE_REQUEST_DIFF_BASE_SHA` | base SHA for sfdx-git-delta on validate pipelines |
| `$CI_COMMIT_BEFORE_SHA` | base SHA for sfdx-git-delta on push (deploy) pipelines |
| `$CI_MERGE_REQUEST_DESCRIPTION` | MR description; scanned for `<Package>` block on validates |
| `$CI_COMMIT_MESSAGE` | merge commit message; scanned for `<Package>` block on deploys |

### Custom CI/CD Variables

| Variable | Purpose |
| --- | --- |
| `$DEPLOY_PACKAGE` | path to the combined package generated at runtime (default: `manifest/package.xml`) |
| `$DEPLOY_TIMEOUT` | `sf` wait time in minutes for deploys/retrieves |
| `$DESTRUCTIVE_TESTS` | space-separated Apex test classes to run when destroying Apex in production |
| `$AUTH_ALIAS` | unique authorization alias per org |
| `$AUTH_URL` | unique SFDX auth URL per org (`sf org login sfdx-url` value) |
| `$SLACK_WEBHOOK_URL` | Slack webhook for status posts; leave empty to disable |
| `$RUNNER_TAG` | GitLab runner tag applied to all jobs via the `default:` block |
| `$DEV_ORG_URL` | display URL for the dev sandbox environment (cosmetic, shown in GitLab environments) |
| `$FULLQA_ORG_URL` | display URL for the full QA sandbox environment |
| `$PRODUCTION_ORG_URL` | display URL for the production environment |
| `$VALID_BRANCH_PREFIXES` | space-separated substrings required in MR source branch names; `pre-merge-check` fails branches that match none. Leave empty to skip enforcement. |
| `$CONFLUENCE_BASE_URL` | Confluence base URL for `metadataAudit` job (e.g. `https://yourorg.atlassian.net`) |
| `$MAINTAINER_PAT_NAME` / `$MAINTAINER_PAT_USER_NAME` / `$MAINTAINER_PAT_VALUE` | project access token used by maintenance jobs that push to the repo |
