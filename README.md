# Chaotic Repository Template

This repository contains the template for Chaotic-AUR's infra 4.0.
It superceeds infra 3.0, taking a different approach at distributing and executing builds.

## Reasoning

Our previous build tools, the so called [toolbox](https://github.com/chaotic-aur/toolbox) was initially created by @pedrohlc to deal with one issue: having a lot of packages to compile while not having many maintainers for all of the packages.
Additionally, Chaotic-AUR has quite inhomogene builders: servers, personal devices and one HPC which all need to be integrated somehow.
The toolbox had a nice approach to this - keeping things as KISS as possible, using Git to distribute package builds between builders. These would then grab builds according to their activated routines. While this works fairly well, it had a few problems which we tried to get rid of in the new version.
A few key ideas about this new setup:

- Since we like working with CI a lot besides it providing great enhancement for automating the boring tasks as well as making the whole process more transparent to the public as well, it was clear CI should be a major part of it.
- The system should have a scheduler that distributes build tasks to nodes, which prevents useless build routines and enables nodes to grab jobs whenever they are queued.
- The tools should be available as Docker container to make them easy to use on other systems than Arch.
- All logic besides the scheduler (which is written in TypeScript using BullMQ) should be written in Bash

## How it works

The new system consists of a three integral parts:

- The CI (which can be both GitLab CI and GitHub Actions!) which handles PKGBUILDs, their changes and figuring out what to build, utilizing a Chaotic Manager container to schedule packages via the central Redis instance.
- The central Redis instance storing information about currently scheduled builds.
- The [Chaotic Manager](https://gitlab.com/garuda-linux/tools/chaotic-manager) which is used to add new builds to the queue and executing them via the main manager container. All containers have SSH-tunneled access to the Redis instance, enabling the build containers to grab new builds whenever they enter the queue.

Compared to infra 3.0, this means we have the following key differences:

- We no longer have package lists but a repository full of PKGBUILD folders. These PKGBUILDs are getting pulled either from AUR once a package has been updated or updated manually in case a Git repository and its tags serve as source.
- No more dedicated builders (might change in the future, eg. for heavy builds?) but a common build queue.
- Routines are no longer necessary - CI determines and adds packages to the schedule as needed. The only "routine-like" thing we have is the CI schedule, executing tasks like PKGBUILD or version updates.
- The actual logic behind the build process (like `interfere.sh` or database management) was moved to the [builder container of Chaotic Manager](https://gitlab.com/garuda-linux/tools/chaotic-manager/-/tree/main/builder-container?ref_type=heads) - this one updates daily/on-commit and gets pulled regularly by the Manager instance.
- Live-updating build logs will be available via CI - multiple revisions instead of only the latest.
- The interfere repo is no longer needed, instead package builds can be configured via the `.CI` folder in their respective PKGBUILD folders. All known interfere types can be put here (eg. `PKGBUILD.append` or `prepare.sh`), keeping existing interferes working.
- The CI's behaviour concerning each package can be configured via a `config` file in the `.CI` folder: this file stores many information like PKGBUILD source (it can be AUR or something different), PKGBUILD timestamp on AUR, most recent Git commit as well as settings like whether to push a PKGBUILD change back to AUR.
- PKGBUILD changes can now be reviewed in case of major (all changes other than pkgver, hashes, pkgrel) updates - CI automatically creates a PR containing the changes for human reviewal.
- Adding and removing packages is entirely controlled via Git - after adding a new PKGBUILD folder via commit, the corresponding package will automatically be deployed. Removing it has the opposite effect.

## Workflows and information

### Adding packages

Adding packages is as easy as creating a new folder named after `pkgname` of the package. Put the PKGBUILD and all other required files in here.
Finally, add a `.CI` folder containing the basic config (`CI_PKGBUILD_SOURCE` is required), commit any changes and push the changes back to the main branch.
Please follow the [conventional commit convention](https://www.conventionalcommits.org/en/v1.0.0/) while doing so ([cz-cli](https://github.com/commitizen/cz-cli) can help with that!).

### Removing packages

This can be done by removing the folder containing a package's PKGBUILD. A cleanup job will then automatically remove any obsolete package once the next package deployment happens.

### Adding interfere

Put the required interfere file in the `.CI` folder of a PKGBUILD folder:

- `prepare`: A script which is being executed after the building chroot has been set up. It can be used to source environment variables or modify other things before compilation starts.
  - If somethign needs to be set up before the actual compilation process, commands can be pushed by inserting eg. `$CAUR_PUSH 'source /etc/profile'`. Likewise, package conflicts can be solved, eg. as follows: `$CAUR_PUSH 'yes | pacman -S nftables'` (single quotes are important because we want the variables/pipes to evaluate in the guest's runtime and not while interfering)
- `interfere.patch`: a patch file that can be used to fix either multiple files or PKGBUILD if a lot of changes are required. All changes need to be added to this file.
- `PKGBUILD.prepend`: contents of this file are added to the beginning of PKGBUILD.
- `PKGBUILD.append`: contents of this file are added to the end of PKGBUILD. Fixing `build()` as is easy as adding the fixed `build()` into this file. This can be used for all kinds of fixes. If something needs to be added to an array, this is as easy as `makedepend+=(somepackage)`.
- `on-failure.sh`: A script that is being executed if the build fails.
- `on-success.sh`: A script that is being executed if the build succeeds.

### Bumping pkgrel

This is now carried out by adding the required variable `CI_PKGREL` to `.CI/config`. See below for more information.

### .CI/config

The `.CI/config` file inside each package directory contains additional flags to control the pipelines and build processes with.

- `CI_GIT_COMMIT`: Used by CI to determine whether the latest commit changed. Used by `fetch-gitsrc` to schedule new builds.
- `CI_IS_GIT_SOURCE`: By setting this to `1`, the `fetch-gitsrc` job will check out the latest git commit of the source and compare it with the value recorded in `CI_GIT_COMMIT`.
  If it differs, schedules a build.
  This is useful for packages which use `pkgver()` to set their version without being having `-git` or another VCS package suffix.
- `CI_MANAGE_AUR`: By setting this variable to `1`, the CI will update the corresponding AUR repository at the end of a pipeline run if changes occurred (omitting CI-related files)
- `CI_PKGREL`: Controls package bumps for all packages which don't have `CI_MANAGE_AUR` set to `1`. It increases `pkgrel` by `0.1` for every `+1` increase of this variable.
- `CI_PKGBUILD_SOURCE`: Sets the source for all PKGBUILD related files, used for pulling updated files from remote repositories

### Managing AUR packages (WIP)

AUR packages can also be managed via this repository in an automated way using `.CI_CONFIG`. See the above section for details.

## Chaotic Manager

This tool is distributed as Docker containers and consists of a pair of manager and builder instances.

- Manager: `registry.gitlab.com/garuda-linux/tools/chaotic-manager/manager`
- Builder: `registry.gitlab.com/garuda-linux/tools/chaotic-manager/builder`
  - This one contains the actual logic behind package builds (seen [here](https://gitlab.com/garuda-linux/tools/chaotic-manager/-/tree/main/builder-container?ref_type=heads)) known from infra 3.0 like `interfere.sh`, `database.sh` etc.
  - Picks packages to build from the Redis instance managed by the manager instance

The manager is used by GitLab CI in the `schedule-package` job, scheduling packages by adding it to the build queue.
The builder can be used by any machine capable of running the container. It will pick available jobs from our central Redis instance.

## Development setup

This repository features a NixOS flake, which may be used to set up the needed things like pre-commit hooks and checks, as well as needed utilities, automatically via [direnv](https://direnv.net/). This includes checking PKGBUILDs via `shellcheck` and `shfmt`.
Needed are `nix` (the package manager) and [direnv](https://direnv.net/), after that, the environment may be entered by running `direnv allow`.
