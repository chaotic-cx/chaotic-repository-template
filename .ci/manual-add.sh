#!/usr/bin/env bash
set -euo pipefail

# This script is triggered for manual package adding via the web interface
# shellcheck source=./util.shlib
source .ci/util.shlib

# Read config file into global variables
UTIL_READ_CONFIG_FILE

UTIL_SET_GIT_IDENTITY

export TMPDIR="${TMPDIR:-/tmp}"

UTIL_SETUP_CLONE

PACKAGES_LIST=()
IFS=' ' read -r -a PACKAGES_LIST <<<"$ADD_PACKAGES"

MODIFIED_PACKAGES=()

regex="([[:alnum:]_@.+-]+)/(.*)"

for package_string in "${PACKAGES_LIST[@]}"; do
    if [[ "$package_string" =~ $regex ]]; then
        pkgbase="${BASH_REMATCH[1]}"
        source="${BASH_REMATCH[2]}"

        if [ -d "${pkgbase}" ]; then
            UTIL_PRINT_WARNING "Package ${pkgbase} already exists. Skipping."
        else
            GIT_URL=""
            branch=""
            if [[ "$source" == "aur" ]]; then
                GIT_URL="https://github.com/archlinux/aur.git"
                branch="$pkgbase"
            else
                GIT_URL="$source"
            fi

            output_path=""
            if ! UTIL_CLONE_PACKAGE output_path "$pkgbase" "$GIT_URL" "${branch:-}"; then
                UTIL_PRINT_ERROR "Failed to clone package ${pkgbase} from ${GIT_URL}"
                continue
            fi

            # Ratelimits
            sleep "$CI_CLONE_DELAY"

            # Rsync: exclude copying .git, exclude copying .CI
            # shellcheck disable=SC2046
            rsync -a $(UTIL_GET_EXCLUDE_LIST "--exclude") "$output_path/" "$pkgbase/"

            MODIFIED_PACKAGES+=("$pkgbase")
        fi
    fi
done

# Commit package changes if any
if [ ${#MODIFIED_PACKAGES[@]} -ne 0 ]; then
  git add "${MODIFIED_PACKAGES[@]}"

  COMMIT_MESSAGE=""
  if ((${#MODIFIED_PACKAGES[@]} == 1)); then
    COMMIT_MESSAGE="feat(add): add ${MODIFIED_PACKAGES[0]}"
  else
    COMMIT_MESSAGE="feat(add): add packages (${#MODIFIED_PACKAGES[@]})"
  fi

  git commit -q -m "$COMMIT_MESSAGE"
fi

# Push changes
git push origin HEAD:main
