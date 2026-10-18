FROM salesforce/cli:latest-full

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

# Install the pipeline's sf CLI plugins from sf-plugins.txt (the same list
# .install-sf-plugins installs at runtime)
# Print Salesforce CLI version in format accepted for Salesforce CLI bugs on GitHub
COPY sf-plugins.txt /tmp/sf-plugins.txt
RUN grep -vE '^[[:space:]]*(#|$)' /tmp/sf-plugins.txt | while read -r plugin; do \
        echo y | sf plugins install "$plugin" || exit 1; \
    done && \
    rm /tmp/sf-plugins.txt && \
    sf version --verbose --json
