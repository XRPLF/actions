#!/usr/bin/env bash
#
# Common helpers shared by sync-branches.sh and sync-tags.sh. Intended to be sourced, not executed
# directly.

# Emit an error and exit with the given status (default 2 for usage/config errors).
die() {
    local status="${2:-2}"
    echo "::error::$1" >&2
    exit "${status}"
}

# Apply the defaults shared by all sync scripts. These match what is set in the workflow file, so
# the scripts can also be run locally. Keep in sync with the workflow file.
set_common_defaults() {
    DRY_RUN="${DRY_RUN:-false}"
    FORCE="${FORCE:-false}"
}

# Push the given source ref to the destination. Reads the SOURCE_REF and REMOTE_REF_PREFIX globals
# (the caller sets REMOTE_REF_PREFIX to "refs/heads" or "refs/tags") and the PUSH_OPTS global (e.g.
# --dry-run). Any extra arguments (e.g. --force-with-lease) are inserted before the refspec.
# Args: <ref> [git-push-option...]
push_ref() {
    local ref="$1"
    shift
    git push "$@" "${PUSH_OPTS[@]+"${PUSH_OPTS[@]}"}" "${DEST_REMOTE}" \
        "${SOURCE_REF}/${ref}:${REMOTE_REF_PREFIX}/${ref}"
}

# Add a remote pointing at a github.com repository and authenticate to it with GH_TOKEN. The token
# is passed via an HTTP Authorization header rather than embedded in the remote URL. Embedding would
# persist the credential in .git/config and, because git prints the remote URL in its error
# messages, risk leaking it into CI logs. Passing it as an 'extraheader' keeps git's output limited
# to 'https://github.com/<repo>'. This mirrors how actions/checkout authenticates. The 'tr -d'
# command strips any line breaks base64 may insert so the header stays on one line. A public
# repository ignores a valid token, so the same header is used for both.
# Args: <remote-name> <owner/repo>
add_authenticated_remote() {
    local remote="$1" repo="$2"
    local url="https://github.com/${repo}"
    git remote add "${remote}" "${url}"
    git config --local "http.${url}/.extraheader" \
        "AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GH_TOKEN}" | base64 | tr -d '\n')"
}

# Validate configuration shared by all sync scripts: GH_TOKEN, SOURCE_REPO, DEST_REPO, DRY_RUN,
# FORCE, and git presence.
validate_common_config() {
    [ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is required but not set." 2
    [ -n "${SOURCE_REPO:-}" ] || die "SOURCE_REPO is required but not set." 2
    [ -n "${DEST_REPO:-}" ] || die "DEST_REPO is required but not set." 2

    case "${DRY_RUN}" in
        true | false) ;;
        *) die "DRY_RUN must be 'true' or 'false', got '${DRY_RUN}'." 2 ;;
    esac

    case "${FORCE}" in
        true | false) ;;
        *) die "FORCE must be 'true' or 'false', got '${FORCE}'." 2 ;;
    esac

    command -v git >/dev/null 2>&1 || die "git is required but not found on PATH." 2
}

# Initialize the working repository and wire up the authenticated remotes. Reachability is not
# checked here, because if the first real fetch against each remote (in fetch_branches/fetch_tags)
# fails it will provide a clear message if the repository is unreachable or the token is invalid, so
# checking it here would be redundant.
setup_working_repo() {
    if [ -z "${WORKDIR:-}" ]; then
        WORKDIR="$(mktemp -d)"
        trap 'rm -rf "${WORKDIR}"' EXIT
    fi
    mkdir -p "${WORKDIR}"
    cd "${WORKDIR}" || exit

    git init --quiet
    # Both remotes carry the token; a public source simply ignores it as long as the token is valid.
    add_authenticated_remote "${SOURCE_REMOTE}" "${SOURCE_REPO}"
    add_authenticated_remote "${DEST_REMOTE}" "${DEST_REPO}"
}
