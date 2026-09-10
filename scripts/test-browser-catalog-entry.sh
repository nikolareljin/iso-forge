#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(
  cd "$ROOT_DIR"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  source ./inc/download-state.sh

  is_browser_url "https://example.invalid/installer"
  if is_browser_url "http://example.invalid/installer"; then
    echo "plain HTTP browser URLs must be rejected" >&2
    exit 1
  fi

  fakebin="$tmpdir/bin"
  browser_log="$tmpdir/browser-url"
  mkdir -p "$fakebin"
  cat >"$fakebin/xdg-open" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >"$BROWSER_LOG"
EOF
  chmod +x "$fakebin/xdg-open"

  old_path="$PATH"
  BROWSER_LOG="$browser_log" PATH="$fakebin:$PATH" open_browser_url "https://example.invalid/installer"
  PATH="$old_path"
  [[ "$(cat "$browser_log")" == "https://example.invalid/installer" ]]

  # A failing opener must not be reported as a successful browser handoff.
  cat >"$fakebin/xdg-open" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"$fakebin/gio" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == open ]]
printf '%s\n' "$2" >"$BROWSER_LOG"
EOF
  chmod +x "$fakebin/xdg-open" "$fakebin/gio"
  rm -f "$browser_log"
  BROWSER_LOG="$browser_log" PATH="$fakebin:$PATH" open_browser_url "https://example.invalid/fallback"
  [[ "$(cat "$browser_log")" == "https://example.invalid/fallback" ]]

  jq -e '.distros[] | select(.id == "Ubuntu_24_04_4_server_arm64") | .url == "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.4-live-server-arm64.iso"' config.json >/dev/null
  jq -e '.distros[] | select(.id == "Ubuntu_26_04_1_server_arm64") | .url == "https://cdimage.ubuntu.com/releases/26.04/release/ubuntu-26.04.1-live-server-arm64.iso"' config.json >/dev/null

  jq -e '.distros[] | select(.id == "pfSense_Netgate_Installer") |
    (.browser_url == "https://shop.netgate.com/products/netgate-installer") and
    (has("url") | not)' config.json >/dev/null
)
