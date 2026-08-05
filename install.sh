#!/usr/bin/env bash
# opencode-serve installer — Unix-agnostic (Linux / macOS).
#
#   Linux : installs a systemd --user service
#   macOS : installs a launchd LaunchAgent
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/dzianisv/opencode-serve/main/install.sh | bash
#
# Env overrides:
#   OPENCODE_SERVE_HOST   force bind host (default: auto tailnet IP)
#   OPENCODE_SERVE_PORT   listen port (default 4096)
#   OPENCODE_SERVE_RAW    raw base URL to fetch files when piped
#   PREFIX                install prefix for the wrapper (default ~/.local)
set -euo pipefail

REPO_RAW="${OPENCODE_SERVE_RAW:-https://raw.githubusercontent.com/dzianisv/opencode-serve/main}"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
WRAPPER="$BIN_DIR/opencode-serve"
PORT="${OPENCODE_SERVE_PORT:-4096}"
OS="$(uname -s)"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

# Emit a repo file to stdout — from the local checkout if present, else fetch it.
fetch() {
  local rel="$1"
  if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/$rel" ]; then
    cat "$SELF_DIR/$rel"
  else
    curl -fsSL "$REPO_RAW/$rel"
  fi
}

install_opencode() {
  if command -v opencode >/dev/null 2>&1; then
    say "opencode present: $(opencode --version 2>/dev/null || echo unknown)"
    return
  fi
  if command -v npm >/dev/null 2>&1; then
    say "installing @vibetechnologies/opencode via npm"
    npm install -g @vibetechnologies/opencode
  else
    say "installing opencode via upstream installer"
    curl -fsSL https://opencode.ai/install | bash
  fi
}

install_wrapper() {
  mkdir -p "$BIN_DIR"
  fetch "bin/opencode-serve" > "$WRAPPER"
  chmod +x "$WRAPPER"
  say "wrapper installed -> $WRAPPER"
}

install_linux() {
  local unit="$HOME/.config/systemd/user/opencode-serve.service"
  local log="$HOME/.cache/opencode-serve/serve.log"
  mkdir -p "$(dirname "$unit")" "$(dirname "$log")"

  # This installer owns opencode-serve.service. Clear stale drop-ins from prior
  # tooling so a previous WorkingDirectory/Environment override can't break us.
  if [ -d "$unit.d" ]; then
    warn "removing stale drop-ins in $unit.d"
    rm -rf "$unit.d"
  fi

  fetch "templates/opencode-serve.service" \
    | sed -e "s|__WRAPPER__|$WRAPPER|g" -e "s|__LOG__|$log|g" > "$unit"
  say "unit installed -> $unit"

  # Migrate away from a legacy hand-rolled opencode.service on the same port.
  if systemctl --user list-unit-files 2>/dev/null | grep -q '^opencode\.service'; then
    warn "disabling legacy opencode.service (avoids port $PORT conflict)"
    systemctl --user disable --now opencode.service 2>/dev/null || true
  fi

  systemctl --user daemon-reload
  systemctl --user enable --now opencode-serve.service
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  say "service started (systemd --user)"
}

install_macos() {
  local plist="$HOME/Library/LaunchAgents/com.opencode.serve.plist"
  local log="$HOME/Library/Logs/opencode-serve.log"
  mkdir -p "$(dirname "$plist")" "$(dirname "$log")"

  fetch "templates/com.opencode.serve.plist" \
    | sed -e "s|__WRAPPER__|$WRAPPER|g" -e "s|__LOG__|$log|g" > "$plist"
  say "plist installed -> $plist"

  launchctl unload "$plist" 2>/dev/null || true
  launchctl load -w "$plist"
  say "service started (launchd)"
}

main() {
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v openssl >/dev/null 2>&1 || die "openssl is required"
  command -v tailscale >/dev/null 2>&1 || warn "tailscale CLI not found — will fall back to interface scan / loopback"

  install_opencode
  install_wrapper

  case "$OS" in
    Linux)  install_linux ;;
    Darwin) install_macos ;;
    *)      die "unsupported OS: $OS (expected Linux or Darwin)" ;;
  esac

  local host
  host="$(OPENCODE_SERVE_HOST="${OPENCODE_SERVE_HOST:-}" bash -c '
    if [ -n "$OPENCODE_SERVE_HOST" ]; then echo "$OPENCODE_SERVE_HOST";
    elif command -v tailscale >/dev/null 2>&1; then tailscale ip -4 2>/dev/null | head -n1;
    fi')"
  echo
  say "OpenCode server is up:"
  printf '    URL:      http://%s:%s\n' "${host:-<tailnet-ip>}" "$PORT"
  printf '    Password: %s (OPENCODE_SERVER_PASSWORD)\n' "$HOME/.opencode-serve/env"
  printf '    Token:    %s\n' "$HOME/.opencode-serve/token"
  if [ "$OS" = "Linux" ]; then
    printf '    Logs:     journalctl --user -u opencode-serve -f  (or ~/.cache/opencode-serve/serve.log)\n'
  else
    printf '    Logs:     ~/Library/Logs/opencode-serve.log\n'
  fi
}

main "$@"
