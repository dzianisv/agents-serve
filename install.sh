#!/usr/bin/env bash
# agents-serve installer — Unix-agnostic (Linux / macOS).
#
# Installs one or more AI agent services as tailnet-bound background services:
#
#   Linux : systemd --user services
#   macOS : launchd LaunchAgents
#
# One-liner (installs ALL services: opencode, paperclip, hermes, openclaw):
#   curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh | bash
#
# Selective install:
#   curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh | bash -s -- opencode
#   curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh | bash -s -- paperclip hermes
#   curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh | bash -s -- openclaw
#
# Service units: this installer only writes a unit where upstream has none.
# opencode and paperclip have no native service support, so they get
# opencode-serve.service / paperclip-serve.service here. hermes and openclaw
# both ship their own service manager (`hermes gateway install`,
# `openclaw gateway install`) — this installer configures them and calls those,
# it never hand-rolls a competing unit.
#
# Generic env overrides:
#   AGENTS_SERVE_HOST     force bind host for opencode/paperclip (default: auto tailnet IP)
#   AGENTS_SERVE_RAW      raw base URL to fetch files when piped
#   OPENCODE_SERVE_RAW    back-compat alias for AGENTS_SERVE_RAW
#   PREFIX                install prefix for wrappers/lib (default ~/.local)
# Per-service overrides (host/port/etc.): see README.md
set -euo pipefail

# The native CLIs (openclaw, hermes, tailscale) usually live in ~/.local/bin or
# an npm prefix. A piped `curl | bash` inherits a minimal PATH, so widen it
# before any command lookup below.
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"

REPO_RAW="${AGENTS_SERVE_RAW:-${OPENCODE_SERVE_RAW:-https://raw.githubusercontent.com/dzianisv/agents-serve/main}}"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib/agents-serve"
OS="$(uname -s)"

# Only trust BASH_SOURCE for the checkout location. When the script is piped
# (curl | bash), BASH_SOURCE is empty and $0 is just "bash" — falling back to
# $0 would make SELF_DIR the caller's cwd, and fetch() could then silently
# pick up unrelated same-named files from that directory instead of the repo.
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SELF_DIR=""
fi

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

# Write a fetched file to its destination atomically: fetch into a temp file
# in the same directory and rename on success, so a failed download cannot
# truncate a previously working wrapper/lib that is already installed.
fetch_to() {
  local rel="$1" dest="$2" tmp
  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  if fetch "$rel" > "$tmp"; then
    mv "$tmp" "$dest"
  else
    rm -f "$tmp"
    return 1
  fi
}

install_lib() {
  mkdir -p "$LIB_DIR"
  fetch_to "lib/tailnet.sh" "$LIB_DIR/tailnet.sh"
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
  # Migrate off the Vibe Technologies fork when it was installed via npm:
  # it provides the same `opencode` binary, so the present-check below would
  # otherwise keep the fork forever and the mainstream install never happens.
  if command -v npm >/dev/null 2>&1 \
     && npm list -g --depth=0 2>/dev/null | grep -q '@vibetechnologies/opencode'; then
    say "removing @vibetechnologies/opencode fork — replaced by mainstream @opencode/cli"
    npm uninstall -g @vibetechnologies/opencode
  fi
  if command -v opencode >/dev/null 2>&1; then
    say "opencode present: $(opencode --version 2>/dev/null || echo unknown)"
    return
  fi
  if command -v npm >/dev/null 2>&1; then
    say "installing @opencode/cli (mainstream OpenCode v2) via npm"
    npm install -g @opencode/cli@latest
  else
    say "installing opencode via upstream v2 installer"
    curl -fsSL https://opencode.ai/v2/install | bash
  fi
}

install_opencode_wrapper() {
  mkdir -p "$BIN_DIR"
  fetch_to "bin/opencode-serve" "$BIN_DIR/opencode-serve"
  chmod +x "$BIN_DIR/opencode-serve"
  fetch_to "bin/opencode-cli" "$BIN_DIR/opencode-cli"
  chmod +x "$BIN_DIR/opencode-cli"
  fetch_to "bin/opencode-session-offload" "$BIN_DIR/opencode-session-offload"
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
  loginctl enable-linger "${USER:-$(id -un)}" >/dev/null 2>&1 || true
  say "opencode service started (systemd --user)"
  expose_opencode_publicly "$log"
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
  expose_opencode_publicly "$log"
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
  if [ "${OPENCODE_SERVE_PUBLIC:-0}" = "1" ]; then
    printf '    Public:   https://%s:%s\n' "${host:-<tailnet-ip>}" "${OPENCODE_SERVE_FUNNEL_PORT:-443}"
  fi
}

# ----------------------------------------------------------------- public --
# Expose an already-running opencode server publicly over HTTPS via Tailscale
# Funnel (https://<tailnet-host>:<port>). Opt-in only: private tailnet binds
# remain the default. Funnel must be enabled once in the tailnet admin console
# (the installer prints the link when it's missing). Binding targets the
# server's actual address — never the unauthenticated legacy loopback server.
expose_opencode_publicly() {
  [ "${OPENCODE_SERVE_PUBLIC:-0}" = "1" ] || return 0
  local log="$1"
  command -v tailscale >/dev/null 2>&1 || {
    warn "tailscale CLI not found — opencode stays tailnet-only"
    return 0
  }
  local port funnel_port host
  port="${OPENCODE_SERVE_PORT:-4096}"
  funnel_port="${OPENCODE_SERVE_FUNNEL_PORT:-443}"
  host="$(resolved_host_preview "${OPENCODE_SERVE_HOST:-}" 2>/dev/null || true)"
  [ -n "$host" ] || host=127.0.0.1
  say "exposing opencode publicly via Tailscale Funnel at https://${host}:${funnel_port} -> ${host}:${port}"
  if ! tailscale funnel --bg --https "$funnel_port" "http://$host:$port" >> "$log" 2>&1; then
    warn "tailscale funnel failed — enable funnel in your tailnet admin console, or set OPENCODE_SERVE_FUNNEL_PORT if port $funnel_port is already in use"
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
  fetch_to "bin/paperclip-serve" "$BIN_DIR/paperclip-serve"
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
  loginctl enable-linger "${USER:-$(id -un)}" >/dev/null 2>&1 || true
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
  # Legacy: pre-native installs shipped a hermes-serve wrapper + hand-written
  # unit. Hermes has owned its own service for a while (`hermes gateway
  # install`), so the wrapper is gone. Clean up any leftover from an old
  # install so it cannot keep binding the port next to the native unit.
  rm -f "$BIN_DIR/hermes-serve"
  if [ "$OS" = "Linux" ] && [ -f "$HOME/.config/systemd/user/hermes-serve.service" ]; then
    warn "removing legacy hermes-serve.service (superseded by hermes gateway install)"
    systemctl --user disable --now hermes-serve.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/hermes-serve.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  if [ "$OS" = "Darwin" ] && [ -f "$HOME/Library/LaunchAgents/com.agents-serve.hermes.plist" ]; then
    warn "removing legacy com.agents-serve.hermes LaunchAgent (superseded by hermes gateway install)"
    launchctl unload "$HOME/Library/LaunchAgents/com.agents-serve.hermes.plist" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.agents-serve.hermes.plist"
  fi
}

install_hermes_service() {
  # `hermes gateway install` is Hermes' own service manager: systemd --user on
  # Linux, launchd on macOS. It knows its restart policy, stop hooks and
  # ExecReload; a hand-written unit only drifts from that.
  #
  # Note: Hermes does NOT provide a service for `hermes dashboard` (upstream
  # docs: "Hermes never installs a service for `hermes dashboard` or
  # `hermes serve`"), so this installer deliberately leaves the dashboard
  # alone rather than inventing a unit for it.
  if ! command -v hermes >/dev/null 2>&1; then
    warn "hermes CLI not found — skipping gateway service install"
    return 1
  fi
  if hermes gateway install; then
    say "hermes gateway installed (native service)"
  else
    warn "hermes gateway install failed — run 'hermes doctor' (or 'hermes pm repair') and retry"
    return 1
  fi
}

print_hermes_info() {
  echo
  say "Hermes gateway (native service):"
  printf '    Status: hermes gateway status\n'
  if [ "$OS" = "Linux" ]; then
    printf '    Logs:   journalctl --user -u hermes-gateway -f\n'
  else
    printf '    Logs:   ~/.hermes/logs/gateway.log\n'
  fi
}

install_hermes() {
  say "== hermes =="
  install_hermes_upstream
  install_hermes_wrapper
  install_hermes_service
  print_hermes_info
}

# ------------------------------------------------------------------ openclaw --
# OpenClaw serves its dashboard (the Control UI) from the gateway itself, and
# ships its own service manager, so there is nothing to wrap: configure the
# gateway in openclaw.json, then let `openclaw gateway install` own the unit.
install_openclaw_upstream() {
  if command -v openclaw >/dev/null 2>&1 || [ -x "$HOME/.local/bin/openclaw" ]; then
    say "openclaw present"
    return
  fi
  say "installing openclaw via upstream installer"
  curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
}

find_openclaw() {
  if command -v openclaw >/dev/null 2>&1; then command -v openclaw; return; fi
  local p
  for p in "$HOME/.local/bin/openclaw" "$HOME/.openclaw/bin/openclaw" \
           /usr/local/bin/openclaw /opt/homebrew/bin/openclaw; do
    if [ -x "$p" ]; then printf '%s' "$p"; return; fi
  done
  return 1
}

# Never rotate a password that already works: only append when the key is
# absent. OpenClaw loads ~/.openclaw/.env itself, so the native unit needs no
# EnvironmentFile and no wrapper to see it.
ensure_openclaw_password() {
  local env_file="$HOME/.openclaw/.env"
  mkdir -p "$(dirname "$env_file")"
  if [ -f "$env_file" ] && grep -q '^OPENCLAW_GATEWAY_PASSWORD=' "$env_file" 2>/dev/null; then
    say "openclaw gateway password already set in $env_file"
    return 0
  fi
  local pw
  pw="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
  ( umask 177; printf 'OPENCLAW_GATEWAY_PASSWORD=%s\n' "$pw" >> "$env_file" )
  say "generated OPENCLAW_GATEWAY_PASSWORD in $env_file"
}

# Print the proxy target currently published on HTTPS :443, if any. OpenClaw's
# managed Funnel always claims :443 and refuses to start when another route
# owns it, so the caller needs to know before flipping the mode on.
funnel_443_target() {
  tailscale funnel status 2>/dev/null | awk '
    /^https:\/\/[^:]+ \(Funnel on\)$/ { block = 1; next }
    /^https:\/\// { block = 0 }
    block && /proxy/ { print $NF; exit }
  '
}

install_openclaw_funnel() {
  local oc="$1" port="$2"
  if [ "${OPENCLAW_SERVE_PUBLIC:-0}" != "1" ]; then
    "$oc" config set gateway.tailscale.mode off >/dev/null 2>&1 || true
    return 0
  fi
  if ! command -v tailscale >/dev/null 2>&1; then
    warn "tailscale CLI not found — openclaw stays loopback-only"
    return 0
  fi
  local target
  target="$(funnel_443_target || true)"
  if [ -n "$target" ] && [ "$target" != "http://127.0.0.1:$port" ]; then
    warn "HTTPS :443 is already published to $target — not enabling openclaw's managed Funnel (it would fail to start). Free :443 and re-run with OPENCLAW_SERVE_PUBLIC=1."
    "$oc" config set gateway.tailscale.mode off >/dev/null 2>&1 || true
    return 0
  fi
  "$oc" config set gateway.tailscale.mode funnel >/dev/null
  say "openclaw managed Funnel enabled (public HTTPS on :443, password auth required)"
}

install_openclaw() {
  say "== openclaw =="
  install_openclaw_upstream
  local oc port bind
  if ! oc="$(find_openclaw)"; then
    warn "openclaw binary not found after install"
    return 1
  fi
  port="${OPENCLAW_SERVE_PORT:-18789}"
  bind="${OPENCLAW_SERVE_BIND:-loopback}"

  ensure_openclaw_password

  # Config, not flags: `openclaw gateway install` bakes no bind/auth flags into
  # the unit — the gateway reads all of this from openclaw.json on every start.
  "$oc" config set gateway.bind "$bind" >/dev/null
  "$oc" config set gateway.port "$port" >/dev/null
  "$oc" config set gateway.auth.mode password >/dev/null

  install_openclaw_funnel "$oc" "$port"

  say "installing the gateway as OpenClaw's own service (openclaw gateway install)"
  if ! "$oc" gateway install --port "$port" --force; then
    warn "openclaw gateway install failed — check 'openclaw doctor'"
    return 1
  fi
  say "openclaw gateway installed (native service)"
  print_openclaw_info "$oc" "$port" "$bind"
}

print_openclaw_info() {
  local oc="$1" port="$2" bind="$3" origin=""
  echo
  say "OpenClaw gateway + dashboard (native service):"
  if [ "${OPENCLAW_SERVE_PUBLIC:-0}" = "1" ]; then
    origin="$("$oc" config get gateway.publicOrigin 2>/dev/null | tr -d '"' || true)"
    case "$origin" in
      https://*) : ;;
      *) origin="https://$(tailscale status --json 2>/dev/null \
           | grep -o '"DNSName": *"[^"]*"' | head -n1 | cut -d'"' -f4 | sed 's/\.$//')" ;;
    esac
  fi
  if [ -n "$origin" ] && [ "$origin" != "https://" ]; then
    printf '    URL:      %s (managed Funnel, public HTTPS)\n' "$origin"
  else
    printf '    URL:      http://127.0.0.1:%s (bind=%s)\n' "$port" "$bind"
  fi
  printf '    Password: OPENCLAW_GATEWAY_PASSWORD in %s/.openclaw/.env\n' "$HOME"
  printf '    Status:   openclaw gateway status\n'
  if [ "$OS" = "Linux" ]; then
    printf '    Logs:     journalctl --user -u openclaw-gateway -f\n'
  else
    printf '    Logs:     ~/Library/Logs/openclaw-gateway.log\n'
  fi
}

# ----------------------------------------------------------------- dispatch --
# Expand "all"/no-args into the canonical service list, de-duplicated, or die
# on an unknown name. Prints one service name per line.
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
