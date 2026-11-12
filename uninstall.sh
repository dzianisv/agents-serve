#!/usr/bin/env bash
# agents-serve uninstaller — removes services on Linux/macOS.
#
# Usage:
#   uninstall.sh                      # remove ALL services (keep secrets)
#   uninstall.sh opencode             # remove just one
#   uninstall.sh paperclip hermes     # remove a subset
#   uninstall.sh --purge              # remove all + delete opencode's
#                                      # generated secrets in ~/.opencode-serve
#   uninstall.sh opencode --purge     # remove one + purge its secrets
#
# hermes and openclaw are removed through their own service managers
# (`hermes gateway uninstall`, `openclaw gateway uninstall`); their app data
# lives outside this repo's control (e.g. ~/.hermes, ~/.openclaw) — --purge
# never touches it, only the opencode secrets this installer itself generates.
set -euo pipefail

OS="$(uname -s)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib/agents-serve"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

PURGE=0
SERVICE_ARGS=""
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    *) SERVICE_ARGS="$SERVICE_ARGS $arg" ;;
  esac
done

# Expand "all"/no-args into the canonical service list, or die on an unknown
# name. Prints one service name per line. Deliberately takes args unquoted
# via $SERVICE_ARGS at the call site (word-split on purpose).
expand_services() {
  if [ "$#" -eq 0 ]; then
    printf 'opencode\npaperclip\nhermes\nopenclaw\n'
    return
  fi
  local name want_all=0
  for name in "$@"; do
    [ "$name" = "all" ] && want_all=1
  done
  if [ "$want_all" -eq 1 ]; then
    printf 'opencode\npaperclip\nhermes\nopenclaw\n'
    return
  fi
  for name in "$@"; do
    case "$name" in
      opencode|paperclip|hermes|openclaw) printf '%s\n' "$name" ;;
      *) die "unknown service '$name' — valid: opencode paperclip hermes openclaw all" ;;
    esac
  done
}

uninstall_opencode() {
  case "$OS" in
    Linux)
      systemctl --user disable --now opencode-serve.service 2>/dev/null || true
      rm -f "$HOME/.config/systemd/user/opencode-serve.service"
      systemctl --user daemon-reload 2>/dev/null || true
      ;;
    Darwin)
      local plist="$HOME/Library/LaunchAgents/com.agents-serve.opencode.plist"
      local legacy_plist="$HOME/Library/LaunchAgents/com.opencode.serve.plist"
      launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"
      if [ -f "$legacy_plist" ]; then
        launchctl unload "$legacy_plist" 2>/dev/null || true
        rm -f "$legacy_plist"
      fi
      ;;
  esac
  rm -f "$BIN_DIR/opencode-serve" "$BIN_DIR/opencode-cli" "$BIN_DIR/opencode-session-offload"
  say "removed opencode service + wrapper"

  if [ "$PURGE" -eq 1 ]; then
    rm -rf "$HOME/.opencode-serve"
    say "purged ~/.opencode-serve (secrets deleted)"
  else
    say "kept secrets in ~/.opencode-serve (pass --purge to delete)"
  fi
}

uninstall_paperclip() {
  case "$OS" in
    Linux)
      systemctl --user disable --now paperclip-serve.service 2>/dev/null || true
      rm -f "$HOME/.config/systemd/user/paperclip-serve.service"
      systemctl --user daemon-reload 2>/dev/null || true
      ;;
    Darwin)
      local plist="$HOME/Library/LaunchAgents/com.agents-serve.paperclip.plist"
      launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"
      ;;
  esac
  rm -f "$BIN_DIR/paperclip-serve"
  say "removed paperclip service + wrapper"
  if [ "$PURGE" -eq 1 ]; then
    say "paperclip manages its own data in \$PAPERCLIP_HOME (default ~/.paperclip) — not touched by --purge"
  fi
}

uninstall_hermes() {
  # Hermes owns its unit: `hermes gateway uninstall` removes it. The
  # hermes-serve wrapper + unit this repo used to install are legacy — clear
  # them too so an old install cannot keep the port.
  if command -v hermes >/dev/null 2>&1; then
    hermes gateway uninstall 2>/dev/null || warn "hermes gateway uninstall failed — check 'hermes gateway status'"
  fi
  case "$OS" in
    Linux)
      systemctl --user disable --now hermes-serve.service 2>/dev/null || true
      rm -f "$HOME/.config/systemd/user/hermes-serve.service"
      systemctl --user daemon-reload 2>/dev/null || true
      ;;
    Darwin)
      local plist="$HOME/Library/LaunchAgents/com.agents-serve.hermes.plist"
      launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"
      ;;
  esac
  rm -f "$BIN_DIR/hermes-serve"
  say "removed hermes gateway service (native) + legacy wrapper"
  if [ "$PURGE" -eq 1 ]; then
    say "hermes manages its own data outside this repo's control — not touched by --purge"
  fi
}

uninstall_openclaw() {
  # OpenClaw owns its unit: `openclaw gateway uninstall` removes it.
  if command -v openclaw >/dev/null 2>&1; then
    openclaw gateway uninstall 2>/dev/null || warn "openclaw gateway uninstall failed — check 'openclaw gateway status'"
  else
    warn "openclaw CLI not found — nothing to uninstall natively"
  fi
  say "removed openclaw gateway service (native)"
  if [ "$PURGE" -eq 1 ]; then
    # Funnel is owned by the gateway process itself and is released on stop;
    # this only clears a route that survived a hard kill.
    if command -v tailscale >/dev/null 2>&1; then
      tailscale funnel --https=443 --set-path=/ off >/dev/null 2>&1 || true
    fi
    say "openclaw keeps its config + secrets in ~/.openclaw — not touched by --purge (remove OPENCLAW_GATEWAY_PASSWORD from ~/.openclaw/.env to revoke access)"
  fi
}

main() {
  case "$OS" in
    Linux|Darwin) ;;
    *) die "unsupported OS: $OS (expected Linux or Darwin)" ;;
  esac

  local services
  # shellcheck disable=SC2086 # intentional word-splitting of collected args
  services="$(expand_services $SERVICE_ARGS)"

  local failed="" svc
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    if ! ( set -euo pipefail; "uninstall_$svc" ); then
      warn "failed to fully uninstall $svc"
      failed="$failed $svc"
    fi
  done <<EOF
$services
EOF

  # Remove the shared lib once nothing installed by this repo remains. Only
  # opencode and paperclip use it — hermes and openclaw run their own native
  # services and never source lib/tailnet.sh.
  if [ ! -x "$BIN_DIR/opencode-serve" ] && [ ! -x "$BIN_DIR/paperclip-serve" ]; then
    rm -rf "$LIB_DIR"
  fi

  if [ -n "$failed" ]; then
    die "one or more services failed to uninstall cleanly:$failed"
  fi
}

main
