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

| Field                   | What to set                                                 |
| ----------------------- | ----------------------------------------------------------- |
| `resource_group`        | unique name per org (e.g. `staging`)                        |
| `AUTH_ALIAS`            | Salesforce CLI alias (e.g. `STAGING`)                       |
| `AUTH_CLIENT_ID`        | CI variable holding the org's JWT client ID                 |
| `AUTH_JWT_KEY_FILE`     | Path from a GitLab File variable containing the private key |
| `AUTH_USERNAME`         | Salesforce username to authorize                            |
| `AUTH_INSTANCE_URL`     | Salesforce My Domain login URL                              |
| `environment.name`      | e.g. `validate-staging`, `staging`                          |
| `environment.url`       | CI variable for the org URL (e.g. `$STAGING_ORG_URL`)       |
| Branch name in rules    | e.g. `'staging'`                                            |
| Disabled guard variable | e.g. `$STAGING_DISABLED`                                    |

### Step 3: Include the New Org File

Add your new org file to `.gitlab-ci.yml`:

```yaml
include:
  - local: ".gitlab/workflows/base-templates.yml"
  - local: ".gitlab/workflows/core-jobs.yml"
  - local: ".gitlab/workflows/test-quality-jobs.yml"
  - local: ".gitlab/workflows/maintenance-pipeline.yml"
  - local: ".gitlab/workflows/orgs/dev.yml"
  - local: ".gitlab/workflows/orgs/fullqa.yml"
  - local: ".gitlab/workflows/orgs/production.yml"
  - local: ".gitlab/workflows/orgs/staging.yml" # ← add here
```

### Step 4: Configure GitLab CI/CD Variables

Create an external client app (or connected app where required) and upload the public certificate, following Salesforce's [JWT flow setup guide](https://developer.salesforce.com/docs/platform/sfdx-dev/guide/sfdx-dev-auth-jwt-flow.html). In your GitLab project settings, add:

For `PRODUCTION_JWT_CLIENT_ID`, use a **Connected App** if you run the `sandboxRefresh` job: Salesforce requires it when the CLI creates or refreshes sandboxes.

For JWT credentials belonging to a sandbox that will be refreshed, follow the manual [before-refresh backup](https://sfdx-hardis.cloudity.com/hardis/org/refresh/before-refresh/) and [after-refresh restore](https://sfdx-hardis.cloudity.com/hardis/org/refresh/after-refresh/) procedures. Back up the External Client App credentials before refreshing, then verify the restored consumer key matches that sandbox's `*_JWT_CLIENT_ID` and its certificate matches `*_JWT_KEY`. The before-refresh procedure can optionally delete backed-up apps to support a clean restore; this is not mandatory for every setup. These procedures are interactive and must not be added to CI. Connected Apps generally can't be restored after a Spring '26 refresh without Salesforce Support, so convert any sandbox app that must survive refresh to an External Client App first.

- **`STAGING_JWT_CLIENT_ID`** - OAuth consumer key for the app
- **`STAGING_JWT_KEY`** - private key; set the variable type to **File** so CI passes a temporary file path to Salesforce CLI
- **`STAGING_USERNAME`** - Salesforce username to authorize
- **`STAGING_INSTANCE_URL`** - org login URL, preferably the My Domain URL ending in `my.salesforce.com`
- **`STAGING_ORG_URL`** - display URL for the GitLab environment (cosmetic)
- **`STAGING_DISABLED`** - optional; set to any value to disable deploys to staging

Keep the private key out of the repository. Protect and scope the key variable to trusted pipelines where possible; merge-request validation jobs also need access to the credentials for the target org.

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
    AUTH_CLIENT_ID: $[JWT_CLIENT_ID_VAR]
    AUTH_JWT_KEY_FILE: $[JWT_KEY_VAR]
    AUTH_USERNAME: $[USERNAME_VAR]
    AUTH_INSTANCE_URL: $[INSTANCE_URL_VAR]

test:postrun:[ORG_NAME]:
  extends: .test-postrun
  rules:
    - if: $CI_PIPELINE_SOURCE == 'schedule' && $JOB_NAME == 'unitTest' && $CI_COMMIT_REF_NAME == '[BRANCH_NAME]'
      when: delayed
      start_in: 90 minutes
    - when: never
  needs: ["test:unit:[ORG_NAME]"]
  variables:
    AUTH_ALIAS: [AUTH_ALIAS]
    AUTH_CLIENT_ID: $[JWT_CLIENT_ID_VAR]
    AUTH_JWT_KEY_FILE: $[JWT_KEY_VAR]
    AUTH_USERNAME: $[USERNAME_VAR]
    AUTH_INSTANCE_URL: $[INSTANCE_URL_VAR]

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
    AUTH_CLIENT_ID: $[JWT_CLIENT_ID_VAR]
    AUTH_JWT_KEY_FILE: $[JWT_KEY_VAR]
    AUTH_USERNAME: $[USERNAME_VAR]
    AUTH_INSTANCE_URL: $[INSTANCE_URL_VAR]
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
    AUTH_CLIENT_ID: $[JWT_CLIENT_ID_VAR]
    AUTH_JWT_KEY_FILE: $[JWT_KEY_VAR]
    AUTH_USERNAME: $[USERNAME_VAR]
    AUTH_INSTANCE_URL: $[INSTANCE_URL_VAR]
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
    AUTH_CLIENT_ID: $[JWT_CLIENT_ID_VAR]
    AUTH_JWT_KEY_FILE: $[JWT_KEY_VAR]
    AUTH_USERNAME: $[USERNAME_VAR]
    AUTH_INSTANCE_URL: $[INSTANCE_URL_VAR]
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
    AUTH_CLIENT_ID: $[JWT_CLIENT_ID_VAR]
    AUTH_JWT_KEY_FILE: $[JWT_KEY_VAR]
    AUTH_USERNAME: $[USERNAME_VAR]
    AUTH_INSTANCE_URL: $[INSTANCE_URL_VAR]
  environment:
    name: [ORG_NAME]
    url: $[ORG_URL_VAR]
```

### Template Placeholders

| Placeholder           | Example                 |
| --------------------- | ----------------------- |
| `[ORG_NAME]`          | `staging`               |
| `[BRANCH_NAME]`       | `staging`               |
| `[AUTH_ALIAS]`        | `STAGING`               |
| `[JWT_CLIENT_ID_VAR]` | `STAGING_JWT_CLIENT_ID` |
| `[JWT_KEY_VAR]`       | `STAGING_JWT_KEY`       |
| `[USERNAME_VAR]`      | `STAGING_USERNAME`      |
| `[INSTANCE_URL_VAR]`  | `STAGING_INSTANCE_URL`  |
| `[ORG_URL_VAR]`       | `STAGING_ORG_URL`       |
| `[DISABLED_VAR]`      | `STAGING_DISABLED`      |

---

## Updating an Existing Org

Edit the org's YAML file directly. Changes are isolated — no other files need touching.

## Removing an Org

1. Delete the file: `rm .gitlab/workflows/orgs/staging.yml`
2. Remove its `include:` line from `.gitlab-ci.yml`
3. Clean up the org's CI/CD variables (optional)

## Troubleshooting

| Symptom                     | Check                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------ |
| Jobs not appearing          | `include:` line added to `.gitlab-ci.yml`?                                           |
| Auth failures               | JWT client ID, File-type private key, username, and My Domain URL variables are set? |
| Wrong jobs triggering       | Branch names in rules match your git branches?                                       |
| Resource group conflicts    | Resource group names unique per org?                                                 |
| Push destroy always skipped | Expected — `allow_failure: true`, exits 0 when delta has no destructive types        |
