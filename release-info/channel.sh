#!/usr/bin/env bash
# Print the release channel for a build, from IS_TAG, REF_NAME and VISIBILITY.
#
# Only a tag says how mature a build is; anything else is a develop build.
# A tag matching none of the release patterns is a custom build.
set -euo pipefail

VERSION_CORE='[0-9]+\.[0-9]+\.[0-9]+'

if [[ "${VISIBILITY}" != "public" ]]; then
    echo private
elif [[ "${IS_TAG}" != "true" ]]; then
    echo develop
elif [[ "${REF_NAME}" =~ ^${VERSION_CORE}$ ]]; then
    echo stable
elif [[ "${REF_NAME}" =~ ^${VERSION_CORE}-rc[0-9]+(\+.*)?$ ]]; then
    echo rc
elif [[ "${REF_NAME}" =~ ^${VERSION_CORE}-b(0|[1-9][0-9]*)(\+.*)?$ ]]; then
    echo beta
else
    echo custom
fi
