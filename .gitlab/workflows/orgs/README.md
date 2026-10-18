# Org-Specific CI/CD Configuration

Every Salesforce org in the pipeline uses the same job template, [`org.yml`](org.yml). `.gitlab-ci.yml` includes it once per org with that org's [CI/CD inputs](https://docs.gitlab.com/ci/inputs/), so adding an org is one `include` entry, not a copied file. Requires **GitLab 17.0+**.

Each include defines that org's jobs:

- `test:unit:<name>` / `test:postrun:<name>` - scheduled unit tests (`$JOB_NAME == unitTest` on the org's branch)
- `test:predeploy:<name>` - manual MR validation against the org
- `deploy:<name>` - deploy on push to the org's branch
- `destroy:<name>` - web pipeline destroy with `$PACKAGE`
- `.<name>-auth` / `.<name>-org` - hidden templates with the org's credentials (plus the deploy lock and environment URL), reusable by other jobs (the maintenance jobs extend `.prd-auth`, `.dev-auth` and `.fullqa-auth`)

Git-tracked deletions need no job of their own: `deploy:<name>` and `test:predeploy:<name>` include them (see `AUTO_DESTROY` in `.gitlab-ci.yml`).

## Current Orgs

```yaml
include:
  - local: ".gitlab/workflows/orgs/org.yml"
    inputs:
      name: dev
      environment: dev
      alias: DEV
      branch: "$DEV_BRANCH"
      release: true
  - local: ".gitlab/workflows/orgs/org.yml"
    inputs:
      name: fullqa
      environment: fullqa
      alias: FULLQA
      branch: "$FULLQA_BRANCH"
      release: true
      release_manual: true
      release_after: "deploy:dev"
  - local: ".gitlab/workflows/orgs/org.yml"
    inputs:
      name: prd
      environment: production
      alias: PRODUCTION
      branch: "$CI_DEFAULT_BRANCH"
      production: true
```

## Inputs

| Input            | Required | Example            | Purpose                                                                                                                                                                          |
| ---------------- | -------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`           | yes      | `staging`          | Job name suffix (`deploy:staging`, ...) and hidden template prefix (`.staging-auth`, `.staging-org`)                                                                             |
| `environment`    | yes      | `staging`          | GitLab environment and deploy lock (`resource_group`) name; MR validations use `validate-<environment>`                                                                           |
| `alias`          | yes      | `STAGING`          | Salesforce CLI alias (match it in `sfdx-project.json` `replaceWhenEnv` values) and prefix of the org's CI/CD variables (see [below](#cicd-variables))                             |
| `branch`         | yes      | `"$STAGING_BRANCH"` | Rules expression for the org's branch: a variable reference (define it under `variables:` in `.gitlab-ci.yml`) or a quoted literal such as `"'staging'"`                         |
| `production`     | no       | `true`             | Marks the production org: sets `IS_PRODUCTION`, so `QUICK_DEPLOY` applies and Apex deletions require tests (`DESTRUCTIVE_TESTS`). Default `false`                                |
| `release`        | no       | `true`             | Release branching model (`BRANCHING_MODEL: "release"`): validate MRs into `release/*` and deploy `release/*` pushes to this org. Default `false`                                  |
| `release_manual` | no       | `true`             | Release deploys are manual jobs that need `release_after`, instead of running automatically. Default `false`                                                                      |
| `release_after`  | no       | `"deploy:dev"`     | Job a manual release deploy needs, so it can only be played once the same commit is deployed there. Default `deploy:dev`                                                         |

## Adding a New Org

1. **Add an include** to `.gitlab-ci.yml` with the new org's inputs:

   ```yaml
   - local: ".gitlab/workflows/orgs/org.yml"
     inputs:
       name: staging
       environment: staging
       alias: STAGING
       branch: "$STAGING_BRANCH"
   ```

   and define the branch variable under `variables:` (`STAGING_BRANCH: "staging"`).

2. **Set the org's CI/CD variables** (see [below](#cicd-variables)).

3. **Wire it into the shared jobs** where needed:
   - Add `test:predeploy:<name>` (with `optional: true`) to the `needs` list of the `quality` job in `test-quality-jobs.yml`, so SonarQube (when `SONAR_URL` is set) receives that org's validation coverage.
   - If the new org's branch should be treated like the other long-lived org branches (MRs *from* it skip validation and scans), add it to `.skip-org-branch-sources` in `base-templates.yml` and to the target-branch lists in `test-quality-jobs.yml`.
   - If the new org should be checked by `pre-merge-check`, set `DEV_DEPLOY_JOB`/`FULLQA_DEPLOY_JOB` (and the `*_PREDEPLOY_JOB` variables) accordingly.

### Release branching model

With `BRANCHING_MODEL: "release"`, orgs with `release: true` validate MRs into `release/*` and receive `release/*` deploys. Set `release_manual: true` and `release_after` to the deploy job of the org that should be deployed first (for example a UAT org after `deploy:fullqa`). Release deploys diff from the merge-base with the default branch (`DELTA_BASE_BRANCH`), so playing the latest pipeline deploys the whole release even if earlier pipelines were never played.

## CI/CD Variables

Create an external client app (or connected app where required) and upload the public certificate, following Salesforce's [JWT flow setup guide](https://developer.salesforce.com/docs/platform/sfdx-dev/guide/sfdx-dev-auth-jwt-flow.html). In your GitLab project settings, add these variables, named after the org's `alias` input (`STAGING` here):

- **`STAGING_JWT_CLIENT_ID`** - OAuth consumer key for the app
- **`STAGING_JWT_KEY`** - private key; set the variable type to **File** so CI passes a temporary file path to Salesforce CLI
- **`STAGING_USERNAME`** - Salesforce username to authorize
- **`STAGING_INSTANCE_URL`** - org login URL, preferably the My Domain URL ending in `my.salesforce.com`
- **`STAGING_ORG_URL`** - display URL for the GitLab environment (cosmetic)
- **`STAGING_DISABLED`** - optional; set to any value to disable deploys to staging

For `PRODUCTION_JWT_CLIENT_ID`, use a **Connected App** if you run the `sandboxRefresh` job: Salesforce requires it when the CLI creates or refreshes sandboxes.

For JWT credentials belonging to a sandbox that will be refreshed, follow the manual [before-refresh backup](https://sfdx-hardis.cloudity.com/hardis/org/refresh/before-refresh/) and [after-refresh restore](https://sfdx-hardis.cloudity.com/hardis/org/refresh/after-refresh/) procedures. Back up the External Client App credentials before refreshing, then verify the restored consumer key matches that sandbox's `*_JWT_CLIENT_ID` and its certificate matches `*_JWT_KEY`. The before-refresh procedure can optionally delete backed-up apps to support a clean restore; this is not mandatory for every setup. These procedures are interactive and must not be added to CI. Connected Apps generally can't be restored after a Spring '26 refresh without Salesforce Support, so convert any sandbox app that must survive refresh to an External Client App first.

Keep the private key out of the repository. Protect and scope the key variable to trusted pipelines where possible; merge-request validation jobs also need access to the credentials for the target org.

## Customizing

Changes to `org.yml` apply to every org. For a one-off change to a single org, override that job after the includes, in `.gitlab-ci.yml` or a separate included file (later definitions are merged over the template's, and keys such as `rules` are replaced whole):

```yaml
deploy:staging:
  when: manual
```

## Removing an Org

1. Remove its `include` entry from `.gitlab-ci.yml`
2. Remove references to its jobs or `.<name>-auth` template (the `quality` job's `needs`, maintenance jobs)
3. Clean up the org's CI/CD variables (optional)

## Troubleshooting

| Symptom                       | Check                                                                                                   |
| ----------------------------- | ------------------------------------------------------------------------------------------------------- |
| `unknown keyword` / `spec` errors | GitLab 17.0+? Older versions don't support `include` inputs                                         |
| Jobs not appearing            | `include` entry added to `.gitlab-ci.yml`? Branch variable defined and matching your git branch?       |
| Auth failures                 | `<ALIAS>_JWT_CLIENT_ID`, File-type `<ALIAS>_JWT_KEY`, `<ALIAS>_USERNAME` and `<ALIAS>_INSTANCE_URL` set? |
| Resource group conflicts      | `environment` input unique per org?                                                                     |
| No quick deploy / destructive tests in production | `production: true` set on the production org's include?                            |
| Deleted files not deleted     | `AUTO_DESTROY` is `"true"`? The job log prints a "Destructive Changes" list when deletions are included |
| Delete fails on a dependency  | Needs the other order — add `[pre-destructive]` to the commit message / MR title, or use a web destroy  |
