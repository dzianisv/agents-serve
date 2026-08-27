# shellcheck shell=bash
# lib/tailnet.sh — shared helpers for agents-serve wrappers.
#
# Sourced by bin/opencode-serve, bin/paperclip-serve, bin/hermes-serve so all
# three wrappers share one implementation of tailnet IP resolution, secret
# generation, and logging instead of copy-pasting it three times.
#
# Not meant to be executed directly. Callers are expected to:
#   1. set LOG_TAG before calling log(), e.g. LOG_TAG="opencode-serve"
#   2. call resolve_host "$SERVICE_SPECIFIC_HOST_OVERRIDE" to get the bind host
#
# Bind host precedence: explicit per-service override (passed as $1) >
# AGENTS_SERVE_HOST (generic override) > `tailscale ip -4` > interface scan
# for a CGNAT/tailnet address (100.64.0.0/10) > 127.0.0.1 fallback.

log() { printf '[%s] %s\n' "${LOG_TAG:-agents-serve}" "$*" >&2; }

# scan_tailnet_ip — find a tailnet address (100.64.0.0/10) among local
# interfaces. Works on Linux (`ip`) and macOS (`ifconfig`); used only when the
# `tailscale` CLI itself is unavailable on PATH.
scan_tailnet_ip() {
  { if command -v ip >/dev/null 2>&1; then
      ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    else
      ifconfig 2>/dev/null | awk '/inet /{print $2}'
    fi
  } | awk -F. '$1==100 && $2>=64 && $2<=127 {print; exit}'
}

# resolve_host [override]
#   $1 (optional) — a per-service override value, e.g. "$OPENCODE_SERVE_HOST".
#   Takes precedence over everything, including AGENTS_SERVE_HOST, when set.
resolve_host() {
  local override="${1:-}"
  if [ -n "$override" ]; then
    printf '%s' "$override"
    return
  fi
  if [ -n "${AGENTS_SERVE_HOST:-}" ]; then
    printf '%s' "$AGENTS_SERVE_HOST"
    return
  fi
  if command -v tailscale >/dev/null 2>&1; then
    local ip
    ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    if [ -n "$ip" ]; then
      printf '%s' "$ip"
      return
    fi
  fi
  local scanned
  scanned="$(scan_tailnet_ip || true)"
  if [ -n "$scanned" ]; then
    printf '%s' "$scanned"
    return
  fi
  log "WARNING: no tailnet IP found; binding to 127.0.0.1"
  printf '127.0.0.1'
}

# rand_secret — URL-safe base64, 32 random bytes, no padding/newline.
rand_secret() { openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'; }
