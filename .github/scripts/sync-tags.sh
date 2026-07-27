#!/usr/bin/env bash
#
# Synchronize tags from a source repository into a destination repository. Missing tags are always
# created. By default existing tags that match on both sides are a no-op, while a diverged tag (same
# name, different object) aborts the run. Force mode overwrites diverged tags with a force-push
# (using --force-with-lease). Dry-run mode reports what would change without pushing anything.
#
# This script is intended to run after the branches have been synchronized (see sync-branches.sh),
# so that tagged commits are already reachable from a branch in the destination before their tags
# arrive.
#
# Configuration is supplied via environment variables:
#
#   Required:
#     GH_TOKEN     Token with read access to the source repository and write access to the
#                  destination. A public repository ignores the token as long as it is valid. When
#                  running this script locally, your personal access token must have at least the
#                  "repo", "read:org" (for tags in organization repos), and "workflow" scopes.
#     SOURCE_REPO  Source repository, as "owner/repo" (github.com is assumed).
#     DEST_REPO    Destination repository, as "owner/repo" (github.com is assumed).
#
#   Optional:
#     DRY_RUN      "true" to report changes without pushing.
#                  (default: false)
#     FORCE        "true" to overwrite diverged destination tags.
#                  (default: false)
#
# Exit status:
#     0        All tags synchronized successfully (or a clean dry run was performed).
#     non-zero Synchronization failed, and the run stopped at the first tag that could not be
#              synchronized. Failures that git detects (an unreachable remote, a rejected push) exit
#              with git's own status and message.

set -euo pipefail

# shellcheck source=sync-common-functions.sh
source "${BASH_SOURCE[0]%/*}/sync-common-functions.sh"

# --- Configuration -----------------------------------------------------------------------------

set_common_defaults

# Internal git ref/remote names used within the working repository.
TAG_REF="refs/tags"
SOURCE_REF="refs/remotes/source-tags"
DEST_REF="refs/remotes/dest-tags"
SOURCE_REMOTE="source"
DEST_REMOTE="dest"
REMOTE_REF_PREFIX="${TAG_REF}"

# --- Helpers -----------------------------------------------------------------------------------

# Fetch all tags from both remotes into local tracking refs. --no-tags suppresses git's automatic
# tag-following, which would otherwise populate refs/tags/* locally as a side effect. That side
# effect can cause the destination fetch to short-circuit (all objects already locally reachable via
# refs/tags/*), leaving refs/remotes/dest-tags/ empty and making every tag appear as new.
fetch_tags() {
    echo "Fetching tags from source."
    git fetch --no-tags --quiet "${SOURCE_REMOTE}" "+${TAG_REF}/*:${SOURCE_REF}/*"

    echo "Fetching tags from destination."
    git fetch --no-tags --quiet "${DEST_REMOTE}" "+${TAG_REF}/*:${DEST_REF}/*"
}

# Synchronize a single already-fetched tag onto the destination.
sync_tag() {
    local tag="$1"

    # Create tags that do not yet exist on the destination.
    if ! git show-ref --verify --quiet "${DEST_REF}/${tag}"; then
        echo "Creating: ${tag}"
        push_ref "${tag}"
        return
    fi

    local src_sha dest_sha
    src_sha="$(git rev-parse "${SOURCE_REF}/${tag}")"
    dest_sha="$(git rev-parse "${DEST_REF}/${tag}")"

    # Tags that already match need no action.
    if [ "${src_sha}" = "${dest_sha}" ]; then
        echo "Up-to-date: ${tag}"
        return
    fi

    # Overwrite diverged tags when force is enabled. An explicit lease value is required: tags are
    # fetched into the custom ${DEST_REF} namespace rather than a standard remote-tracking ref, so
    # a bare --force-with-lease has no remote-tracking ref to compare against and always rejects
    # the push as stale, even when the destination has not changed since fetch_tags ran.
    if [ "${FORCE}" = "true" ]; then
        echo "Overwriting: ${tag}"
        push_ref "${tag}" "--force-with-lease=${TAG_REF}/${tag}:${dest_sha}"
        return
    fi

    die "Tag '${tag}' exists on both sides with different objects; use FORCE to overwrite it."
}

sync_tags() {
    PUSH_OPTS=()
    if [ "${DRY_RUN}" = "true" ]; then
        echo "Dry run: no tags will be pushed."
        PUSH_OPTS+=("--dry-run")
    fi

    local tag
    while IFS= read -r tag; do
        sync_tag "${tag}"
    done < <(git for-each-ref --format='%(refname:lstrip=3)' "${SOURCE_REF}/")
}

# --- Main --------------------------------------------------------------------------------------

main() {
    validate_common_config
    setup_working_repo
    fetch_tags
    sync_tags
}

main "$@"
