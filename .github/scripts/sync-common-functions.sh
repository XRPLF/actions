# shellcheck shell=bash
#
# Common helpers shared by sync-branches.sh and sync-tags.sh.

# Emit an error and exit.
die() {
    echo "::error::$1" >&2
    exit 1
}

# Apply the defaults shared by all sync scripts, so that only the variables that differ from the
# default need to be set. The workflow passes DRY_RUN explicitly; FORCE is only ever set when running
# a script directly, as the workflow deliberately does not expose force-pushing.
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
# to 'https://github.com/<repo>'. The header is scoped to the single repository rather than to
# github.com as a whole, so that the token for one remote is never sent to the other. The 'tr -d'
# command strips the line breaks GNU base64 inserts (it wraps at 76 columns, and an encoded token
# exceeds that) so the header stays on one line. A public repository ignores a valid token, so the
# same header is used for both.
# Args: <remote-name> <owner/repo>
add_authenticated_remote() {
    local remote="$1" repo="$2"
    local url="https://github.com/${repo}"
    git remote add "${remote}" "${url}"
    git config --local "http.${url}/.extraheader" \
        "AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GH_TOKEN}" | base64 | tr -d '\n')"
}

# Validate configuration shared by all sync scripts.
validate_common_config() {
    [ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is required but not set."
    [ -n "${SOURCE_REPO:-}" ] || die "SOURCE_REPO is required but not set."
    [ -n "${DEST_REPO:-}" ] || die "DEST_REPO is required but not set."

    case "${DRY_RUN}" in
        true | false) ;;
        *) die "DRY_RUN must be 'true' or 'false', got '${DRY_RUN}'." ;;
    esac

    case "${FORCE}" in
        true | false) ;;
        *) die "FORCE must be 'true' or 'false', got '${FORCE}'." ;;
    esac
}

# Initialize a fresh working repository in a temporary directory and wire up the authenticated
# remotes.
setup_working_repo() {
    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "${WORKDIR}"' EXIT
    cd "${WORKDIR}"

    git init --quiet
    # Both remotes carry the token; a public source simply ignores it as long as the token is valid.
    add_authenticated_remote "${SOURCE_REMOTE}" "${SOURCE_REPO}"
    add_authenticated_remote "${DEST_REMOTE}" "${DEST_REPO}"
}
