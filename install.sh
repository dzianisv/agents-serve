#!/usr/bin/env bash
# agents-serve installer — Unix-agnostic (Linux / macOS).
#
# Installs one or more AI agent services as tailnet-bound background services:
#
#   Linux : systemd --user services
#   macOS : launchd LaunchAgents
#
# One-liner (installs ALL services: opencode, paperclip, hermes):
#   curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh | bash
#
# Selective install:
#   curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh | bash -s -- opencode
#   curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh | bash -s -- paperclip hermes
#
# Generic env overrides:
#   AGENTS_SERVE_HOST     force bind host for ALL services (default: auto tailnet IP)
#   AGENTS_SERVE_RAW      raw base URL to fetch files when piped
#   OPENCODE_SERVE_RAW    back-compat alias for AGENTS_SERVE_RAW
#   PREFIX                install prefix for wrappers/lib (default ~/.local)
# Per-service overrides (host/port/etc.): see README.md
set -euo pipefail

REPO_RAW="${AGENTS_SERVE_RAW:-${OPENCODE_SERVE_RAW:-https://raw.githubusercontent.com/dzianisv/agents-serve/main}}"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib/agents-serve"
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

install_lib() {
  mkdir -p "$LIB_DIR"
  fetch "lib/tailnet.sh" > "$LIB_DIR/tailnet.sh"
  say "shared lib installed -> $LIB_DIR/tailnet.sh"
}

# Preview the host a wrapper will bind to, using the same resolution logic the
# wrapper itself will run at start time (without side effects).
resolved_host_preview() {
  local override="$1"
  ( . "$LIB_DIR/tailnet.sh"; resolve_host "$override" ) 2>/dev/null
}

# ------------------------------------------------------------------ opencode --
install_opencode_upstream() {
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

install_opencode_wrapper() {
  mkdir -p "$BIN_DIR"
  fetch "bin/opencode-serve" > "$BIN_DIR/opencode-serve"
  chmod +x "$BIN_DIR/opencode-serve"
  fetch "bin/opencode-cli" > "$BIN_DIR/opencode-cli"
  chmod +x "$BIN_DIR/opencode-cli"
  fetch "bin/opencode-session-offload" > "$BIN_DIR/opencode-session-offload"
  chmod +x "$BIN_DIR/opencode-session-offload"
  say "opencode wrapper/CLI/offload installed -> $BIN_DIR"
}

install_opencode_linux() {
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
    | sed -e "s|__WRAPPER__|$BIN_DIR/opencode-serve|g" -e "s|__LOG__|$log|g" > "$unit"
  say "unit installed -> $unit"

  # Migrate away from a legacy hand-rolled opencode.service on the same port.
  if systemctl --user list-unit-files 2>/dev/null | grep -q '^opencode\.service'; then
    warn "disabling legacy opencode.service (avoids port conflict)"
    systemctl --user disable --now opencode.service 2>/dev/null || true
  fi

  systemctl --user daemon-reload
  systemctl --user reset-failed opencode-serve.service 2>/dev/null || true
  systemctl --user enable opencode-serve.service
  systemctl --user restart opencode-serve.service
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  say "opencode service started (systemd --user)"
}

install_opencode_macos() {
  local plist="$HOME/Library/LaunchAgents/com.agents-serve.opencode.plist"
  local legacy_plist="$HOME/Library/LaunchAgents/com.opencode.serve.plist"
  local log="$HOME/Library/Logs/opencode-serve.log"
  mkdir -p "$(dirname "$plist")" "$(dirname "$log")"

  # Migrate away from the old com.opencode.serve label so it can't double-bind
  # the port alongside the new com.agents-serve.opencode LaunchAgent.
  if [ -f "$legacy_plist" ]; then
    warn "migrating legacy com.opencode.serve LaunchAgent"
    launchctl unload "$legacy_plist" 2>/dev/null || true
    rm -f "$legacy_plist"
  fi

  fetch "templates/com.agents-serve.opencode.plist" \
    | sed -e "s|__WRAPPER__|$BIN_DIR/opencode-serve|g" -e "s|__LOG__|$log|g" > "$plist"
  say "plist installed -> $plist"

  launchctl unload "$plist" 2>/dev/null || true
  launchctl load -w "$plist"
  say "opencode service started (launchd)"
}

print_opencode_info() {
  local host port
  port="${OPENCODE_SERVE_PORT:-4096}"
  host="$(resolved_host_preview "${OPENCODE_SERVE_HOST:-}")"
  echo
  say "OpenCode server:"
  printf '    URL:      http://%s:%s\n' "${host:-<tailnet-ip>}" "$port"
  printf '    Password: %s (OPENCODE_SERVER_PASSWORD)\n' "$HOME/.opencode-serve/env"
  printf '    Token:    %s\n' "$HOME/.opencode-serve/token"
  if [ "$OS" = "Linux" ]; then
    printf '    Logs:     journalctl --user -u opencode-serve -f  (or ~/.cache/opencode-serve/serve.log)\n'
  else
    printf '    Logs:     ~/Library/Logs/opencode-serve.log\n'
  fi
}

install_opencode() {
  say "== opencode =="
  install_opencode_upstream
  install_opencode_wrapper
  case "$OS" in
    Linux)  install_opencode_linux ;;
    Darwin) install_opencode_macos ;;
  esac
  print_opencode_info
}

# ----------------------------------------------------------------- paperclip --
install_paperclip_upstream() {
  if command -v paperclipai >/dev/null 2>&1 || [ -x "$HOME/.local/bin/paperclipai" ]; then
    say "paperclipai present"
    return
  fi
  say "installing paperclipai via upstream installer"
  curl -fsSL https://paperclip.ing/install.sh | bash -s -- --no-prompt --no-onboard
}

install_paperclip_wrapper() {
  mkdir -p "$BIN_DIR"
  fetch "bin/paperclip-serve" > "$BIN_DIR/paperclip-serve"
  chmod +x "$BIN_DIR/paperclip-serve"
  say "paperclip wrapper installed -> $BIN_DIR/paperclip-serve"
}

install_paperclip_linux() {
  local unit="$HOME/.config/systemd/user/paperclip-serve.service"
  local log="$HOME/.cache/paperclip-serve/serve.log"
  mkdir -p "$(dirname "$unit")" "$(dirname "$log")"

  fetch "templates/paperclip-serve.service" \
    | sed -e "s|__WRAPPER__|$BIN_DIR/paperclip-serve|g" -e "s|__LOG__|$log|g" > "$unit"
  say "unit installed -> $unit"

  systemctl --user daemon-reload
  systemctl --user reset-failed paperclip-serve.service 2>/dev/null || true
  systemctl --user enable paperclip-serve.service
  systemctl --user restart paperclip-serve.service
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  say "paperclip service started (systemd --user)"
}

install_paperclip_macos() {
  local plist="$HOME/Library/LaunchAgents/com.agents-serve.paperclip.plist"
  local legacy_plist="$HOME/Library/LaunchAgents/ing.paperclip.paperclipai.plist"
  local log="$HOME/Library/Logs/paperclip-serve.log"
  mkdir -p "$(dirname "$plist")" "$(dirname "$log")"

  # A pre-existing upstream install may already run its own LaunchAgent on the
  # same port. Don't clobber it silently: warn and unload it (but don't delete
  # the file — it isn't ours to remove) before loading our managed one.
  if [ -f "$legacy_plist" ]; then
    warn "found pre-existing ing.paperclip.paperclipai LaunchAgent — unloading it so it doesn't fight for the port (remove $legacy_plist yourself to stop it reloading at next login)"
    launchctl unload "$legacy_plist" 2>/dev/null || true
  fi

  fetch "templates/com.agents-serve.paperclip.plist" \
    | sed -e "s|__WRAPPER__|$BIN_DIR/paperclip-serve|g" -e "s|__LOG__|$log|g" > "$plist"
  say "plist installed -> $plist"

  launchctl unload "$plist" 2>/dev/null || true
  launchctl load -w "$plist"
  say "paperclip service started (launchd)"
}

print_paperclip_info() {
  local host port
  port="${PAPERCLIP_SERVE_PORT:-3100}"
  host="$(resolved_host_preview "${PAPERCLIP_SERVE_HOST:-}")"
  echo
  say "Paperclip server:"
  printf '    URL:  http://%s:%s\n' "${host:-<tailnet-ip>}" "$port"
  if [ "$OS" = "Linux" ]; then
    printf '    Logs: journalctl --user -u paperclip-serve -f  (or ~/.cache/paperclip-serve/serve.log)\n'
  else
    printf '    Logs: ~/Library/Logs/paperclip-serve.log\n'
  fi
}

install_paperclip() {
  say "== paperclip =="
  install_paperclip_upstream
  install_paperclip_wrapper
  case "$OS" in
    Linux)  install_paperclip_linux ;;
    Darwin) install_paperclip_macos ;;
  esac
  print_paperclip_info
}

# -------------------------------------------------------------------- hermes --
install_hermes_upstream() {
  if command -v hermes >/dev/null 2>&1 || [ -x "$HOME/.local/bin/hermes" ]; then
    say "hermes present"
    return
  fi
  say "installing hermes-agent via upstream installer"
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
}

install_hermes_wrapper() {
  mkdir -p "$BIN_DIR"
  fetch "bin/hermes-serve" > "$BIN_DIR/hermes-serve"
  chmod +x "$BIN_DIR/hermes-serve"
  say "hermes wrapper installed -> $BIN_DIR/hermes-serve"
}

install_hermes_linux() {
  local unit="$HOME/.config/systemd/user/hermes-serve.service"
  local log="$HOME/.cache/hermes-serve/serve.log"
  mkdir -p "$(dirname "$unit")" "$(dirname "$log")"

  fetch "templates/hermes-serve.service" \
    | sed -e "s|__WRAPPER__|$BIN_DIR/hermes-serve|g" -e "s|__LOG__|$log|g" > "$unit"
  say "unit installed -> $unit"

  systemctl --user daemon-reload
  systemctl --user reset-failed hermes-serve.service 2>/dev/null || true
  systemctl --user enable hermes-serve.service
  systemctl --user restart hermes-serve.service
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  say "hermes service started (systemd --user)"
}

install_hermes_macos() {
  local plist="$HOME/Library/LaunchAgents/com.agents-serve.hermes.plist"
  local log="$HOME/Library/Logs/hermes-serve.log"
  mkdir -p "$(dirname "$plist")" "$(dirname "$log")"

  fetch "templates/com.agents-serve.hermes.plist" \
    | sed -e "s|__WRAPPER__|$BIN_DIR/hermes-serve|g" -e "s|__LOG__|$log|g" > "$plist"
  say "plist installed -> $plist"

  launchctl unload "$plist" 2>/dev/null || true
  launchctl load -w "$plist"
  say "hermes service started (launchd)"
}

print_hermes_info() {
  local host port
  port="${HERMES_SERVE_PORT:-9119}"
  host="$(resolved_host_preview "${HERMES_SERVE_HOST:-}")"
  echo
  say "Hermes server:"
  printf '    URL:  http://%s:%s\n' "${host:-<tailnet-ip>}" "$port"
  if [ "$OS" = "Linux" ]; then
    printf '    Logs: journalctl --user -u hermes-serve -f  (or ~/.cache/hermes-serve/serve.log)\n'
  else
    printf '    Logs: ~/Library/Logs/hermes-serve.log\n'
  fi
  warn "hermes: binding to a non-loopback host requires auth to be configured (password or OAuth) — run 'hermes dashboard register' if you haven't. --insecure is a deprecated no-op."
}

install_hermes() {
  say "== hermes =="
  install_hermes_upstream
  install_hermes_wrapper
  case "$OS" in
    Linux)  install_hermes_linux ;;
    Darwin) install_hermes_macos ;;
  esac
  print_hermes_info
}

# ----------------------------------------------------------------- dispatch --
# Expand "all"/no-args into the canonical service list, de-duplicated, or die
# on an unknown name. Prints one service name per line.
expand_services() {
  if [ "$#" -eq 0 ]; then
    printf 'opencode\npaperclip\nhermes\n'
    return
  fi
  local name want_all=0
  for name in "$@"; do
    [ "$name" = "all" ] && want_all=1
  done
  if [ "$want_all" -eq 1 ]; then
    printf 'opencode\npaperclip\nhermes\n'
    return
  fi
  for name in "$@"; do
    case "$name" in
      opencode|paperclip|hermes) printf '%s\n' "$name" ;;
      *) die "unknown service '$name' — valid: opencode paperclip hermes all" ;;
    esac
  done
}

main() {
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v openssl >/dev/null 2>&1 || die "openssl is required"
  command -v tailscale >/dev/null 2>&1 || warn "tailscale CLI not found — will fall back to interface scan / loopback"

  case "$OS" in
    Linux|Darwin) ;;
    *) die "unsupported OS: $OS (expected Linux or Darwin)" ;;
  esac

  local services
  services="$(expand_services "$@")"

  install_lib

  local failed="" svc
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    # Run each service's installer in its own subshell with errexit enabled,
    # so a failure aborts *that* service immediately without killing the rest
    # of the run. The overall script still exits non-zero if anything failed.
    if ! ( set -euo pipefail; "install_$svc" ); then
      warn "failed to install $svc — continuing with remaining services"
      failed="$failed $svc"
    fi
  done <<EOF
$services
EOF

  if [ -n "$failed" ]; then
    die "one or more services failed to install:$failed"
  fi
}

main "$@"
