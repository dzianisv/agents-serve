#!/usr/bin/env bash
# opencode-serve uninstaller — removes the service on Linux/macOS.
# Secrets in ~/.opencode-serve are kept unless --purge is passed.
set -euo pipefail

OS="$(uname -s)"
PURGE="${1:-}"
WRAPPER="${PREFIX:-$HOME/.local}/bin/opencode-serve"
CLI="${PREFIX:-$HOME/.local}/bin/opencode-cli"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

case "$OS" in
  Linux)
    unit="$HOME/.config/systemd/user/opencode-serve.service"
    systemctl --user disable --now opencode-serve.service 2>/dev/null || true
    rm -f "$unit"
    systemctl --user daemon-reload 2>/dev/null || true
    say "removed systemd service"
    ;;
  Darwin)
    plist="$HOME/Library/LaunchAgents/com.opencode.serve.plist"
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    say "removed launchd agent"
    ;;
  *)
    printf 'unsupported OS: %s\n' "$OS" >&2; exit 1 ;;
esac

rm -f "$WRAPPER" && say "removed wrapper $WRAPPER"
rm -f "$CLI" && say "removed CLI $CLI"

if [ "$PURGE" = "--purge" ]; then
  rm -rf "$HOME/.opencode-serve"
  say "purged ~/.opencode-serve (secrets deleted)"
else
  say "kept secrets in ~/.opencode-serve (use --purge to delete)"
fi
