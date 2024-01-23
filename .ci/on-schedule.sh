#!/usr/bin/env bash
set -euo pipefail
set -x

# This script is triggered by a scheduled pipeline

source .ci/util.shlib

# Read config file into global variables
UTIL_READ_CONFIG_FILE

export TMPDIR="${TMPDIR:-/tmp}"

git config --global user.name "$GIT_AUTHOR_NAME"
git config --global user.email "$GIT_AUTHOR_EMAIL"

if [ -v TEMPLATE_ENABLE_UPDATES ] && [ "$TEMPLATE_ENABLE_UPDATES" == "true" ]; then
    .ci/update-template.sh && echo "Info: Updated CI template." && exit 0 || true
fi

# Check if the scheduled tag does not exist or scheduled does not point to HEAD
if ! [ "$(git tag -l "scheduled")" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse scheduled)" ]; then
    echo "Previous on-commit pipeline did not seem to run successfully. Aborting." >&2
    exit 1
fi

PACKAGES=()
declare -A AUR_TIMESTAMPS
MODIFIED_PACKAGES=()
DELETE_BRANCHES=()
UTIL_GET_PACKAGES PACKAGES
COMMIT="${COMMIT:-false}"

# Loop through all packages to do optimized aur RPC calls
# $1 = Output associative array
function collect_aur_timestamps() {
    # shellcheck disable=SC2034
    local -n collect_aur_timestamps_output=$1
    local AUR_PACKAGES=()

    for package in "${PACKAGES[@]}"; do
        unset VARIABLES
        declare -gA VARIABLES
        if UTIL_READ_MANAGED_PACAKGE "$package" VARIABLES; then
            if [ -v "VARIABLES[CI_PKGBUILD_SOURCE]" ]; then
                local PKGBUILD_SOURCE="${VARIABLES[CI_PKGBUILD_SOURCE]}"
                if [[ "$PKGBUILD_SOURCE" == aur ]]; then
                    AUR_PACKAGES+=("$package")
                fi
            fi
        fi
    done

    # Get all timestamps from AUR
    UTIL_FETCH_AUR_TIMESTAMPS collect_aur_timestamps_output "${AUR_PACKAGES[*]}"
}

# $1: dir1
# $2: dir2
function package_changed() {
    # Check if the package has changed
    # NOTE: We don't care if anything but the PKGBUILD or .SRCINFO has changed.
    # Any properly built PKGBUILD will use hashes, which will change
    if diff -q "$1/PKGBUILD" "$2/PKGBUILD" >/dev/null; then
        if [ ! -f "$1/.SRCINFO" ] && [ ! -f "$2/.SRCINFO" ]; then
            return 1
        elif [ -f "$1/.SRCINFO" ] && [ -f "$2/.SRCINFO" ]; then
            if diff -q "$1/.SRCINFO" "$2/.SRCINFO" >/dev/null; then
                return 1
            fi
        fi
    fi
    return 0
}

# Check if the package has gotten major changes
# Any change that is not a pkgver or pkgrel bump is considered a major change
# $1: dir1
# $2: dir2
function package_major_change() {
    local sdiff_output
    if sdiff_output="$(sdiff -ds <(gawk -f .ci/awk/remove-checksum.awk "$1/PKGBUILD") <(gawk -f .ci/awk/remove-checksum.awk "$2/PKGBUILD"))"; then
        return 1
    fi

    if [ $? -eq 2 ]; then
        echo "Warning: sdiff failed" >&2
        return 2
    fi

    if gawk -f .ci/awk/check-diff.awk <<<"$sdiff_output"; then
        # Check the rest of the files in the folder for changes
        # Excluding PKGBUILD .SRCINFO, .gitignore, .git .CI
        # shellcheck disable=SC2046
        if diff -q $(UTIL_GET_EXCLUDE_LIST "-x" "PKGBUILD .SRCINFO") -r "$1" "$2" >/dev/null; then
            return 1
        fi
    fi
    return 0
}

# $1: VARIABLES
# $2: git URL
function update_via_git() {
    local -n VARIABLES_VIA_GIT=${1:-VARIABLES}
    local pkgbase="${VARIABLES_VIA_GIT[PKGBASE]}"

    git clone --depth=1 "$2" "$TMPDIR/aur-pulls/$pkgbase"

    # We always run shfmt on the PKGBUILD. Two runs of shfmt on the same file should not change anything
    shfmt -w "$TMPDIR/aur-pulls/$pkgbase/PKGBUILD"

    if package_changed "$TMPDIR/aur-pulls/$pkgbase" "$pkgbase"; then
        if [ -v CI_HUMAN_REVIEW ] && [ "$CI_HUMAN_REVIEW" == "true" ] && package_major_change "$TMPDIR/aur-pulls/$pkgbase" "$pkgbase"; then
            echo "Warning: Major change detected in $pkgbase."
            VARIABLES_VIA_GIT[CI_REQUIRES_REVIEW]=true
        fi
        # Rsync: delete files in the destination that are not in the source. Exclude deleting .CI, exclude copying .git
        # shellcheck disable=SC2046
        rsync -a --delete $(UTIL_GET_EXCLUDE_LIST "--exclude") "$TMPDIR/aur-pulls/$pkgbase/" "$pkgbase/"
    fi
}

# $1: VARIABLES
# $2: source
function update_from_gitlab_tag() {
    local -n VARIABLES_UPDATE_FROM_GITLAB_TAG=${1:-VARIABLES}
    local pkgbase="${VARIABLES_UPDATE_FROM_GITLAB_TAG[PKGBASE]}"
    local project_id="${2:-}"

    if [ ! -f "$pkgbase/.SRCINFO" ]; then
        echo "ERROR: $pkgbase: .SRCINFO does not exist." >&2
        return
    fi

    local TAG_OUTPUT
    if ! TAG_OUTPUT="$(curl --fail-with-body --silent "https://gitlab.com/api/v4/projects/${project_id}/repository/tags?order_by=version&per_page=1")" || [ -z "$TAG_OUTPUT" ]; then
        echo "ERROR: $pkgbase: Failed to get list of tags." >&2
        return
    fi

    local COMMIT_URL VERSION
    COMMIT_URL="$(jq -r '.[0].commit.web_url' <<<"$TAG_OUTPUT")"
    VERSION="$(jq -r '.[0].name' <<<"$TAG_OUTPUT")"
    
    if [ -z "$COMMIT_URL" ] || [ -z "$VERSION" ]; then
        echo "ERROR: $pkgbase: Failed to get latest tag." >&2
        return
    fi

    # Parse .SRCINFO file for PKGVER
    local SRCINFO_PKGVER
    if ! SRCINFO_PKGVER="$(grep -m 1 -oP '\tpkgver\s=\s\K.*$' "$pkgbase/.SRCINFO")"; then
        echo "ERROR: $pkgbase: Failed to parse PKGVER from .SRCINFO." >&2
        return
    fi

    # Check if the tag is different from the PKGVER
    if [ "$VERSION" == "$SRCINFO_PKGVER" ]; then
        return
    fi

    # Extract project URL and commit hash from commit URL
    local DOWNLOAD_URL BASE_URL COMMIT PROJECT_NAME
    if [[ "$COMMIT_URL" =~ ^(.*)/([^/]+)/-/commit/([^/]+)$ ]]; then
        PROJECT_NAME="${BASH_REMATCH[2]}"
        COMMIT="${BASH_REMATCH[3]}"
        BASE_URL="${BASH_REMATCH[1]}/${PROJECT_NAME}/-/archive"
    else
        echo "ERROR: $pkgbase: Failed to parse commit URL." >&2
        return
    fi

    shfmt -w "$pkgbase/PKGBUILD"

    gawk -i inplace -f .ci/awk/update-pkgbuild.awk -v TARGET_VERSION="$VERSION" -v BASE_URL="$BASE_URL" -v TARGET_URL="${BASE_URL}/\${_commit}/${PROJECT_NAME}-\${_commit}.tar.gz" -v COMMIT="$COMMIT" "$pkgbase/PKGBUILD"
    gawk -i inplace -f .ci/awk/update-srcinfo.awk -v TARGET_VERSION="$VERSION" -v BASE_URL="$BASE_URL" -v TARGET_URL="${BASE_URL}/${COMMIT}/${PROJECT_NAME}-${COMMIT}.tar.gz" "$pkgbase/.SRCINFO"
}

function update_pkgbuild() {
    local -n VARIABLES_UPDATE_PKGBUILD=${1:-VARIABLES}
    local pkgbase="${VARIABLES_UPDATE_PKGBUILD[PKGBASE]}"
    if ! [ -v "VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_SOURCE]" ]; then
        return 0
    fi

    local PKGBUILD_SOURCE="${VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_SOURCE]}"

    # Check if the source starts with gitlab:
    if [[ "$PKGBUILD_SOURCE" =~ ^gitlab:(.*) ]]; then
        update_from_gitlab_tag VARIABLES_UPDATE_PKGBUILD "${BASH_REMATCH[1]}"
    # Check if the package is from the AUR
    elif [[ "$PKGBUILD_SOURCE" != aur ]]; then
        update_via_git VARIABLES_UPDATE_PKGBUILD "$PKGBUILD_SOURCE"
    else
        local git_url="https://aur.archlinux.org/${pkgbase}.git"

        # Fetch from optimized AUR RPC call
        if ! [ -v "AUR_TIMESTAMPS[$pkgbase]" ]; then
            echo "Warning: Could not find $pkgbase in cached AUR timestamps." >&2
            return 0
        fi
        local NEW_TIMESTAMP="${AUR_TIMESTAMPS[$pkgbase]}"

        # Check if CI_PKGBUILD_TIMESTAMP is set
        if [ -v "VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_TIMESTAMP]" ]; then
            local PKGBUILD_TIMESTAMP="${VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_TIMESTAMP]}"
            if [ "$PKGBUILD_TIMESTAMP" != "$NEW_TIMESTAMP" ]; then
                update_via_git VARIABLES_UPDATE_PKGBUILD "$git_url"
                UTIL_UPDATE_AUR_TIMESTAMP VARIABLES_UPDATE_PKGBUILD "$NEW_TIMESTAMP"
            fi
        else
            update_via_git VARIABLES_UPDATE_PKGBUILD "$git_url"
            UTIL_UPDATE_AUR_TIMESTAMP VARIABLES_UPDATE_PKGBUILD "$NEW_TIMESTAMP"
        fi
    fi
}

function update_vcs() {
    local -n VARIABLES_UPDATE_VCS=${1:-VARIABLES}
    local pkgbase="${VARIABLES_UPDATE_VCS[PKGBASE]}"

    # Check if pkgbase ends with -git or if CI_GIT_COMMIT is set
    if [[ "$pkgbase" != *-git ]] && [ ! -v "VARIABLES_UPDATE_VCS[CI_GIT_COMMIT]" ]; then
        return 0
    fi

    local _NEWEST_COMMIT
    if ! _NEWEST_COMMIT="$(UTIL_FETCH_VCS_COMMIT VARIABLES_UPDATE_VCS)"; then
        echo "Warning: Could not fetch latest commit for $pkgbase via heuristic." >&2
        return 0
    fi

    if [ -z "$_NEWEST_COMMIT" ]; then
        unset "VARIABLES_UPDATE_VCS[CI_GIT_COMMIT]"
        return 0
    fi

    # Check if CI_GIT_COMMIT is set
    if [ -v "VARIABLES_UPDATE_VCS[CI_GIT_COMMIT]" ]; then
        local CI_GIT_COMMIT="${VARIABLES_UPDATE_VCS[CI_GIT_COMMIT]}"
        if [ "$CI_GIT_COMMIT" != "$_NEWEST_COMMIT" ]; then
            UTIL_UPDATE_VCS_COMMIT VARIABLES_UPDATE_VCS "$_NEWEST_COMMIT"
        fi
    else
        UTIL_UPDATE_VCS_COMMIT VARIABLES_UPDATE_VCS "$_NEWEST_COMMIT"
    fi
}

# Collect last modified timestamps from AUR in an efficient way
collect_aur_timestamps AUR_TIMESTAMPS

mkdir "$TMPDIR/aur-pulls"

# Loop through all packages to check if they need to be updated
for package in "${PACKAGES[@]}"; do
    unset VARIABLES
    declare -A VARIABLES
    if UTIL_READ_MANAGED_PACAKGE "$package" VARIABLES; then
        update_pkgbuild VARIABLES
        update_vcs VARIABLES
        UTIL_WRITE_KNOWN_VARIABLES_TO_FILE "./${package}/.CI/config" VARIABLES

        if ! git diff --exit-code --quiet; then
            if [[ -v VARIABLES[CI_REQUIRES_REVIEW] ]] && [ "${VARIABLES[CI_REQUIRES_REVIEW]}" == "true" ]; then
                .ci/create-pr.sh "$package"
            else
                git add .
                if [ "$COMMIT" == "false" ]; then
                    COMMIT=true
                    git commit -m "chore(packages): update packages [skip ci]"
                else
                    git commit --amend --no-edit
                fi
                MODIFIED_PACKAGES+=("$package")
                if [ -v CI_HUMAN_REVIEW ] && [ "$CI_HUMAN_REVIEW" == "true" ] && git show-ref --quiet "origin/update-$package"; then
                    DELETE_BRANCHES+=("update-$package")
                fi
            fi
        fi
    fi
done

if [ ${#MODIFIED_PACKAGES[@]} -ne 0 ]; then
    .ci/schedule-packages.sh schedule "${MODIFIED_PACKAGES[@]}"
fi

if [ "$COMMIT" = true ]; then
    git tag -f scheduled
    git_push_args=()
    for branch in "${DELETE_BRANCHES[@]}"; do
        git_push_args+=(":$branch")
    done
    git push --atomic origin HEAD:main +refs/tags/scheduled "${git_push_args[@]}"
fi
