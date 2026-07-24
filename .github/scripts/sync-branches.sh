#!/usr/bin/env bash
#
# Synchronize important branches from a source repository into a destination repository. Missing
# branches are always created. By default branches are fast-forwarded only, while diverged branches
# are skipped and cause a non-zero exit. Force mode overwrites diverged branches with a force-push
# (using --force-with-lease). Dry-run mode reports what would change without pushing anything.
#
# Configuration is supplied via environment variables:
#
#   Required:
#     GH_TOKEN     Token with read access to the source repository and write access to the
#                  destination. A public repository ignores the token as long as it is valid. When
#                  running this script locally, your personal access token must have at least the
#                  "repo", "read:org" (for branches in organization repos), and "workflow" scopes.
#     SOURCE_REPO  Source repository, as "owner/repo" (github.com is assumed).
#     DEST_REPO    Destination repository, as "owner/repo" (github.com is assumed).
#     BRANCH       A single branch name or glob to synchronize. A glob may match several branches,
#                  all of which are synchronized.
#
#   Optional:
#     DRY_RUN      "true" to report changes without pushing.
#                  (default: false)
#     FORCE        "true" to overwrite diverged destination branches.
#                  (default: false)
#     WORKDIR      Directory to initialize the working repo in.
#                  (default: a fresh mktemp dir)
#
# Exit status:
#     0   All branches synchronized successfully (or a clean dry run was performed).
#     1   At least one branch could not be synchronized (diverged without FORCE, or a push was
#         rejected because the destination changed concurrently); other branches were still
#         attempted.
#     2   Invalid configuration / usage error.

set -euo pipefail

# shellcheck source=sync-common-functions.sh
source "${BASH_SOURCE[0]%/*}/sync-common-functions.sh"

# --- Configuration -----------------------------------------------------------------------------

set_common_defaults
BRANCH="${BRANCH:-}"

# Internal git ref/remote names used within the working repository.
BRANCH_REF="refs/heads"
SOURCE_REF="refs/remotes/source"
DEST_REF="refs/remotes/dest"
SOURCE_REMOTE="source"
DEST_REMOTE="dest"
REMOTE_REF_PREFIX="${BRANCH_REF}"

# --- Helpers -----------------------------------------------------------------------------------

# Validate the configuration supplied via the environment, exiting with status 2 on any problem.
validate_config() {
    validate_common_config
    [ -n "${BRANCH}" ] || die "BRANCH must be a non-empty branch name or glob." 2
}

# Fetch the branch (or all branches matching the glob) from both remotes into local tracking refs.
# The '+' prefix force-updates the tracking refs so they always reflect each remote.
fetch_branches() {
    # Unlike the destination, a missing source branch is a real error as there is nothing to
    # synchronize from. Both "no matching refs" and other failures are fatal, but they get distinct
    # messages to aid diagnosis, and both exit 2 to match the documented usage/config status rather
    # than git's bare exit 1. The 'git ls-remote --exit-code' command returns 2 only when no ref
    # matches, so we capture the status with '|| ls_status=$?' to ensure a non-zero exit does not
    # trip 'set -e' before it is inspected. Any other non-zero status than 2 is treated as a real
    # failure.
    echo "Fetching source branch: ${BRANCH}"
    if ! git fetch --quiet "${SOURCE_REMOTE}" "+${BRANCH_REF}/${BRANCH}:${SOURCE_REF}/${BRANCH}"; then
        local ls_status=0
        git ls-remote --exit-code --heads "${SOURCE_REMOTE}" "${BRANCH_REF}/${BRANCH}" >/dev/null 2>&1 || ls_status=$?
        if [ "${ls_status}" -eq 2 ]; then
            die "Source branch(es) '${BRANCH}' not found in '${SOURCE_REPO}'." 2
        fi
        die "Failed to fetch source branch(es) '${BRANCH}' from '${SOURCE_REPO}'." 2
    fi

    # A glob that matches no refs makes 'git fetch' succeed having fetched nothing (git does not
    # treat an empty glob match as an error), so a missing or mistyped BRANCH would otherwise go
    # undetected.
    if [ -z "$(git for-each-ref "${SOURCE_REF}/")" ]; then
        die "Source branch(es) '${BRANCH}' not found in '${SOURCE_REPO}'." 2
    fi

    # A literal (non-glob) branch that does not yet exist on the destination makes 'git fetch' fail;
    # that case is tolerated here and the branch is created below. Any other failure (e.g. a
    # transient network or remote error) must not be masked, or the branch would be wrongly treated
    # as missing.
    echo "Fetching destination branch: ${BRANCH}"
    if ! git fetch --quiet "${DEST_REMOTE}" "+${BRANCH_REF}/${BRANCH}:${DEST_REF}/${BRANCH}"; then
        local ls_status=0
        git ls-remote --exit-code --heads "${DEST_REMOTE}" "${BRANCH_REF}/${BRANCH}" >/dev/null 2>&1 || ls_status=$?
        if [ "${ls_status}" -ne 2 ]; then
            die "Failed to fetch destination branch(es) '${BRANCH}' from '${DEST_REPO}'." 2
        fi
    fi
}

# Synchronize a single already-fetched ref onto the destination. Returns 0 on success and 1 on a
# recoverable per-branch failure (so the caller can continue with other branches).
sync_ref() {
    local ref="$1"

    # Create branches that do not yet exist on the destination. The refspec is not forced, so if a
    # racing push created the branch between our fetch and now, the destination is rejected rather
    # than clobbered; this is recorded as a failure and the next branch is still attempted.
    if ! git show-ref --verify --quiet "${DEST_REF}/${ref}"; then
        echo "Creating: ${ref}"
        if ! push_ref "${ref}"; then
            echo "::error::Branch '${ref}' could not be created (it may have been created concurrently); skipping."
            return 1
        fi
        return 0
    fi

    # Overwrite diverged branches when force is enabled. The --force-with-lease flag guards against
    # clobbering destination commits that appeared after our fetch: if the destination advanced in
    # the meantime the push is rejected; this is recorded as a failure and the next branch is still
    # attempted.
    if [ "${FORCE}" = "true" ]; then
        echo "Overwriting: ${ref}"
        if ! push_ref "${ref}" --force-with-lease; then
            echo "::error::Branch '${ref}' could not be overwritten (the destination changed since fetch); skipping."
            return 1
        fi
        return 0
    fi

    # Check out the destination branch and attempt a fast-forward to the source.
    echo "Syncing: ${ref}"
    git checkout --quiet -B "${ref}" "${DEST_REF}/${ref}"
    if ! git merge --ff-only "${SOURCE_REF}/${ref}"; then
        echo "::error::Branch '${ref}' has diverged and cannot be fast-forwarded; skipping."
        return 1
    fi

    if ! git push "${PUSH_OPTS[@]+"${PUSH_OPTS[@]}"}" "${DEST_REMOTE}" "HEAD:${BRANCH_REF}/${ref}"; then
        echo "::error::Branch '${ref}' could not be pushed (the destination changed since fetch); skipping."
        return 1
    fi
}

# Synchronize every ref that was fetched under SOURCE_REF (a glob may match several). Returns 1 if
# any branch failed to synchronize, 0 otherwise.
sync_branches() {
    # A dry run adds --dry-run to every push so nothing is actually written. The refspecs are
    # expanded as "${PUSH_OPTS[@]+"${PUSH_OPTS[@]}"}" to avoid the "unbound variable" error that an
    # empty array triggers under 'set -u' on older versions of Bash.
    PUSH_OPTS=()
    if [ "${DRY_RUN}" = "true" ]; then
        echo "Dry run: no branches will be pushed."
        PUSH_OPTS+=("--dry-run")
    fi

    # Process substitution feeds the loop so it runs in the current shell and 'failed' persists.
    local failed=0
    local ref
    while IFS= read -r ref; do
        [ -n "${ref}" ] || continue
        sync_ref "${ref}" || failed=1
    done < <(git for-each-ref --format='%(refname:lstrip=3)' "${SOURCE_REF}/")

    return "${failed}"
}

# --- Main --------------------------------------------------------------------------------------

main() {
    validate_config
    setup_working_repo
    fetch_branches
    sync_branches
}

main "$@"
