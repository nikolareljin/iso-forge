Isoforge

Shell tooling for Linux images: download them from a curated list, write them to USB with `dd` or Ventoy, and build your own installable ISO from a recipe. The interface is `dialog`-based.

<img width="1111" height="606" alt="image" src="https://github.com/user-attachments/assets/5ea1e06b-feaf-4208-9c4b-80cbd99d1891" />


Repository

- GitHub (SSH): git@github.com:nikolareljin/iso-forge.git
- GitHub (HTTPS): https://github.com/nikolareljin/iso-forge.git

Important: Clone With Submodules

- This repo uses a Git submodule in `./scripts/script-helpers` for shared helpers. Clone with `--recurse-submodules`.
- Fresh clone (SSH):
  - `git clone --recurse-submodules git@github.com:nikolareljin/iso-forge.git`
  - `cd iso-forge`
- Fresh clone (HTTPS):
  - `git clone --recurse-submodules https://github.com/nikolareljin/iso-forge.git`
  - `cd iso-forge`
- If you already cloned without submodules:
  - `git submodule sync --recursive`
  - `git submodule update --init --recursive`

Recent Changes

- Root commands are short symlinks (`./isoforge`, `./forge`, `./download`, `./burn`, `./setup`, `./build`, `./test`, `./update`).
- Actual app scripts were moved from `./scripts/script-helpers/scripts/*.sh` to `./inc/*.sh`.
- Scripts resolve the repo root at runtime so they work via symlinks or direct `bash ./inc/<name>.sh`.

Curated Distros (config.json)

- I expanded `config.json` with a validated mix spanning:
  - Daily use: Ubuntu 24.04.3, Debian 13.1, Fedora 41, openSUSE Leap 15.6, Linux Mint 22, Arch (latest)
  - Cybersecurity: Kali Linux (installer 2025.2), Parrot OS
  - Cloning/backup: Rescuezilla 2.4.2, Clonezilla Live
  - Repair tools: SystemRescue 11.00, GParted Live, Hiren's BootCD PE
  - 32-bit hardware: Debian 12.7 (i386), antiX 23 (i386), TinyCore 15 (i386)
  - Media/music production: Ubuntu Studio 24.04.3
  - SBC/ARM images: Raspberry Pi OS, Ubuntu for Raspberry Pi, Armbian (Orange Pi, Banana Pi)
  - Android/Tablet: Android-x86, Bliss OS, LineageOS, GrapheneOS (factory image)
  - Surface/Xbox notes: Surface-friendly entries and Xbox notes as pointers

- Every URL in `config.json` was checked for HTTP 200 and no 404s at the time of update.
- Compressed images like `.img.xz` and `.img.gz` are supported for direct flashing; the tool will stream-decompress before writing.

Symlinked entrypoints

- The root now contains simple entrypoints without the `.sh` suffix:
  `./isoforge`, `./forge`, `./download`, `./burn`, `./setup`, `./build`, `./test`, `./update`.
- App flow entrypoints (`./isoforge`, `./forge`, `./download`, `./burn`, `./setup`) point to scripts in `./inc/*.sh`.
- Helper entrypoints (`./build`, `./test`, `./update`) point to scripts in `./scripts/*.sh`.
- `./build` and `./forge` are different things: `./build` runs packaging sanity
  checks, `./forge` builds an ISO.
- This keeps the root clean and makes commands shorter to run.

Build A Custom ISO

- `isoforge` also builds installable images, not just writes them:
  - `sudo ./forge --recipe recipes/example.yml`
  - or, from an installed package, `sudo isoforge build --recipe /usr/share/isoforge/recipes/example.yml`
- A recipe names a base image from `config.json` and describes what to change:
  packages to install or remove, apt sources and PPAs, flatpaks, files to
  overlay and scripts to run inside the image.
- It can also drive a NikOS Ansible playbook inside the image, or read a
  distrodeck export so a snapshot of a working machine becomes an ISO. Both are
  optional; a recipe with only a package list still produces a working image.
- Bases: Ubuntu and Xubuntu 24.04 and 26.04, amd64. Both casper layouts are
  handled, including the layered squashfs that Ubuntu Desktop ships.
- The finished ISO lands in `download_dir`, so `./isoforge` lists it and flashes
  it like any other image.
- Check a recipe without root, a download or a build: `./forge --recipe recipes/example.yml --dry-run`
- `recipes/nikos.yml` preserves stock Xubuntu and adds an **Install NikOS**
  launcher. After Xubuntu is installed and rebooted, it selects a NikOS profile
  and starts NikOS's own options TUI. Run
  `scripts/test-nikos-xubuntu-iso.sh` after downloading Xubuntu 24.04.4 to
  build and inspect the finished image.
- Full guide: `docs/BUILD.md`. Choosing what an image contains, and the
  limitation to know about until that lands: `docs/IMAGE-COMPOSITION.md`.

Isoforge for the CLI

- Use `./isoforge` for a simple, Etcher-like flow in your terminal:
  - Select Image (download from curated list or pick a local .iso)
  - Select Drive (USB by default)
  - Flash (with progress gauge)

Submodule Layout

- Submodule `scripts/script-helpers` points to `https://github.com/nikolareljin/script-helpers.git` and provides common helpers (logging, dialog, deps, file, etc.).
  - Tracks branch: `production`.

Clone With Submodules

- Fresh clone (SSH):
  - `git clone --recurse-submodules git@github.com:nikolareljin/iso-forge.git`
  - `cd iso-forge`
- Fresh clone (HTTPS):
  - `git clone --recurse-submodules https://github.com/nikolareljin/iso-forge.git`
  - `cd iso-forge`
- If already cloned without submodules:
  - `git submodule sync --recursive`
  - `git submodule update --init --recursive`

Update Submodule (production)

- Pull latest helper scripts from the configured branch (`production`) and record the update:
  - `git submodule update --remote --recursive`
  - `git add scripts/script-helpers && git commit -m "Update script-helpers to latest production"`
- Or use the local helper wrapper:
  - `./update` (sync + init)
  - `./update -r` (sync + init + remote refresh)

Note: The `scripts/script-helpers` submodule is already configured with an HTTPS URL in `.gitmodules`. If you need to override it locally (per-clone, without modifying `.gitmodules`), run `git config submodule.scripts/script-helpers.url https://github.com/nikolareljin/script-helpers.git && git submodule sync --recursive`.

Install Dependencies

- Use the helper-powered setup script to install required tools (`dialog`, `curl`, `jq`, `wget`, `util-linux`, `coreutils`):
  - `./setup`
  - Optionally, pass additional packages: `./setup <pkg1> <pkg2> ...`
  - The scripts also attempt to auto-install missing dependencies at runtime using the script-helpers `deps` module.

Local Quality Helpers

- Run packaging/build sanity checks:
  - `./build`
  - `./build --full` (runs full package builds)
- Run canonical local validation:
  - `./test`
  - `./test --no-shellcheck`

Usage

- Isoforge-like TUI:
  - `./isoforge`

- Config-powered utilities:
  - Download from curated list (config.json): `./download`
  - Burn an ISO from your `download_dir` (or browse): `./burn`

Where Files Are Downloaded

- Default download location:
  - `~/Downloads/iso_images`
  - Expanded path on Linux: `/home/<your-user>/Downloads/iso_images`
- This is controlled by `download_dir` in `config.json`.
- If `download_dir` is missing or empty, scripts fall back to:
  - `$HOME/Downloads/iso_images`
- Quick check:
  - `jq -r '.download_dir' config.json`
  - `ls -lah ~/Downloads/iso_images`

Multi-ISO with Ventoy

- In `./isoforge`, you can now select multiple ISO files (from your `download_dir`).
- If more than one ISO is selected, the tool switches to a Ventoy flow:
  - Installs Ventoy to the selected USB device (data is erased).
  - Optionally applies a custom background image (Ventoy theme plugin).
  - Copies the selected ISOs to the Ventoy partition, checking free space first.
  - If space is insufficient, you can deselect some ISOs to fit.

Background Image & Preview

- The tool will attempt to auto-download a matching `image-view` release binary for your OS/arch from GitHub if none is found.
- If you prefer to manage it yourself, build [image-view](https://github.com/nikolareljin/image-view) separately and place the binary at `image-view/image-view`. It is not a submodule of this repository.
- In `./isoforge`, choose “Select Ventoy Background” and select the bundled **IsoForge** or **NikOS** 1920×1080 background, or choose a custom `jpg/png/tga` image. The editable SVG sources live in `assets/ventoy/`; the PNG exports are used for reliable Ventoy rendering.

Ventoy Requirements

- The tool auto-detects Ventoy. If not found, it tries to install it:
  - via system package manager (`apt`, `dnf`, `pacman`) if available
  - otherwise it fetches the latest release from GitHub and unpacks under `./ventoy/`
- It looks for `./ventoy/Ventoy2Disk.sh`, `./tools/ventoy/Ventoy2Disk.sh`, or `Ventoy2Disk.sh` on `PATH`.
- Packages helpful for this flow (installed by `./setup`): `rsync`, `exfatprogs`, `parted`.

Installable CLI

- System install usage:
  - `isoforge [--config PATH] [--version] [--help]`
  - `sudo isoforge build --recipe PATH [--config PATH] [--output DIR] [--dry-run]`
- Example recipes when installed:
  - `/usr/share/isoforge/recipes/`
- Default config when installed:
  - `/usr/share/isoforge/config.json`
- Man page:
  - `man isoforge`

Packaging

- Debian/Ubuntu:
  - Build `.deb`: `./tools/build-deb.sh`
  - Upload to PPA: `./tools/ppa-upload.sh --ppa ppa:nikolareljin/isoforge --key-id <GPG_KEY_ID>`
- RPM (RedHat-based):
  - Build `.rpm`: `./tools/build-rpm.sh`
- Homebrew:
  - Build tarball + formula: `./tools/build-brew-tarball.sh && ./tools/gen-brew-formula.sh`
  - Publish formula: `./tools/publish-homebrew.sh`
  - Install from tap: `brew install <tap>/isoforge`

CI uses `ci-helpers` reusable workflows from the `production` branch for Debian, RPM, PPA, and Homebrew. See `docs/CI.md`.

Publishing

- PPA publishing requires GPG signing and Launchpad SSH credentials.
- Update the distro series in `debian/changelog` before uploading.
- Set `PPA_GPG_KEY_ID` as a GitHub repository variable (non-secret).
- Set `PPA_PUBLISH_ENABLED=true` as a GitHub repository variable to enable PPA publishing.
- Homebrew publishing requires a tap repo and token (`HOMEBREW_TAP_REPO`, `HOMEBREW_TAP_TOKEN`).

Man page regeneration

- Regenerate `docs/man/isoforge.1`: `./tools/gen-man.sh`

Notes on layout

- App scripts live in `./inc/*.sh`; root-level commands are symlinks.
- The `scripts/script-helpers` directory is a submodule providing helper libraries; app scripts use it via `SCRIPT_HELPERS_DIR`.
- Advanced users can invoke the underlying scripts with `bash ./inc/<name>.sh`, but the recommended way is via the root symlinks shown above.

Screenshots (CLI)

Layout and symlinks

```
$ ls -l
lrwxrwxrwx 1 user user   14 Nov  2  isoforge -> inc/isoforge.sh
lrwxrwxrwx 1 user user   15 Nov  2  download -> inc/download.sh
lrwxrwxrwx 1 user user   11 Nov  2  burn     -> inc/burn.sh
lrwxrwxrwx 1 user user   12 Nov  2  setup    -> inc/setup.sh
lrwxrwxrwx 1 user user   16 Mar  8  build    -> scripts/build.sh
lrwxrwxrwx 1 user user   15 Mar  8  test     -> scripts/test.sh
lrwxrwxrwx 1 user user   29 Mar  8  update   -> scripts/update-submodules.sh
drwxr-xr-x 2 user user 4096 Nov  2  inc/
drwxr-xr-x 5 user user 4096 Nov  2  scripts/   # local scripts
drwxr-xr-x 5 user user 4096 Nov  2  scripts/script-helpers   # helper submodule
```

Isoforge flow

```
$ ./isoforge
Image: <not selected>
Drive: <not selected>

Choose an action:
  image  Select Image
  drive  Select Drive
  flash  Flash!
  quit   Quit
```

Selecting an image from config

<img width="1063" height="626" alt="image" src="https://github.com/user-attachments/assets/63c48020-4cd1-4539-b767-2eac84366e54" />

Download progress uses the shared `script-helpers` flow (`download_file` with dialog-backed gauge/error handling).

Flashing progress

```
$ ./burn
Confirm Burn
  Image: /home/user/Downloads/iso_images/systemrescue-10.01-amd64.iso
  Drive: /dev/sdb

Flashing to /dev/sdb
[ 42% ] Writing... 420478976 bytes
```

Environment Overrides

- Set `SCRIPT_HELPERS_DIR` to point to a custom helpers location if not using the `scripts/script-helpers` submodule path.
- Downloads require `https://` by default. To explicitly allow insecure `http://` sources, set `ALLOW_INSECURE_HTTP_DOWNLOADS=1` (not recommended).

Configuration

- `config.json` controls the curated distro list and defaults:
  - `download_dir`: where downloads are saved (supports `~`).
    - Default in this repo: `~/Downloads/iso_images`
    - Runtime fallback if missing/empty: `$HOME/Downloads/iso_images`
  - `block_device_filter`: which drives to show; `usb` (default) or `any`.
  - `distros`: array of direct-download `{ id, label, url }` items and authenticated `{ id, label, browser_url }` items. `browser_url` must be HTTPS; selecting one opens the vendor page rather than attempting an unauthenticated transfer.

Example `config.json` snippet:

```
{
  "download_dir": "~/Downloads/iso_images",
  "block_device_filter": "usb",
  "distros": [
    { "id": "Ubuntu_24_04_amd64", "label": "Ubuntu 24.04 LTS (amd64)", "url": "https://releases.ubuntu.com/24.04/ubuntu-24.04.1-desktop-amd64.iso" },
    { "id": "Vendor_Installer", "label": "Vendor installer (requires account; opens browser)", "browser_url": "https://vendor.example/installer" }
  ]
}
```

Notes

- Flashing may require elevated privileges; tools use `sudo` if available.
- Progress uses `dd status=progress` and a `dialog` gauge; total percentage is based on ISO size.

---

## Clone traffic

![Clone traffic](https://raw.githubusercontent.com/nikolareljin/stats/main/charts/iso-forge.svg)

_Updated daily. Total and unique cloners over the last 14 days._
