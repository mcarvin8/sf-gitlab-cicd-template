#!/bin/bash
################################################################################
# Script: configure_coverage.sh
# Description: Applies COVERAGE_FORMATS to the apex-code-coverage-transformer
#              hook config (.apexcodecovtransformer.config.json), which converts
#              coverage JSON after every sf deploy/validate and test run.
#              cobertura is always added (GitLab MR coverage reads
#              coverage-cobertura.xml). The transformer only names files
#              coverage-<format>.<ext> when it writes more than one format, so
#              html is added when cobertura would be the only format.
# Usage: Sourced by the .authenticate CI template before any sf command
# Dependencies: jq
# Environment Variables:
#   - COVERAGE_FORMATS: Comma-separated transformer formats (sonar, cobertura,
#     html, jacoco, lcovonly, clover, ...). Empty keeps the config file as-is.
################################################################################

if [[ -n "${COVERAGE_FORMATS:-}" ]]; then
    coverage_config=".apexcodecovtransformer.config.json"
    jq --arg formats "${COVERAGE_FORMATS}" '
        ($formats | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) as $requested
        | ($requested + (if any($requested[]; . == "cobertura") then [] else ["cobertura"] end)) as $withCobertura
        | .format = (($withCobertura + (if ($withCobertura | length) == 1 then ["html"] else [] end)) | join(","))
    ' "${coverage_config}" > "${coverage_config}.tmp"
    mv "${coverage_config}.tmp" "${coverage_config}"
    echo "Coverage formats: $(jq -r '.format' "${coverage_config}")"
fi
