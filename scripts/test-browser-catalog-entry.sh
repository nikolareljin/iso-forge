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
  for _ in {1..20}; do
    [[ -f "$browser_log" ]] && break
    /bin/sleep 0.05
  done
  [[ "$(cat "$browser_log")" == "https://example.invalid/installer" ]]

  jq -e '.distros[] | select(.id == "pfSense_Netgate_Installer") |
    (.browser_url == "https://shop.netgate.com/products/netgate-installer") and
    (has("url") | not)' config.json >/dev/null
)
