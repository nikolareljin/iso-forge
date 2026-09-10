# IsoForge

IsoForge is a terminal application for collecting Linux installer images, creating customized Ubuntu-family installer ISOs, and preparing a Ventoy USB drive that boots one or many ISO files. The guided interface uses `dialog`; destructive USB steps are deliberate and require confirmation.

## What 2.2.0 provides

- Download a curated collection of desktop, server, recovery, NAS, firewall, hypervisor, ARM and legacy images.
- Open vendor pages in the browser for catalog items that require authentication, such as pfSense, instead of attempting an invalid anonymous download.
- Create a new installable ISO from a supported Ubuntu or Xubuntu base and a recipe.
- Create the NikOS post-install Xubuntu image: the stock Xubuntu installation runs first, then its **Install NikOS** launcher presents NikOS choices on the installed machine.
- Prepare a Ventoy USB drive and copy one or more ISOs to it. Ventoy is the standard USB path even for a single ISO.
- Use the IsoForge Ventoy background by default, or replace it with the NikOS or a custom background and review it before accepting it.

## Start here

Clone with the required helper submodule, then run setup:

```bash
git clone --recurse-submodules https://github.com/nikolareljin/iso-forge.git
cd iso-forge
./setup
./isoforge
```

For an existing clone:

```bash
git submodule sync --recursive
git submodule update --init --recursive
./setup
```

`./setup` installs the terminal, download, filesystem and ISO-build tools the application uses. It may ask for administrator approval through the system package manager.

## The normal workflow

1. Start `./isoforge`.
2. Select **Select ISO files**, then choose **Choose from curated distros** or a local-image option.
3. Select **Prepare Ventoy USB**. Confirm the exact target drive—its existing data will be erased when Ventoy is installed.
4. Optionally select a Ventoy background. Use the gallery preview, press `q` when finished reviewing it, then accept it or choose another image.
5. IsoForge runs Ventoy's own installer in the terminal. Answer Ventoy's confirmation there.
6. IsoForge mounts the newly prepared Ventoy partition and copies the selected ISOs. Boot the USB drive and choose an ISO from Ventoy’s menu.

The default download directory is `~/Downloads/iso_images`. Change `download_dir` in `config.json` to use another location.

See [docs/USER-GUIDE.md](docs/USER-GUIDE.md) for the complete download, ISO-creation and USB-preparation guide.

## Create a custom ISO

The **ISO Creator** action in the main menu starts the same supported build flow as the command line. It requires a supported Ubuntu or Xubuntu base image, a recipe, administrator privileges, build tools, substantial temporary disk space, and time to unpack/repack the image.

```bash
# Validate without downloading or writing an ISO
./forge --recipe recipes/example.yml --dry-run

# Build from a recipe
sudo ./forge --recipe recipes/example.yml

# Build the stock-Xubuntu post-install NikOS image
sudo ./forge --recipe recipes/nikos.yml
```

A recipe can identify a base with `catalog_id`, a direct HTTPS URL, or a local ISO. The output ISO is placed in `download_dir`, where the regular Ventoy flow can select it. Supported base layouts and recipe fields are documented in [docs/BUILD.md](docs/BUILD.md).

## NikOS post-install image

`recipes/nikos.yml` does not preinstall NikOS into Xubuntu. It adds the NikOS launcher and a profile to the stock Xubuntu installer. After installing Xubuntu and booting the installed system, choose **Install NikOS** from the application menu. The NikOS installer then offers its own configuration choices.

## Catalog and authenticated downloads

`config.json` has direct download entries:

```json
{ "id": "Example", "label": "Example ISO", "url": "https://downloads.example/installer.iso" }
```

and browser-only entries for authenticated vendors:

```json
{ "id": "Vendor", "label": "Vendor installer (requires account; opens browser)", "browser_url": "https://vendor.example/download" }
```

`browser_url` must use HTTPS. Selecting it opens the vendor page; complete the vendor’s download in the browser, then return to IsoForge and select the downloaded file locally.

## Commands

- `./isoforge` — main guided interface.
- `./download` — catalog download and browser handoff interface.
- `./burn` or `./isoforge burn` — opens the Ventoy-first USB workflow.
- `./forge` or `isoforge build` — create an installable ISO from a recipe.
- `./setup` — install dependencies.
- `./test` — run repository tests.
- `./build` — run packaging sanity checks.

## Safety and requirements

- USB preparation is destructive. Verify the selected device before confirming Ventoy installation.
- The ISO builder supports Ubuntu and Xubuntu 24.04/26.04 AMD64 bases. It refuses unsupported layouts or cross-architecture builds rather than producing an unreliable image.
- The builder needs root, `xorriso`, `squashfs-tools`, `rsync`, `jq`, Python with YAML support, and approximately 25 GB free scratch space.
- Downloads use HTTPS by default. Set `ALLOW_INSECURE_HTTP_DOWNLOADS=1` only when you explicitly accept an HTTP source.

## Documentation

- [User guide: download, create, and prepare USB](docs/USER-GUIDE.md)
- [Custom ISO build reference](docs/BUILD.md)
- [ISO composition notes](docs/IMAGE-COMPOSITION.md)
- [CI and packaging](docs/CI.md)
- [Command man page](docs/man/isoforge.1)

## Development

```bash
./test
./build
./tools/gen-man.sh
```

The Pages overview is published from `site/` after changes reach `main`.
