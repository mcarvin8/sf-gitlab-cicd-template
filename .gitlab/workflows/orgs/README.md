# Org-Specific CI/CD Configuration

This directory contains individual YAML files for each Salesforce org that participates in the CI/CD pipeline. Each org has its own dedicated file containing all deployment jobs (validate, unit test, deploy, destroy) for that environment.

## Current Orgs

- **`dev.yml`** - Development sandbox
- **`fullqa.yml`** - Full QA sandbox
- **`production.yml`** - Production

## Adding a New Org

### Step 1: Create the Org YAML File

Copy an existing org file as your template:

```bash
cp .gitlab/workflows/orgs/dev.yml .gitlab/workflows/orgs/staging.yml
```

### Step 2: Update Job Names and Variables

Edit every job in the new file. Replace all `dev` / `develop` / `SANDBOX` references with your org's values.

#### Job names to define:
- `test:unit:[ORG]` / `test:postrun:[ORG]`
- `test:predeploy:[ORG]`
- `deploy:[ORG]`
- `destroy:[ORG]` (web pipeline)
- `destroy:[ORG]:push` (push pipeline)

#### Per-job values to update:
| Field | What to set |
| --- | --- |
| `resource_group` | unique name per org (e.g. `staging`) |
| `AUTH_ALIAS` | Salesforce CLI alias (e.g. `STAGING`) |
| `AUTH_URL` | CI variable holding the sfdx-url (e.g. `$STAGING_AUTH_URL`) |
| `environment.name` | e.g. `validate-staging`, `staging` |
| `environment.url` | CI variable for the org URL (e.g. `$STAGING_ORG_URL`) |
| Branch name in rules | e.g. `'staging'` |
| Disabled guard variable | e.g. `$STAGING_DISABLED` |

### Step 3: Include the New Org File

Add your new org file to `.gitlab-ci.yml`:

```yaml
include:
  - local: '.gitlab/workflows/base-templates.yml'
  - local: '.gitlab/workflows/core-jobs.yml'
  - local: '.gitlab/workflows/test-quality-jobs.yml'
  - local: '.gitlab/workflows/maintenance-pipeline.yml'
  - local: '.gitlab/workflows/orgs/dev.yml'
  - local: '.gitlab/workflows/orgs/fullqa.yml'
  - local: '.gitlab/workflows/orgs/production.yml'
  - local: '.gitlab/workflows/orgs/staging.yml'   # ← add here
```

### Step 4: Configure GitLab CI/CD Variables

In your GitLab project settings, add:

- **`STAGING_AUTH_URL`** - `sf org login sfdx-url` value for the staging org
- **`STAGING_ORG_URL`** - display URL for the GitLab environment (cosmetic)
- **`STAGING_DISABLED`** - optional; set to any value to disable deploys to staging

---

## Org File Template

```yaml
####################################################
# [ORG_NAME] Org Jobs
####################################################

test:unit:[ORG_NAME]:
  extends: .test-unit
  rules:
    - if: $CI_PIPELINE_SOURCE == 'schedule' && $JOB_NAME == 'unitTest' && $CI_COMMIT_REF_NAME == '[BRANCH_NAME]'
      when: always
    - when: never
  variables:
    AUTH_ALIAS: [AUTH_ALIAS]
    AUTH_URL: $[AUTH_URL_VAR]

test:postrun:[ORG_NAME]:
  extends: .test-postrun
  rules:
    - if: $CI_PIPELINE_SOURCE == 'schedule' && $JOB_NAME == 'unitTest' && $CI_COMMIT_REF_NAME == '[BRANCH_NAME]'
      when: delayed
      start_in: 90 minutes
    - when: never
  needs: ['test:unit:[ORG_NAME]']
  variables:
    AUTH_ALIAS: [AUTH_ALIAS]
    AUTH_URL: $[AUTH_URL_VAR]

test:predeploy:[ORG_NAME]:
  extends: .validate-metadata
  stage: test
  resource_group: [ORG_NAME]
  rules:
    - if: $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME == 'develop' || $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME == 'fullqa' || $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME == $CI_DEFAULT_BRANCH
      when: never
    - if: $CI_MERGE_REQUEST_TARGET_BRANCH_NAME == '[BRANCH_NAME]'
      when: manual
  allow_failure: false
  variables:
    AUTH_ALIAS: [AUTH_ALIAS]
    AUTH_URL: $[AUTH_URL_VAR]
  environment:
    name: validate-[ORG_NAME]
    url: $[ORG_URL_VAR]

deploy:[ORG_NAME]:
  extends: .deploy-metadata
  stage: deploy
  resource_group: [ORG_NAME]
  rules:
    - if: $[DISABLED_VAR]
      when: never
    - if: '$CI_COMMIT_MESSAGE =~ /chore\(metadata-retrieval\):/i'
      when: never
    - if: $CI_COMMIT_REF_NAME == '[BRANCH_NAME]' && $CI_PIPELINE_SOURCE == 'push'
      when: always
  allow_failure: false
  variables:
    AUTH_ALIAS: [AUTH_ALIAS]
    AUTH_URL: $[AUTH_URL_VAR]
  environment:
    name: [ORG_NAME]
    url: $[ORG_URL_VAR]

destroy:[ORG_NAME]:
  extends: .delete-metadata
  stage: destroy
  resource_group: [ORG_NAME]
  rules:
    - if: $[DISABLED_VAR]
      when: never
    - if: $CI_COMMIT_REF_NAME == '[BRANCH_NAME]' && $CI_PIPELINE_SOURCE == 'web' && $PACKAGE
      when: always
  allow_failure: false
  variables:
    AUTH_ALIAS: [AUTH_ALIAS]
    AUTH_URL: $[AUTH_URL_VAR]
  environment:
    name: [ORG_NAME]
    url: $[ORG_URL_VAR]

destroy:[ORG_NAME]:push:
  extends: .delete-metadata-push
  stage: destroy
  resource_group: [ORG_NAME]
  rules:
    - if: $[DISABLED_VAR]
      when: never
    - if: '$CI_COMMIT_MESSAGE =~ /chore\(metadata-retrieval\):/i'
      when: never
    - if: $CI_COMMIT_REF_NAME == '[BRANCH_NAME]' && $CI_PIPELINE_SOURCE == 'push'
      when: always
  allow_failure: true
  variables:
    AUTH_ALIAS: [AUTH_ALIAS]
    AUTH_URL: $[AUTH_URL_VAR]
  environment:
    name: [ORG_NAME]
    url: $[ORG_URL_VAR]
```

### Template Placeholders

| Placeholder | Example |
| --- | --- |
| `[ORG_NAME]` | `staging` |
| `[BRANCH_NAME]` | `staging` |
| `[AUTH_ALIAS]` | `STAGING` |
| `[AUTH_URL_VAR]` | `STAGING_AUTH_URL` |
| `[ORG_URL_VAR]` | `STAGING_ORG_URL` |
| `[DISABLED_VAR]` | `STAGING_DISABLED` |

---

## Updating an Existing Org

Edit the org's YAML file directly. Changes are isolated — no other files need touching.

## Removing an Org

1. Delete the file: `rm .gitlab/workflows/orgs/staging.yml`
2. Remove its `include:` line from `.gitlab-ci.yml`
3. Clean up the org's CI/CD variables (optional)

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Jobs not appearing | `include:` line added to `.gitlab-ci.yml`? |
| Auth failures | `AUTH_URL` variable set and contains a valid sfdx-url? |
| Wrong jobs triggering | Branch names in rules match your git branches? |
| Resource group conflicts | Resource group names unique per org? |
| Push destroy always skipped | Expected — `allow_failure: true`, exits 0 when delta has no destructive types |
