# mcarvin8/sf-cli

Docker image with Salesforce CLI (`sf`) preinstalled, used by the CI/CD pipelines in
[sf-gitlab-cicd-template](https://github.com/mcarvin8/sf-gitlab-cicd-template).

## Tags

| Tag               | Base                         | Notes                      |
| ----------------- | ---------------------------- | -------------------------- |
| `latest`, `linux` | `salesforce/cli:latest-full` | Linux runners (amd64 only) |

## What's included

- Salesforce CLI `latest` (from Salesforce's official `salesforce/cli:latest-full` image)
- `sfdx-git-delta`
- `apex-code-coverage-transformer`
- `sf-package-list`
- `apextestlist`
- Node.js, git, jq, curl
- `code-analyzer` and `sf-cat` plugins, plus OpenJDK 11 and Python 3.10 (from the base image) for Code Analyzer's PMD and Flow engines

## Pull

```
docker pull mcarvin8/sf-cli:latest
```

Full CI/CD pipeline docs, plugin versions, and the Dockerfile: see the
[GitHub repo](https://github.com/mcarvin8/sf-gitlab-cicd-template).
