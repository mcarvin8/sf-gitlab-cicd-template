# AGENTS.md

Orientation file for coding agents (Cursor, Claude Code, Codex, Aider, etc.).  
This document provides **context and guardrails**, not exhaustive rules.  
Defer to your tool's capabilities and developer instructions when appropriate.

---

## What this repo is

A **Salesforce DX (SFDX) metadata repository** deployed via **GitLab CI/CD** across multiple environments using the org branching model.

### Core characteristics

- **Delta-driven deployments via sfdx-git-delta**
  - There is **no committed deployment package.xml**
  - The CI pipeline generates the deployment package automatically from the git diff at validate and deploy time using `sfdx-git-delta`
  - Metadata not captured by the git diff is not deployed — make sure every file that needs to ship is actually changed in the MR/commit
  - No wildcards allowed in any package declaration

- **Apex test selection via annotations**
  - CI executes only tests referenced in `@tests:` annotations on changed classes/triggers
  - All non-test Apex classes and triggers must have a valid `@tests:` annotation

- **Promotion-based delivery model**
  - The same story branch is promoted across environments via separate MRs

---

## Branching & environment model

| Environment | Purpose | Branch | Deployment Trigger |
|------------|--------|--------|--------------------|
| Dev (Shared) | Integration | `develop` | Merge to `develop` |
| QA / UAT | Validation | `fullqa` | Merge to `fullqa` |
| Production | Live | `main` | Merge to `main` |

### Promotion flow (required)

```
story branch → develop → fullqa → main
```

- **Three MRs per change are required**
- Each MR must originate from the **same story branch**
- Do not rely on branch-to-branch merges for promotion

---

## Universal hard rules

1. **No secrets in commits** — never commit credentials, tokens, keys, or `.env` files
2. **No direct pushes to protected branches** — `develop`, `fullqa`, and `main` require MRs
3. **Do not edit profiles** — use Permission Sets instead
4. **Branch from `main` only** — do not branch from `develop` or `fullqa`

---

## Declaring metadata to deploy

The deployment package is **generated automatically** from the git diff. Whatever files your MR/commit changes is what gets deployed.

### Destructive changes

- **Push pipelines**: deleting metadata files triggers a destructive deploy automatically via sfdx-git-delta — no action required
- **Web pipelines**: trigger a pipeline on the org branch with `$PACKAGE` set to sf-package-list format to destroy specific metadata

---

## Conflict resolution rules

### General

- Resolve conflicts **locally using git**
- Do **not** use GitLab UI conflict resolver
- Do **not** rebase story branches
- Do **not** merge target branches into story branches

### `force-app/` metadata

- Resolve **manually and intentionally**
- Preserve intended story branch changes and any necessary target branch changes
- Escalate if unclear

---

## Repository structure

```
force-app/main/default/
  classes/
  triggers/
  objects/
  flows/
  layouts/
  lwc/
  aura/
  permissionsets/
  profiles/        (read-only)
  customMetadata/
scripts/
  bash/            deployment, destroy, rollback, sandbox scripts
  packages/        pre-made package.xml files for metadata retrieves
  pmd/             PMD rulesets for static analysis
.gitlab/
  workflows/       pipeline YAML (base-templates, core-jobs, orgs/, etc.)
```

---

## CI/CD entry points

- `.gitlab-ci.yml` — pipeline definition and global variables
- `.gitlab/workflows/base-templates.yml` — shared job templates
- `.gitlab/workflows/orgs/<org>.yml` — per-org validate/deploy/destroy jobs

---

## Toolchain

- Salesforce CLI (`sf`) with plugins: sfdx-git-delta (`>= 7.3.0`, needs `--merge-base`), apex-code-coverage-transformer, sf-package-list, apextestlist (`>= 1.15.0`, needs `--fail-on-empty`)
- GitLab CI runners (Docker-based, image defined in `Dockerfile`)
- Pre-commit hooks (lint-staged: ESLint + Prettier, including Apex/XML plugins)

---

## Common pitfalls ("sharp edges")

1. **Missing `@tests:` annotations** — results in zero tests running and a potential CI failure for Apex deployments
2. **Profiles edited** — changes ignored or rejected; use Permission Sets
3. **Wrong branching strategy** — branching from `develop`/`fullqa` causes conflicts during promotion
4. **Environment-specific values hardcoded** — handled at deploy time via sfdx-project.json replacements or CI variables
5. **ConnectedApp consumerKey left in source** — CI pipeline strips it automatically via `sed`; don't re-add it

---

## Agent guidance: change types

### Good candidates for automation

- Apex test classes
- Validation rules
- Permission set updates
- Documentation
- Small refactors with existing coverage
- Custom labels and translations

### Requires human review

- Flows (high blast radius)
- Custom Metadata changes (may drive business logic via CMT switches)
- Triggers
- Destructive changes
- Managed package metadata

---

## MR review checklist

Agents should verify:

1. **`@tests:` annotations present** on all changed non-test Apex classes and triggers
2. **No secrets** committed
3. **No profile edits**
4. **Proper reviewers assigned**
5. **Sandbox validation completed** (`test:predeploy:<org>` job passed)

---

## Sandbox usage

- Personal sandbox → development/testing
- Dev sandbox → integration validation
- QA sandbox → business validation
- Production → final deployment

---

## General Salesforce guidance

- Prefer **declarative solutions** over code
- Follow naming conventions for metadata
- Use **Permission Sets**, not profiles
- Avoid hardcoding IDs or environment-specific values

---

## Working principles for agents

- The deployment package is **auto-generated** by sfdx-git-delta at CI time — never hand-create or edit it
- Prioritize **safe, minimal changes** — only touch metadata relevant to the task
- Avoid modifying unrelated metadata
- Add `@tests:` annotations to every non-test Apex file you create or modify
- Escalate when impact is unclear
- Preserve **promotion integrity across environments**
