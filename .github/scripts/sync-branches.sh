#!/usr/bin/env bash
#
# Synchronize important branches from a source repository into a destination repository. Missing
# branches are always created. By default branches are fast-forwarded only, while a diverged branch
# aborts the run. Force mode overwrites diverged branches with a force-push (using
# --force-with-lease). Dry-run mode reports what would change without pushing anything.
#
# Configuration is supplied via environment variables:
#
#   Required:
#     GH_TOKEN       Token with read access to the source repository and write access to the
#                    destination. A public repository ignores the token as long as it is valid. When
#                    running this script locally, your personal access token must have at least the
#                    "repo", "read:org" (for branches in organization repos), and "workflow" scopes.
#     SOURCE_REPO    Source repository, as "owner/repo" (github.com is assumed).
#     DEST_REPO      Destination repository, as "owner/repo" (github.com is assumed).
#     BRANCHES_GLOB  Glob matching the branches to synchronize. A plain branch name is a glob that
#                    matches only itself; a wider glob may match several branches, all of which are
#                    synchronized.
#
#   Optional:
#     DRY_RUN        "true" to report changes without pushing.
#                    (default: false)
#     FORCE          "true" to overwrite diverged destination branches.
#                    (default: false)
#
# Exit status:
#     0        All matched branches synchronized successfully (or a clean dry run was performed).
#     non-zero Synchronization failed, and the run stopped at the first branch that could not be
#              synchronized. Failures that git detects (an unreachable remote, a missing branch, a
#              rejected push) exit with git's own status and message.

set -euo pipefail

# shellcheck source=sync-common-functions.sh
source "${BASH_SOURCE[0]%/*}/sync-common-functions.sh"

# --- Configuration -----------------------------------------------------------------------------

set_common_defaults
BRANCHES_GLOB="${BRANCHES_GLOB:-}"

# Internal git ref/remote names used within the working repository.
BRANCH_REF="refs/heads"
SOURCE_REF="refs/remotes/source"
DEST_REF="refs/remotes/dest"
SOURCE_REMOTE="source"
DEST_REMOTE="dest"
REMOTE_REF_PREFIX="${BRANCH_REF}"

# --- Helpers -----------------------------------------------------------------------------------

validate_config() {
    validate_common_config
    [ -n "${BRANCHES_GLOB}" ] || die "BRANCHES_GLOB must be a non-empty branch name or glob."
}

# Fetch the branches matching the glob from both remotes into local tracking refs. The '+' prefix
# force-updates the tracking refs so they always reflect each remote.
fetch_branches() {
    echo "Fetching source branch(es): ${BRANCHES_GLOB}"
    git fetch --quiet "${SOURCE_REMOTE}" \
        "+${BRANCH_REF}/${BRANCHES_GLOB}:${SOURCE_REF}/${BRANCHES_GLOB}"

    # A glob that matches no refs makes 'git fetch' succeed having fetched nothing, so a mistyped
    # BRANCHES_GLOB would otherwise go undetected.
    [ -n "$(git for-each-ref "${SOURCE_REF}/")" ] ||
        die "Source branch(es) '${BRANCHES_GLOB}' not found in '${SOURCE_REPO}'."

    # A branch that does not yet exist on the destination is expected: it is created below. A literal
    # branch name that is missing makes this fetch fail (a glob matching nothing succeeds), so
    # failures are ignored here; a genuine problem such as an unreachable remote or an invalid token
    # surfaces when pushing.
    echo "Fetching destination branch(es): ${BRANCHES_GLOB}"
    git fetch --quiet "${DEST_REMOTE}" \
        "+${BRANCH_REF}/${BRANCHES_GLOB}:${DEST_REF}/${BRANCHES_GLOB}" || true
}

# Synchronize a single already-fetched ref onto the destination.
sync_ref() {
    local ref="$1"

    # Create branches that do not yet exist on the destination. The refspec is not forced, so if a
    # racing push created the branch between our fetch and now, the push is rejected rather than
    # clobbering the destination.
    if ! git show-ref --verify --quiet "${DEST_REF}/${ref}"; then
        echo "Creating: ${ref}"
        push_ref "${ref}"
        return
    fi

    # Overwrite diverged branches when force is enabled. The --force-with-lease flag guards against
    # clobbering destination commits that appeared after our fetch.
    if [ "${FORCE}" = "true" ]; then
        echo "Overwriting: ${ref}"
        push_ref "${ref}" --force-with-lease
        return
    fi

    # Check out the destination branch and fast-forward it to the source.
    echo "Syncing: ${ref}"
    git checkout --quiet -B "${ref}" "${DEST_REF}/${ref}"
    git merge --ff-only "${SOURCE_REF}/${ref}" ||
        die "Branch '${ref}' has diverged and cannot be fast-forwarded; use FORCE to overwrite it."
    git push "${PUSH_OPTS[@]+"${PUSH_OPTS[@]}"}" "${DEST_REMOTE}" "HEAD:${BRANCH_REF}/${ref}"
}

# Synchronize every ref that was fetched under SOURCE_REF (a glob may match several).
sync_branches() {
    # A dry run adds --dry-run to every push so nothing is actually written. The options are expanded
    # as "${PUSH_OPTS[@]+"${PUSH_OPTS[@]}"}" to avoid the "unbound variable" error that an empty
    # array triggers under 'set -u' on older versions of Bash.
    PUSH_OPTS=()
    if [ "${DRY_RUN}" = "true" ]; then
        echo "Dry run: no branches will be pushed."
        PUSH_OPTS+=("--dry-run")
    fi

    local ref
    while IFS= read -r ref; do
        sync_ref "${ref}"
    done < <(git for-each-ref --format='%(refname:lstrip=3)' "${SOURCE_REF}/")
}

# --- Main --------------------------------------------------------------------------------------

main() {
    validate_config
    setup_working_repo
    fetch_branches
    sync_branches
}

main "$@"
