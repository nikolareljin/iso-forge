# Building a custom ISO

`isoforge build` takes a stock Ubuntu or Xubuntu image and a recipe, and writes
an installable ISO with your packages, files and settings already in it. The
result installs the same way the base image does; there is no separate
provisioning step on the target machine.

```bash
sudo ./forge --recipe recipes/example.yml
# or, from an installed package
sudo isoforge build --recipe /usr/share/isoforge/recipes/example.yml
# --config means the same thing here as it does for `isoforge`
sudo ./forge --recipe recipes/example.yml --config /path/to/config.json
```

The finished image lands in `download_dir` from `config.json`, so `./isoforge`
lists it alongside downloaded images and writes it to USB with the same flash
path as anything else.

## What it needs

- Root. The build mounts the base image's filesystems and chroots into them.
- `xorriso`, `squashfs-tools`, `rsync`, `jq`, `python3` and PyYAML.
  `./setup` installs all of them, and preflight checks for them before anything
  is downloaded. PyYAML's package name varies: `python3-yaml` on Debian and
  Ubuntu, `python3dist(pyyaml)` on RPM distributions.
- About 25 GB free in the work directory, `/var/tmp/isoforge` by default. The
  extracted ISO tree, the unpacked root filesystem, the rebuilt squashfs and
  the output image are all on disk at once.
- 20 to 40 minutes, most of it `mksquashfs`.

Check a recipe without any of that:

```bash
./forge --recipe recipes/example.yml --dry-run
```

## Supported base images

Ubuntu and Xubuntu 24.04 and 26.04, amd64. Both casper layouts are handled:

- **single** — one `casper/filesystem.squashfs` holding the whole root. It is
  unpacked, edited and squashed back.
- **layered** — `minimal.squashfs` with `minimal.standard.squashfs` and friends
  stacked on top, listed in `casper/install-sources.yaml`. Rewriting one of
  those in place would mean deciding which files belong to which layer, so
  instead the existing layers are mounted read-only as overlayfs lowerdirs and
  the build writes into a fresh upperdir. The result is squashed as a new top
  layer and registered in `install-sources.yaml`.

  Which layer it stacks onto matters. The topmost squashfs is not the one the
  installer uses: Ubuntu ships `minimal.standard.live` above `minimal.standard`,
  and the live layer exists only for the session you boot into. Building on top
  of it would put the customization somewhere the installer never reads, so the
  build follows `install-sources.yaml` and ignores any layer above the one it
  names.

For a layered image, the new layer has to be registered in
`install-sources.yaml` or the installer keeps using the original layer and
drops everything the build added. If that file is missing, or its layered
source cannot be repointed, the build fails rather than writing an image whose
customizations would be ignored.

The new layer also gets its own sidecar files, because the installer looks them
up by stem. Its `.manifest` is regenerated from the finished system, since that
manifest is what a minimal install consults to decide what to remove; the
vendor's `.manifest-remove` and `.manifest-minimal-remove` lists are carried
over unchanged.

An image with no `casper/` directory is refused, naming what was found. Arch is
not supported: `archiso` shares nothing with casper and needs its own pipeline.

Cross-architecture builds are refused rather than attempted. The architecture
is read from `.disk/info`, falling back to the image filename; when neither
says, the check is skipped rather than guessed at.

## The recipe

Only `recipe`, `base` and `output.name` are required. A recipe with just those
and a package list produces a working image.

```yaml
recipe: nikos-desktop

base:
  catalog_id: Xubuntu_24_04_4_desktop_amd64   # an id from config.json
  # url: https://…                            # or a direct URL
  # iso: /path/to/base.iso                    # or a local file
  # sha256: …                                 # optional; checked when given

output:
  name: nikos-24.04-amd64      # the ISO filename, without .iso
  volume_id: NIKOS_2404        # at most 32 of [A-Za-z0-9_.-]
  label: NikOS 24.04

packages:
  install: [git, curl, tmux]
  remove:  [gnome-mahjongg]

sources:
  ppas: ["ppa:graphics-drivers/ppa"]
  apt:  ["deb [signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable"]
  keys:
    - url:  https://download.docker.com/linux/ubuntu/gpg
      dest: /usr/share/keyrings/docker.gpg

flatpak:
  - org.gimp.GIMP

overlay:
  - src: overlay/etc/skel    # relative to the recipe
    dest: /etc/skel          # absolute, inside the image

hooks:
  chroot:
    - hooks/10-locale.sh     # runs inside the image, as root
```

`volume_id` is restricted to letters, digits, underscore, dot and dash, and to
32 characters, because it is substituted into the boot configuration, replacing
the base image's own label so entries naming the volume follow it. When
`volume_id` is absent the build falls back to `label`, so the same rules apply
to `label` in that case: `label: NikOS 24.04` needs an explicit `volume_id`
beside it.

Package names are validated against Debian's naming rules before they reach
apt, and every value a recipe contributes is shell-quoted on its way into the
chroot. A recipe is data; it cannot become a command running as root.

Stages run in a fixed order: keys and sources, `apt update`, removals,
installs, distrodeck, Ansible, overlay, hooks. The update runs whenever sources
changed, even with no packages to install, because that update is what proves a
new source line or key works; a broken one fails the build rather than the
first machine installed from the image. Sources come first because the
installs may come from them; removals precede installs so a recipe can replace
a package; the overlay lands after the package manager so your files win; hooks
run last so they see the finished system.

### Local overrides

`recipes/foo.local.yml` is merged over `recipes/foo.yml` when it exists, the
same split NikOS uses for `vars/main.yml` and `vars/local.yml`: tracked
defaults, untracked machine-specific values. Add it to `.gitignore` if it holds
anything private.

## Using distrodeck

A distrodeck export turns a real machine into a package list:

```bash
distrodeck export --output workstation.txt
```

```yaml
distrodeck:
  export: workstation.txt
  sections: [apt_manual, ppas, apt_sources, flatpak]
```

The export is parsed directly rather than passed to `distrodeck import`, which
targets a running system and expects to offer a revert. Sections default to the
four above.

**Snaps cannot be installed into an image.** snapd needs its own mount
namespace and a running daemon, neither of which exists in a chroot. A `snap`
section is reported and skipped rather than silently dropped; seed those on
first boot instead.

## Using NikOS after base installation

`recipes/nikos.yml` is intentionally not an Ansible recipe. It preserves the
stock Xubuntu 24.04 installer and overlays only an **Install NikOS** desktop
entry, the `nikos-installer` launcher, and the `xubuntu-24.04` profile.

Install Xubuntu first and reboot into the installed system. Then select
**Install NikOS** from the application menu. The launcher refuses to run in the
live session, asks for an available NikOS profile, fetches the pinned NikOS
installer, and hands control to its normal TUI. That TUI selects the optional
bundles and writes NikOS configuration on the installed machine; no NikOS
packages, configuration, models, or Ansible run are baked into the ISO.

The first profile supports Xubuntu 24.04. The profile directory and launcher
arguments (`--profile` and `--ref`) are deliberately extensible for Ubuntu
Server and antiX, but those profiles are not shipped yet.

To perform the full artifact test after downloading Xubuntu 24.04.4 with
iso-forge:

```bash
./scripts/test-nikos-xubuntu-iso.sh
```

It uses `~/Downloads/iso_images/xubuntu-24.04.4-desktop-amd64.iso` by default,
creates `nikos-xubuntu-24.04-amd64.iso` beside it, and inspects the resulting
ISO. Use `NIKOS_XUBUNTU_ISO=/path/to/xubuntu.iso` for another location.

## Choosing what the image contains

Today a recipe provisions one fixed selection. Making that selectable, and the
defect that blocks it, are described in `docs/IMAGE-COMPOSITION.md`.

## Verifying a NikOS image

`.github/workflows/nikos-iso.yml` runs `recipes/nikos.yml` end to end on a real
Xubuntu base, then checks the artifact rather than the build log:

```bash
scripts/verify-nikos-iso.sh ~/Downloads/iso_images/nikos-xubuntu-24.04-amd64.iso
```

It asserts the image is ISO 9660, carries an El Torito boot record, has the
recipe's volume id, then unpacks the root filesystem and checks the launcher,
Xubuntu profile and desktop entry. It also proves that `/usr/local/bin/nikos`
was not preinstalled into the base system.

The full test runs only after the Xubuntu base image is available and needs
root plus about 25 GB of scratch space.

## Checking the result

```bash
xorriso -indev out.iso -toc
sudo ./forge --recipe recipes/nikos.yml --smoke-test
```

`--smoke-test` boots the image headless under QEMU and reports whether the
firmware reached a bootloader. It does not prove the installer runs to
completion; boot the flashed USB on real hardware before trusting an image.

Boot flags are the usual reason a remastered image fails to start. Rather than
guessing at `-as mkisofs` arguments, the build asks xorriso to report the ones
that reproduce the base image's boot setup and reuses them. The base image has
to stay readable at its path for the whole build, because that report names it.

## Reproducibility

Commands run inside the image start from an empty environment: `PATH`, `HOME`,
`USER`, `LOGNAME`, `SHELL`, `TERM`, `LANG`, `LC_ALL` and `DEBIAN_FRONTEND`, and
nothing else. Whatever the caller has exported does not reach the build, so the
same recipe on the same base produces the same image whether it runs on a
workstation or a CI runner.

That is not theoretical: an early run of the NikOS build failed because
`NVM_DIR` from a CI runner reached the chroot and pointed an installer at a
host path.

## When a build fails

The work directory is left in place. Every mount the build made is released on
the way out, including on failure, so `/proc` and `/sys` are never left bound
inside it. Add `--keep` to keep the scratch directories after a successful
build too; the downloaded base image stays in `<work-dir>/cache` either way, so
the next build of the same base does not re-download it.

```bash
sudo ./forge --recipe recipes/example.yml --work-dir /mnt/big/isoforge --keep
```
