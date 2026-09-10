#!/usr/bin/env bash

isoforge_main_help() {
  cat <<'HELP'
Isoforge downloads Linux images, prepares Ventoy USB drives, and builds custom installable ISOs.

Usage:
  isoforge [OPTIONS]
  isoforge <command> [COMMAND_OPTIONS]
  isoforge help [command]

Commands:
  download      Download one or more ISOs from config.json.
  burn          Prepare a Ventoy drive and copy selected ISO files to it.
  build         Build a custom installable ISO from a recipe. The TUI also provides ISO Creator.
  setup         Install project dependencies.
  help          Show command help.

Options:
  --config PATH  Override config file path for the TUI flow.
  --version      Print version and exit.
  -h, --help     Show this help and exit.

Examples:
  isoforge --config ./config.json
  isoforge download
  sudo isoforge burn
  sudo isoforge build --recipe recipes/example.yml --dry-run
HELP
}

isoforge_download_help() {
  cat <<'HELP'
Download one or more ISOs from the configured distro catalog.

Usage:
  isoforge download [OPTIONS]
  download [OPTIONS]

Options:
  --config PATH  Override config file path.
  -h, --help     Show this help and exit.

Environment:
  ALLOW_INSECURE_HTTP_DOWNLOADS=1
                 Allow http:// download URLs from config.json. Disabled by default.

Config:
  download_dir   Directory where downloaded images are saved.
  distros        Direct { id, label, url } or authenticated { id, label, browser_url } selector entries.
HELP
}

isoforge_burn_help() {
  cat <<'HELP'
Prepare a Ventoy drive and copy selected ISO files to it.

Usage:
  isoforge burn [OPTIONS]
  burn [OPTIONS]

Options:
  --config PATH  Override config file path.
  -h, --help     Show this help and exit.

Config:
  download_dir          Directory scanned for .iso files.
  block_device_filter   Drive filter. Use "usb" for USB/removable devices, or "any".

Notes:
  Burn installs Ventoy and destroys data on the selected destination drive.
HELP
}

isoforge_build_help() {
  cat <<'HELP'
Build a custom installable ISO from a base image and a recipe.

Usage:
  isoforge build --recipe PATH [OPTIONS]
  forge --recipe PATH [OPTIONS]

Options:
  -r, --recipe PATH   Recipe to build. Required.
      --base-iso PATH Override the recipe base with a local ISO.
  -o, --output DIR    Where to write the ISO. Defaults to download_dir from config.json.
      --config PATH   Override config file path.
      --work-dir DIR  Scratch space for build. Defaults to /var/tmp/isoforge.
      --dry-run       Resolve and validate recipe, then stop. Needs no root.
      --smoke-test    Boot finished image under QEMU.
      --keep          Leave work directory in place for inspection.
      --version       Print version and exit.
  -h, --help          Show this help and exit.
HELP
}

isoforge_setup_help() {
  cat <<'HELP'
Install dependencies needed by Isoforge.

Usage:
  isoforge setup [PACKAGE...]
  setup [PACKAGE...]

Options:
  -h, --help     Show this help and exit.

Parameters:
  PACKAGE        Optional package names to install instead of default dependency set.

Default Dependencies:
  dialog curl jq wget util-linux coreutils rsync exfatprogs parted
  xorriso squashfs-tools python3-yaml xz-utils gzip bzip2
HELP
}

isoforge_show_help() {
  case "${1:-}" in
    ""|isoforge|main) isoforge_main_help ;;
    download) isoforge_download_help ;;
    burn) isoforge_burn_help ;;
    build|forge) isoforge_build_help ;;
    setup) isoforge_setup_help ;;
    *)
      printf 'Unknown help topic: %s\n\n' "$1" >&2
      isoforge_main_help
      return 2
      ;;
  esac
}

isoforge_parse_config_only_args() {
  local arg
  while (($#)); do
    arg="$1"
    case "$arg" in
      --config)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          printf 'Missing value for --config\n' >&2
          return 2
        fi
        CONFIG_FILE="$2"
        shift 2
        ;;
      -h|--help)
        return 1
        ;;
      *)
        printf 'Unknown argument: %s\n' "$arg" >&2
        return 2
        ;;
    esac
  done
}
