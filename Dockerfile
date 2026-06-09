FROM ubuntu:latest

# Set Salesforce CLI Environment Variables
# https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_dev_cli_env_variables.htm
ENV SF_AUTOUPDATE_DISABLE=true \
    SF_USE_GENERIC_UNIX_KEYCHAIN=true \
    SF_DOMAIN_RETRY=300 \
    SF_PROJECT_AUTOUPDATE_DISABLE_FOR_PACKAGE_CREATE=true \
    SF_PROJECT_AUTOUPDATE_DISABLE_FOR_PACKAGE_VERSION_CREATE=true \
    SF_DISABLE_DNS_CHECK=true \
    SF_DISABLE_SOURCE_MEMBER_POLLING=true \
    SF_HIDE_RELEASE_NOTES=true \
    SF_HIDE_RELEASE_NOTES_FOOTER=true \
    SF_SKIP_NEW_VERSION_CHECK=true \
    SF_CONTAINER_MODE=true \
    SF_CI_HEARTBEAT_FREQUENCY_MS=60000 \
    NODE_NO_WARNINGS=1

# Install Salesforce CLI and other required software (git, jq, curl, nodejs)
# Print Salesforce CLI version in format accepted for Salesforce CLI bugs on GitHub
RUN apt-get update && apt-get install -y curl jq git && \
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/* && \
    npm install --global @salesforce/cli@latest && \
    echo y | sf plugins install sfdx-git-delta@latest && \
    echo y | sf plugins install apex-code-coverage-transformer@latest && \
    echo y | sf plugins install sf-package-combiner@latest && \
    echo y | sf plugins install sf-package-list@latest && \
    echo y | sf plugins install apextestlist@latest && \
    sf version --verbose --json
