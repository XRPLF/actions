#!/usr/bin/env bash
# Print the release channel for a build, from IS_TAG, REF_NAME and VISIBILITY.
#
# Only a tag says how mature a build is; anything else is a develop build.
# A tag matching none of the release patterns is a custom build.
set -euo pipefail

# SemVer's grammar, which BuildInfo enforces on the version the binary reports.
NUMBER='(0|[1-9][0-9]*)'
VERSION_CORE="${NUMBER}\.${NUMBER}\.${NUMBER}"
BUILD_METADATA='(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?'

if [[ "${VISIBILITY}" != "public" ]]; then
    echo private
elif [[ "${IS_TAG}" != "true" ]]; then
    echo develop
elif [[ "${REF_NAME}" =~ ^${VERSION_CORE}$ ]]; then
    echo stable
elif [[ "${REF_NAME}" =~ ^${VERSION_CORE}-rc${NUMBER}${BUILD_METADATA}$ ]]; then
    echo rc
elif [[ "${REF_NAME}" =~ ^${VERSION_CORE}-b${NUMBER}${BUILD_METADATA}$ ]]; then
    echo beta
else
    echo custom
fi
