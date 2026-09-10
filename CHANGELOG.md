# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning when applicable.

## 2026-09-10 — 2.2.0

### Added
- **Ventoy-first USB preparation.** The interactive workflow installs Ventoy on the selected removable drive, copies one or more chosen ISO files, checks available capacity, and can apply bundled IsoForge or NikOS backgrounds or a user-selected image. Ventoy's own confirmation remains in the terminal so its interactive prompt works reliably.
- **ISO Creator.** `isoforge build` and the ISO Creator menu action turn a supported Ubuntu or Xubuntu base image plus a recipe into a new installable ISO. The completed image is written to the configured download directory, ready for the same Ventoy USB workflow.
- **NikOS post-install image recipe.** The Xubuntu-based NikOS image deliberately retains the stock Xubuntu installer and adds an Install NikOS launcher. NikOS choices are made after the base system is installed, rather than being baked into the base ISO.
- **Expanded curated catalog.** Ubuntu Server 24.04.4 and 26.04.1 for AMD64 and ARM64 join Ubuntu/Xubuntu 26.04.1, Proxmox VE, OpenMediaVault, OPNsense and TrueNAS Community entries.
- **Authenticated source handoff.** Catalog entries with `browser_url` open the vendor's HTTPS page instead of attempting a transfer that requires a login. pfSense uses this flow.

### Changed
- Download progress now presents transferred and total sizes in MiB and calculates the percentage from byte counts.
- Background previews use image-view gallery mode and stay open until the user exits them, followed by an explicit use-or-choose-another prompt.

### Fixed
- Setup uses `exfatprogs` instead of the obsolete `exfat-utils` package on current Debian and Ubuntu releases.
- Dependency installation and download failures remain visible with actionable status rather than appearing stalled.
- Ventoy preparation requests elevated privileges before device access, keeps its native confirmation prompt in the terminal, uses its default MBR-compatible layout, verifies the EFI fallback bootloader, and removes IsoForge-owned temporary mounts.
- The generated man page now matches the Ventoy-first CLI description.
- `burn` starts without `--config` again. The compatibility entrypoint expanded `CONFIG_FILE` before its default was assigned, and the assignment sat below the `exec` where nothing can reach it, so under `set -u` a bare `./burn` died on an unbound variable instead of opening the Ventoy UI.
- `--dry-run` now refuses a base the build would refuse. It checked `compatibility.base_filename_patterns` only against a `--base-iso` override, so a recipe whose configured `catalog_id`, `base.url` or `base.iso` its own patterns forbid reported "Recipe is valid" and then failed the real build. Both branches now run the same check the build runs.

## 2026-09-03 — 2.1.3

### Fixed
- **The rpm job builds.** 2.1.2 tried to give `rpm-build.yml` an absolute `working_directory` so rpmbuild's `_topdir` would resolve, and picked `${{ github.workspace }}`. A `workflow_call` `with:` block is evaluated before any runner exists, so that expression is the empty string, and the failure only moved earlier: `[ERROR] Spec file not found (use --spec): /packaging/isoforge.spec`. No value a caller can write here fixes it, so the fix went to [ci-helpers 0.22.1](https://github.com/nikolareljin/ci-helpers/pull/155), which takes `_topdir` from `pwd` — absolute by construction, whatever the caller passes. This repository goes back to a plain `"."`.

  Requires ci-helpers `production` to be at 0.22.1 or later.

## 2026-09-03 — 2.1.2

### Fixed
- **The deb job could not upload what it built.** `dpkg-buildpackage` writes the `.deb` to the parent of the source directory, which is outside the workspace, and `upload-artifact` refuses a path containing `..`: `Invalid pattern '../*.deb'`. The package had been building fine and then failing on the upload. The build command now moves the artifacts into `dist/` and the glob points there.
- **The rpm job died in `%prep`.** `rpm-build.yml` passes `working_directory` straight into rpmbuild's `_topdir`, and `"."` made it relative, so `%prep` resolved `_builddir` to an absolute `/packaging/rpm/build/BUILD` that does not exist: `Bad exit status from /var/tmp/rpm-tmp.* (%prep)`. It was changed to pass `${{ github.workspace }}`, which **did not work** — see 2.1.3.

Both were diagnosed when the release workflow first ran and then left while other work took priority. They are the only two jobs that have never produced an artifact.

## 2026-09-03 — 2.1.1

### Changed
- Vendored `script-helpers` moves from 0.9.2 to 0.24.0. The pin was far enough behind that a generated activity log inside the checkout showed as a repository change, because it predated `script-helpers` learning to ignore those itself. The Bash API is additive across the range — 111 functions to 294, none removed — and every packaging wrapper was exercised against the new tree before the pin moved.

### Notes
- The two defects `tools/gen-brew-formula.sh` repairs are still present at 0.24.0: the dependency block still reaches the formula with literal `\n` separators, and the `bin` shim is still named after `--entrypoint`. The packaging helpers are also still mode 644, so `tools/*.sh` still has to invoke them through `bash` rather than gate on the executable bit. The workarounds stay.

## 2026-09-01 — 2.1.0

### Added
- **The NikOS recipe pins an immutable tag.** What a recipe pins decides what ends up in the image, so it has to name something that cannot change underneath it. `scripts/test-forge-nikos.sh` now requires a bare `X.Y.Z`, so a branch or a moving ref cannot be pinned by accident.
- **A real NikOS ISO build, verified end to end.** `.github/workflows/nikos-iso.yml` downloads a stock Xubuntu 24.04.4 image, runs `recipes/nikos.yml` against it, and checks the result. Nothing in it is mocked. It runs on demand and automatically when the builder, the recipes or the workflow change, since that is when "does a real build still work?" is worth an hour.
- `scripts/verify-nikos-iso.sh` inspects a finished image rather than trusting the build log: ISO 9660, an El Torito boot record, the recipe's volume id, a plausible size, and then inside the root filesystem the NikOS CLI, its Plymouth theme, the Xfce session, LightDM, desktop configuration in `/etc/skel`, an emptied `/etc/machine-id` and no leftover `policy-rc.d`.
- `scripts/test-forge-nikos.sh` runs on every pull request and covers what the hour-long build should not be the first to catch: the recipe's base, output, `/etc/skel` handoff and pinned playbook ref, and the tag guard below.

### Fixed
- **Ansible collections were installed where the playbook could not find them.** `ansible-galaxy` writes under `$HOME/.ansible` and `ansible-playbook` reads from the same place, so once `HOME` followed `skel_home` for the run but not for the install, the collections were written to `/root/.ansible` and looked for in `/etc/skel/.ansible`. The build failed with `couldn't resolve module/action 'community.general.timezone'`. Both now run with the same `HOME`.
- **`HOME` did not follow `skel_home`.** Roles install per-user tooling by shelling out to installers that honour `$HOME`, while their `creates:` guards and later tasks look under the playbook's own home variable. With the two disagreeing, an installer writes to one place and the next task reads the other. NikOS's nvm step failed exactly that way, installing into `/root/.nvm` and then failing to source `/etc/skel/.nvm/nvm.sh`. `HOME` is now set to `skel_home` for the playbook run, which is also the result that was wanted: whatever a role leaves in the user's home is copied into every account the installer creates.
- **The build host's environment leaked into the chroot.** `forge_in_chroot` used `env` rather than `env -i`, so whatever the caller had set reached the image being built. The second real end-to-end run failed on it: `NVM_DIR=/home/runner/.nvm`, inherited from the CI runner, pointed an installer at a directory that does not exist inside the image. The same leak would have carried `SUDO_*`, `GITHUB_*`, proxy settings and a host `HOME`, and it means an image could differ depending on who built it. The chroot now starts from an empty environment with an explicit allow-list.
- **A failed boot-argument split would have gone unnoticed.** `mapfile < <(cmd)` cannot see `cmd` fail, so if the split ever errored the argument list would be empty and xorriso would pack with no boot arguments at all — an image that mounts perfectly and boots nothing, which is precisely what reading those arguments back exists to prevent. The split is captured by command substitution now, and both a failure and an empty result abort the pack.
- **A failed layer extraction left several gigabytes behind.** The verifier reported the failure and moved on without removing the partial directory, on a run already tight on disk.
- **The merge did not understand overlayfs whiteouts.** A path deleted in an upper layer is recorded as a `0:0` character device, and copying that over the directory it deletes fails: `cp: cannot overwrite directory '.../fwupd-1.9.33' with non-directory`. The merge now applies the deletion, drops the marker and copies the rest, which is what the whiteout means. A character device that is not `0:0` is left alone.
- **A silent layer merge failure would have inverted the verdict.** `rsync` and its `cp` fallback were both `|| true`, so a partial merge left an incomplete filesystem and every assertion after it reported files as missing that were really present — the same shape as the unsquashfs bug it was written to replace. A failed merge is now a reported failure.
- **An empty or unexpected `install-sources.yaml` raised instead of reporting.** The parser took `found[0]` without checking, so an `IndexError` under `set -e` aborted the verifier before it printed a summary. Both the empty-document and no-`path` cases now produce a clean failure.
- **The verifier needs root, and now says so.** Unpacking a root filesystem means recreating device nodes, including the character devices overlayfs uses as whiteouts in a layered image. Unprivileged, `unsquashfs` skips them and then dies on the first hardlink to one, so every layer failed and the image looked as though it contained no NikOS. It runs under `sudo env TMPDIR=...`, which is the one form that gives it both root and the scratch directory, and it warns when run without root rather than failing obscurely.
- **"the root filesystem unpacks" passed on an empty directory.** It only checked the directory existed, which `mkdir` had just created, so a run where every layer failed to unpack still passed that check and then reported four separate missing-file failures — pointing at the image rather than at the unpack that actually broke. It now requires `/usr/bin`, `/usr/sbin`, `/etc` and `/var` and stops there, saying nothing below is meaningful.
- **The verifier's `TMPDIR` never took effect.** It ran as `sudo TMPDIR=... verify-nikos-iso.sh`, and sudo resets the environment by default, so the several gigabytes of extraction went to `/tmp` regardless of the intent. Nothing in the verifier needs root, so it runs unprivileged with `TMPDIR` set and only the directory is created with `sudo`.
- **A missing PyYAML would have surfaced as a traceback.** The layered path imports `yaml` without checking for it, and under `set -e` that took the whole verifier down without saying what was wrong. It is checked first and reported by name.
- **The build's own scaffolding shipped inside the image.** The root filesystem is squashed between `forge_chroot_cleanup` and `forge_chroot_leave`, and the teardown of `policy-rc.d` and `resolv.conf` happened in the latter. So every image carried a `policy-rc.d` returning 101, which refuses to start services on the installed machine, and the build host's `resolv.conf` in place of the image's own. Both are undone before the repack now, and repeated on the way out for builds that fail earlier. Caught by the artifact verifier, not by reading the code.
- **The tag guard matched tags as regexes.** `grep -qx` treats its argument as a pattern, so a tag carrying a metacharacter would match something it does not name, or fail to match itself, and the guard would then report the opposite of the truth. Matching is fixed-string now.
- **The verifier claimed the image was checksummed without checking.** Every other assertion reads structure, so a truncated or corrupted image passed them all. It now recomputes the sha256 and compares it against the file the build wrote.
- **The verifier lost most of the layer it was checking.** Layers were unpacked on top of one another, and `unsquashfs` aborts a whole layer the first time it has to create a hardlink where a file already exists: `FATAL ERROR: create_inode: failed to create hardlink, because File exists`. Everything after that point was silently absent, which read as a build that had not installed NikOS when in fact it had. Each layer is now unpacked into its own directory and merged in order with `rsync`, and a layer that fails to unpack is reported rather than swallowed.
- **The rebuilt image could not be packed.** The boot arguments read back from the base were split with `xargs`, and a bare `-e` in its input comes out as an empty field. xorriso's report contains exactly that — `-e '--interval:appended_partition_2_...'` for the EFI boot image — so the interval was left as a positional argument and xorriso refused the whole command. Splitting is done with `shlex` now, which honours the single quotes and keeps `-e`.
- **`install-sources.yaml` names files, not stems.** Ubuntu writes `path: minimal.standard.squashfs`, extension included, while everything downstream works in stems. The install source was therefore never recognised and the layer selection below silently fell back to the topmost squashfs. Matching and rewriting now happen on stems, and the value is written back in whichever form the file already used. Verified against the file Xubuntu 24.04.4 actually ships.
- **The build stacked onto the wrong layer.** For a layered image the topmost squashfs was taken as the one to build on, but Ubuntu ships `minimal.standard.live` above `minimal.standard` and only the latter is installed; the live layer exists for the session you boot into. The customization therefore landed where the installer never looks, and registration then failed because `install-sources.yaml` names `minimal.standard` and the build offered it `minimal.standard.live.isoforge`. The layout detection now reads the install source out of `install-sources.yaml` and drops any layer stacked above it.
- **`ansible.extra_vars` could only pass strings.** The values were emitted as a series of `-e key=value` pairs, and ansible parses those as strings whatever they look like, so `nikos_vscode_extensions: []` arrived as the string `"[]"` and a role concatenating it with another list failed on the type. They are now passed as one JSON object, alongside `nikos_home` and `nikos_user`, so a recipe can hand the playbook lists and mappings and have them survive.
- **VS Code extension installation broke the NikOS build.** The first real end-to-end run reached `ok=118 changed=64 failed=1`, failing only on `code --install-extension`, which refuses to run as root without `--no-sandbox` and an explicit `--user-data-dir`. Emptying `nikos_vscode_extensions` and `nikos_vscode_ai_extensions` is the right answer rather than a workaround: extensions install into a user's own `~/.vscode`, so there is no build-time location an installed account would inherit. They belong on the machine after first login.
- **`recipes/nikos.yml` skipped a role that cannot be skipped.** It carried `skip_tags: [github-setup]`, but `github-setup` is a role with no `tags:` key, and `--skip-tags` matches tags rather than role names. The skip did nothing. Confirmed against the playbook itself: `ansible-playbook site.yml --list-tags` reports `ai-local, always, education, music, network, never` and the `never`-gated opt-ins, with no `github-setup` among them.
- The recipe now skips `ai-local`, `network`, `music` and `education`, which are tags that exist. `ai-local` matters most: it pulls Ollama models, which are gigabytes and belong on the installed machine rather than in an ISO.
- **A recipe naming a tag the playbook does not define now fails the build.** The two failure modes are not symmetric: a bad `tags` entry runs less than intended and is obvious, while a bad `skip_tags` entry silently runs *more* than intended, which for an image build is the expensive direction. iso-forge asks the playbook with `--list-tags` and refuses to continue on a mismatch; an unreadable listing warns rather than blocking.

## 2026-09-01 — 2.0.2

### Fixed
- **The Debian package could not be built.** `debian/source/format` declared `3.0 (quilt)`, which requires an upstream tarball at `../isoforge_<version>.orig.tar.*`. This project has no separate upstream release, so `dpkg-source` refused with "no upstream tarball found" and the `deb` job failed the moment it was able to run at all. The package is native, and now says so.
- **The RPM could not be built.** The spec's `%autosetup` unpacks `Source0`, but no `Source0:` was declared, so `rpmbuild` stopped with "error: No source number 0". It now declares `%{name}-%{version}.tar.gz`, which is exactly the tarball and prefix `build_rpm_artifacts.sh` writes into `SOURCES`.

Both were invisible until 2.0.1 fixed the workflow permissions, because until then the release run was rejected before any job started.

### Changed
- `README.md` describes building images, lists `./forge` among the entrypoints, distinguishes it from `./build`, documents `isoforge build` for a system install, and drops the placeholder PPA target that the release workflow no longer uses.

## 2026-09-01 — 2.0.1

### Fixed
- **The release workflow had never run.** GitHub validates a called workflow's declared permissions against what the caller grants, before any job starts. `ci-helpers/deb-build.yml` declares `contents: write`, this repository's default workflow permission is `read`, and `.github/workflows/main.yml` granted nothing, so every push to `main` was rejected with a startup failure and the deb, PPA, RPM and Homebrew jobs never executed. Going back through the run history, `Main` has failed on every commit since March and produced no package at any point. The workflow now grants `contents: read` by default and `contents: write` only to the job whose callee asks for it.

## 2026-09-01 — 2.0.0

### Added
- **`isoforge build` remasters a base image into a custom installable ISO.** Until now the tool could only write images someone else had built; now `./forge --recipe recipes/nikos.yml` takes a stock Ubuntu or Xubuntu image, applies a recipe and writes an ISO that installs the finished system. The result lands in `download_dir`, so the existing flash path picks it up unchanged.
- Recipes are YAML: a base image, packages to install or remove, apt sources, PPAs and keys, flatpaks, files to overlay and scripts to run inside the image. A `recipe.local.yml` beside a recipe is merged over it, the same tracked-defaults and untracked-overrides split NikOS uses for `vars/main.yml` and `vars/local.yml`.
- Optional integrations, either or neither: a NikOS Ansible playbook run inside the image, and a distrodeck export read as a package list so a snapshot of a working machine becomes an ISO.
- Both Ubuntu casper layouts. A single `filesystem.squashfs` is unpacked, edited and squashed back. The layered `minimal.standard.squashfs` stack is mounted read-only as overlayfs lowerdirs so the build writes into a fresh upperdir, which is then squashed as a new top layer and registered in `install-sources.yaml`; rewriting a layer in place would mean deciding which files belong to which layer.
- Xubuntu 24.04, Xubuntu 26.04 and Ubuntu 26.04 in the distro catalog.
- `docs/BUILD.md`, and `scripts/test-forge-{recipe,distrodeck,image}.sh` wired into `./test`.

### Notes
- Building needs root, about 25 GB of scratch space and 20 to 40 minutes. `--dry-run` validates a recipe with none of that.
- Boot arguments are read back from the base image with `xorriso -report_el_torito as_mkisofs` rather than hand-written, because hand-written boot flags are the usual reason a remastered image will not start. The base image must stay readable for the whole build.
- Snaps cannot be installed into a chroot; a `snap` section in a distrodeck export is reported and skipped rather than silently dropped.
- Arch is not supported. `archiso` shares nothing with casper and needs its own pipeline.

## 2026-09-01

### Repository
- Repointed every in-repository reference from `burn-iso` to `iso-forge` in preparation for renaming the GitHub repository, so the repository URL, Pages path and published identity will match the `isoforge` CLI and package. The GitHub-side rename itself is a separate step tracked in `docs/REPOSITORY-RENAME.md`; until it lands, `nikolareljin/iso-forge` does not resolve. The CLI, package name, Homebrew formula and man page are unchanged.
- Updated clone URLs, packaging metadata, workflow inputs, Pages links and the clone-traffic badge to `nikolareljin/iso-forge`.

### Fixes
- `inc/burn.sh` now defaults `SCRIPT_HELPERS_DIR` to `scripts/script-helpers`, matching every other entrypoint. `./burn` previously exited with a missing-helpers error on a correctly initialized clone.
- Version metadata is aligned at `1.1.0` across `VERSION`, `debian/changelog` and `packaging/isoforge.spec`, which had drifted to `0.1.0-1`.
- `tools/gen-brew-formula.sh` now builds release URLs from bare `X.Y.Z` tags instead of a `v`-prefixed tag that is never created.
- Replaced the placeholder PPA target in `.github/workflows/main.yml`.
- `tools/*.sh` gated on the script-helpers helper being executable, but upstream ships `build_brew_tarball.sh`, `gen_brew_formula.sh`, `build_rpm_artifacts.sh` and `publish_homebrew.sh` mode 644. Four of the six wrappers therefore failed with a misleading "script-helpers not initialized" error. They now check for the file and invoke it with `bash`.
- `tools/build-deb.sh` relied on the helper's default `--prebuild "make man"`, which fails because this repository has no Makefile. It now passes `./tools/gen-man.sh` explicitly.
- `tools/gen-brew-formula.sh` repairs two defects in the upstream generator: its dependency block reaches the formula with literal `\n` separators, and it names the `bin` shim after `--entrypoint`, producing `bin/"inc/isoforge.sh"` instead of `bin/"isoforge"`. Both are corrected with `awk` and a temporary file, which also works on the macOS hosts that run Homebrew publishing.
- Added the `packaging/rpm/build/` rpmbuild tree to `.gitignore`; `tools/build-rpm.sh` creates it.
- Every `tools/*.sh` wrapper sourced `helpers.sh` before checking that the submodule was initialized. Under `set -e` that aborted with a bare shell error and the friendly message at the bottom was unreachable. The check now runs first, and the helper check is an early guard rather than a trailing branch.
- The `brew` job now passes an explicit `tarball_url`. `ci-helpers/homebrew-package.yml` defaults to a `v`-prefixed tag while `ci-helpers/auto-tag-release.yml` creates bare `X.Y.Z` tags, so the published formula pointed at a URL that does not exist.
- `README.md` no longer describes `image-view` as a submodule of this repository.

### Removed
- Deleted the unreferenced `inc/include.sh` and `inc/distros.sh`. Their distro tables were superseded by `config.json`, and `is_valid_iso` resolves from `scripts/script-helpers/lib/file.sh`.
- Dropped the stale `image-view` entry from `.gitmodules`; it had no gitlink in the index and collided with the path `ensure_image_view_available` downloads into.
- Stopped tracking `packaging/homebrew/isoforge.rb`. It is regenerated by `tools/gen-brew-formula.sh` from a freshly built tarball before publishing, so a committed copy carries a `sha256` that cannot match the release asset. Both `tools/gen-brew-formula.sh` and `tools/publish-homebrew.sh` write or read it at the same path as before.

## 2026-03-11

### TUI
- `Flash!` in `inc/isoforge.sh` now redirects users to drive selection when no drive is chosen, keeps the current image selection intact, and continues into the flash confirmation flow after a drive is picked.
- Added `scripts/test-flash-drive-redirect.sh` and wired it into `./test` to keep the redirect behavior covered.
- Download failures now persist their latest summary, source, URL, timestamp, and `/tmp` log path in session state so the details remain visible in the `isoforge` main status panel after the error dialog is dismissed.
- `./download` now prints the last tracked download failure summary and log path at the end of a failed run.
- Added `scripts/test-download-error-state.sh` and wired it into `./test` to keep the persisted error summary behavior covered.

## 2026-03-08

### TUI
- Main-menu actions in `inc/isoforge.sh` now restore the last committed selection state after a canceled or failed sub-flow, so Cancel consistently returns users to the main page without leaking partial image/drive/background choices.
- Added `scripts/test-cancel-flow.sh` and wired it into `./test` to keep cancel rollback behavior covered.

### Downloads
- Refactored download flows in `inc/isoforge.sh` and `inc/download.sh` to use script-helpers download methods (`download_file`/dialog-backed progress) instead of duplicated in-repo gauge implementations.
- Aligned `inc/download.sh` helper path default to `scripts/script-helpers` to match the script-helpers layout.

### Tooling
- Added canonical helper entrypoints:
  - `./build` -> `scripts/build.sh`
  - `./test` -> `scripts/test.sh`
  - `./update` -> `scripts/update-submodules.sh`
- Added build/test/update helper scripts with strict shell settings and reproducible local workflows.
- `scripts/update-submodules.sh` now supports `-r` for remote submodule refresh mode.

## 2026-01-09

### Breaking
- Renamed the primary CLI to `isoforge`; the `etcher` entrypoint is removed.
- Installable packages now provide `/usr/bin/isoforge` and `/usr/share/isoforge/config.json`.

### Packaging
- Added Debian, PPA, and RPM packaging support with CI workflows.

## 2025-11-07

- Created this changelog and summarized recent work.

## 2025-11-06

### UX and Menus
- Grouped selection UI for downloads and Etcher with clear category headers:
  Desktop / Linux; SBC — Raspberry Pi; SBC — Armbian / TV Box; Android / Tablet; Utilities / Repair; Surface / Xbox.
- Headers are non-selectable: ignored in multi-select, and re-prompted in single-select if chosen.

### Distros
- Expanded curated list in `config.json`:
  - Raspberry Pi: Raspberry Pi OS (Bookworm) Lite (arm64/armhf) and Ubuntu preinstalled server for RPi (arm64).
  - Armbian for Orange Pi 5/3, Banana Pi/M2+ (redirects to latest), and community TV box builds (Amlogic S905X).
  - Android-based OSes: Android-x86 9.0-r2, Bliss OS 15, LineageOS 21 (x86_64 ISO), GrapheneOS factory image (note-only).
  - Alternatives for Surface/Xbox: NixOS 24.05 GNOME, Ubuntu 24.04.3 Desktop/Server references.

### Flashing and Images
- Auto-decompression on flash: streamed write for compressed images
  - `.img.xz`/`.xz` via `xz -dc | dd`
  - `.img.gz`/`.gz` via `gzip -dc | dd`
  - Shows progress gauge (percent unknown for streams, completes on finish).

### Preview
- Switched CLI image preview fallback from `viu` to `chafa` for broader Linux/macOS support.
- Kept external `image-view` as preferred preview when present.
- In-terminal preview uses `chafa | less -R`; user presses `q` to close.

### Dependencies and Setup
- First-run dependency installer now uses a minimal dialog gauge and logs details to `.deps_install.log`.
- Core and helpful tools installed: `dialog`, `jq`, `curl`/`wget`, `util-linux`, `coreutils`, `file`, `rsync`, `unzip`,
  plus preview/decompression helpers: `chafa`, `less`, `xz`/`xz-utils`, `gzip`.

### Terminal Hygiene
- When dialogs are cancelled or the app exits, restore terminal state and clear the screen (EXIT/INT/TERM traps).

## 2025-11-05

### Downloads
- Download dialog switched to script-helpers’ default dialog helpers.
- Gauge-only download: removed extra stdout prints during downloads.
- Gauge labels now use the human-friendly distro name.

### Etcher
- Downloads within Etcher also use friendly labels in the gauge and suppress extra prints.
