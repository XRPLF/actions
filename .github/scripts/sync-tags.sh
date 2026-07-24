#!/usr/bin/env bash
#
# Synchronize tags from a source repository into a destination repository. Missing tags are always
# created. By default existing tags that match on both sides are a no-op; diverged tags (same name,
# different object) are skipped and cause a non-zero exit. Force mode overwrites diverged tags with
# a force-push (using --force-with-lease). Dry-run mode reports what would change without pushing
# anything.
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
#     WORKDIR      Directory to initialize the working repo in.
#                  (default: a fresh mktemp dir)
#
# Exit status:
#     0   All tags synchronized successfully (or a clean dry run was performed).
#     1   At least one tag could not be synchronized (diverged without FORCE, or a push was
#         rejected because the destination changed concurrently); other tags were still attempted.
#     2   Invalid configuration / usage error.

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

# Validate the configuration supplied via the environment, exiting with status 2 on any problem.
validate_config() {
    validate_common_config
}

fetch_tags() {
    echo "Fetching tags from source."
    # --no-tags suppresses git's automatic tag-following, which would otherwise populate
    # refs/tags/* locally as a side effect. That side effect can cause the destination fetch
    # below to short-circuit (all objects already locally reachable via refs/tags/*), leaving
    # refs/remotes/dest-tags/ empty and making every tag appear as new.
    if ! git fetch --no-tags --quiet "${SOURCE_REMOTE}" "+${TAG_REF}/*:${SOURCE_REF}/*"; then
        die "Failed to fetch tags from '${SOURCE_REPO}'." 2
    fi

    echo "Fetching tags from destination."
    if ! git fetch --no-tags --quiet "${DEST_REMOTE}" "+${TAG_REF}/*:${DEST_REF}/*"; then
        die "Failed to fetch tags from '${DEST_REPO}'." 2
    fi
}

# Synchronize a single already-fetched tag onto the destination. Returns 0 on success and 1 on a
# recoverable per-tag failure (so the caller can continue with other tags).
sync_tag() {
    local tag="$1"

    # Create tags that do not yet exist on the destination.
    if ! git show-ref --verify --quiet "${DEST_REF}/${tag}"; then
        echo "Creating: ${tag}"
        if ! push_ref "${tag}"; then
            echo "::error::Tag '${tag}' could not be created (it may have been created concurrently); skipping."
            return 1
        fi
        return 0
    fi

    local src_sha dest_sha
    src_sha="$(git rev-parse "${SOURCE_REF}/${tag}")"
    dest_sha="$(git rev-parse "${DEST_REF}/${tag}")"

    # Tags that already match need no action.
    if [ "${src_sha}" = "${dest_sha}" ]; then
        echo "Up-to-date: ${tag}"
        return 0
    fi

    # Overwrite diverged tags when force is enabled. An explicit lease value is required: tags are
    # fetched into the custom ${DEST_REF} namespace rather than a standard remote-tracking ref, so
    # a bare --force-with-lease has no remote-tracking ref to compare against and always rejects
    # the push as stale, even when the destination has not changed since fetch_tags ran.
    if [ "${FORCE}" = "true" ]; then
        echo "Overwriting: ${tag}"
        if ! push_ref "${tag}" "--force-with-lease=${TAG_REF}/${tag}:${dest_sha}"; then
            echo "::error::Tag '${tag}' could not be overwritten (the destination changed since fetch); skipping."
            return 1
        fi
        return 0
    fi

    echo "::error::Tag '${tag}' exists on both sides with different objects; skipping (use FORCE to overwrite)."
    return 1
}

sync_tags() {
    PUSH_OPTS=()
    if [ "${DRY_RUN}" = "true" ]; then
        echo "Dry run: no tags will be pushed."
        PUSH_OPTS+=("--dry-run")
    fi

    local failed=0
    local tag
    while IFS= read -r tag; do
        [ -n "${tag}" ] || continue
        sync_tag "${tag}" || failed=1
    done < <(git for-each-ref --format='%(refname:lstrip=3)' "${SOURCE_REF}/")

    return "${failed}"
}

# --- Main --------------------------------------------------------------------------------------

main() {
    validate_config
    setup_working_repo
    fetch_tags
    sync_tags
}

main "$@"
