# User guide: download, create, and prepare a USB drive

IsoForge has two related jobs:

1. obtain or create ISO installer images; and
2. prepare a Ventoy USB drive that boots those images.

Ventoy is the standard USB path. Use it for one ISO or many, so the drive remains reusable: add or remove ISO files later instead of re-imaging the USB drive for every operating system.

## Before you begin

Clone with submodules and install dependencies:

```bash
git clone --recurse-submodules https://github.com/nikolareljin/iso-forge.git
cd iso-forge
./setup
```

Start the application with:

```bash
./isoforge
```

The standard image directory is `~/Downloads/iso_images`. Set `download_dir` in `config.json` before starting if another directory is preferred.

> USB preparation erases the selected drive when Ventoy is installed. Back up its contents and identify the target drive before proceeding.

## Download one or more images

1. In the main menu, select **Select Images**.
2. Choose **Choose from curated distros**.
3. Select one or more entries. The catalog includes desktop Linux, Ubuntu Server for AMD64 and ARM64, recovery tools, NAS, firewall and virtualization images.
4. IsoForge downloads direct catalog entries to `download_dir`. Its progress display shows downloaded MiB, total MiB, and a percentage calculated from the underlying byte counts. Compressed catalog images such as `.img.xz`, `.img.gz`, and `.iso.bz2` are unpacked to a bootable ISO or raw image before Ventoy uses them; the original archive is retained.
5. Entries labelled as requiring an account are handled differently: IsoForge asks to open the vendor’s HTTPS page in the browser. Complete the download there, then return to **Select Images** and choose **Choose local ISO files**.

A download error remains visible in the main status area after its error dialog closes, including the source and log location.

### Download from the command line

Use `./download` for the same catalog without entering the main USB workflow. Direct selections download into `download_dir`; authenticated selections open the browser.

## Create a new ISO

Use ISO Creator when the desired installer must contain a customized Ubuntu or Xubuntu system. It builds a new ISO from a base image and a YAML recipe.

### Prerequisites

- A supported Ubuntu or Xubuntu 24.04/26.04 AMD64 base ISO.
- Administrator privileges. The builder mounts the ISO and chroots into its root filesystem.
- `xorriso`, `squashfs-tools`, `rsync`, `jq`, Python YAML support, and roughly 25 GB of temporary free space. `./setup` installs the usual dependencies.
- Enough time for extraction and repacking; a typical build can take 20–40 minutes.

### In the interface

1. Choose **ISO Creator** from the main menu.
2. Select a supported base ISO already stored in `download_dir`. Download it first through **Select Images**, or place it there yourself.
3. Select a recipe. `recipes/example.yml` demonstrates packages, sources, overlays, and hooks. `recipes/nikos.yml` creates the post-install NikOS Xubuntu image.
4. Confirm the destination and start the build. IsoForge passes the selected config and `download_dir` to the builder, then reports the resulting ISO filename and directory when it finishes.
5. Return to **Select Images**, choose the resulting ISO, and continue with USB preparation.

### From the command line

Validate a recipe without changing the system:

```bash
./forge --recipe recipes/example.yml --dry-run
```

Build it:

```bash
sudo ./forge --recipe recipes/example.yml
```

Use a particular already-downloaded base image when needed:

```bash
sudo ./forge --recipe recipes/example.yml --base-iso /path/to/base.iso
```

The output goes to `download_dir` unless `--output` specifies another directory. For recipe syntax and supported base-image layouts, see [BUILD.md](BUILD.md).

### NikOS image behavior

The NikOS recipe intentionally keeps the original Xubuntu installation process. It adds an **Install NikOS** launcher and profile, rather than installing NikOS packages and configuration into the live installer image.

1. Build and boot the NikOS Xubuntu ISO.
2. Complete the normal Xubuntu installation.
3. Boot the installed system.
4. Open **Install NikOS** from the application menu.
5. Choose the NikOS options in its own installer.

This keeps hardware-specific and user-specific choices on the installed machine, where they belong.

## Prepare the Ventoy USB drive

1. In the main menu, select **Prepare USB** after selecting one or more ISO files.
2. Review the target device. IsoForge lists removable USB drives by default. Do not select an internal disk.
3. Confirm the destructive warning. IsoForge asks for administrator authentication before accessing the device.
4. IsoForge uses the bundled dark **IsoForge** background by default. Select **Ventoy Background** before preparation to replace it:
   - **IsoForge** restores the bundled default background.
   - **NikOS** uses the bundled NikOS background.
   - **Custom** accepts PNG, JPG/JPEG, or TGA.
5. The image preview opens in `image-view` gallery mode. Use Left/Right to inspect nearby images and press `q` when satisfied. IsoForge then asks whether to use that image or preview another.
6. IsoForge starts Ventoy’s installer in the terminal. Read its prompt and answer its confirmation there; this preserves Ventoy’s own interactive safety check. IsoForge uses Ventoy’s default MBR-compatible layout rather than forcing GPT, which improves compatibility with older firmware.
7. After Ventoy completes, IsoForge waits for both Ventoy partitions and verifies the standard EFI fallback bootloader before it copies any ISO files. A failed verification stops the workflow and asks you to reinstall Ventoy rather than reporting a bootable USB that is incomplete.
8. IsoForge checks available space and copies the selected ISO files onto the Ventoy data partition, then unmounts any temporary mount it created.
9. Safely eject the USB drive. Boot it on the target computer and select an ISO from Ventoy’s menu.

Once Ventoy is installed, future use normally only requires copying more ISO files; reinstall Ventoy only when changing the drive layout or repairing the installation.

## Troubleshooting

- **No drive is shown:** reconnect the USB drive, wait for the operating system to detect it, then reopen drive selection. IsoForge intentionally does not hide removable drives solely because their capacity cannot currently be read.
- **Ventoy asks for confirmation:** this is expected in the terminal. Answer the Ventoy prompt there, then return to IsoForge.
- **A browser-only item did not download:** it requires vendor authentication. Complete it in the browser and select the downloaded image locally.
- **A build fails:** keep the reported work directory for inspection, verify the base image is supported, and run `--dry-run` first. See [BUILD.md](BUILD.md).
- **A background preview is unavailable:** install `image-view` or `chafa`; IsoForge can obtain an `image-view` binary automatically when a suitable release is available. The downloaded local binary is a cache and is ignored by Git.
