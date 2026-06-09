# AGENTS.md

Orientation file for coding agents (Cursor, Claude Code, Codex, Aider, etc.).  
This document provides **context and guardrails**, not exhaustive rules.  
Defer to your tool's capabilities and developer instructions when appropriate.

---

## What this repo is

A **Salesforce DX (SFDX) metadata repository** deployed via **GitLab CI/CD** across multiple environments using the org branching model.

### Core characteristics

- **Delta-driven deployments via sfdx-git-delta**
  - There is **no committed `manifest/package.xml`**
  - The CI pipeline generates the deployment package automatically from the git diff at validate and deploy time using `sfdx-git-delta`
  - To include metadata not captured by the git diff, add a `<Package>` block to the MR description or merge commit message (see below)
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

The deployment package is **generated automatically** from the git diff. You do not create or edit `manifest/package.xml`.

### When the git diff is sufficient

If your changes are fully captured by the files you modified, no extra declaration is needed — the pipeline handles it.

### When you need extra metadata

Add a `<Package>` block to the **MR description** (for validates) or the **merge commit message** (for deploys):

```
<Package>
MetadataType: Member1, Member2
MetadataType2: Member1
</Package>
```

This is merged with the git-delta package by `sf-package-combiner`. Use it for metadata that is not file-tracked or that must be included alongside changed files.

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
- `scripts/bash/generate_delta_package.sh` — delta package generation logic

---

## Toolchain

- Salesforce CLI (`sf`) with plugins: sfdx-git-delta, apex-code-coverage-transformer, sf-package-combiner, sf-package-list, apextestlist
- GitLab CI runners (Docker-based, image defined in `Dockerfile`)
- Pre-commit hooks (lint + secret scanning)

---

## Common pitfalls ("sharp edges")

1. **Missing `@tests:` annotations** — results in zero tests running and a potential CI failure for Apex deployments
2. **Profiles edited** — changes ignored or rejected; use Permission Sets
3. **Wrong branching strategy** — branching from `develop`/`fullqa` causes conflicts during promotion
4. **Secrets in commits** — blocked by hooks or CI
5. **Environment-specific values hardcoded** — handled at deploy time via sfdx-project.json replacements or CI variables
6. **ConnectedApp consumerKey left in source** — `package_check.py` strips it automatically; don't re-add it

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
6. **`<Package>` block in MR description** if extra metadata beyond the git diff is needed

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

- The deployment package is **auto-generated** — never create or edit `manifest/package.xml`
- Prioritize **safe, minimal changes** — only touch metadata relevant to the task
- Avoid modifying unrelated metadata
- Add `@tests:` annotations to every non-test Apex file you create or modify
- Escalate when impact is unclear
- Preserve **promotion integrity across environments**
