# opencode-serve

One-line installer that runs [OpenCode](https://opencode.ai)'s headless server as
a background service, **auto-bound to your Tailscale tailnet IP** — no hardcoded
address. Unix-agnostic: **systemd** on Linux, **launchd** on macOS.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/dzianisv/opencode-serve/main/install.sh | bash
```

The installer:

1. Installs the `opencode` binary if missing (`@vibetechnologies/opencode` via
   npm, else the upstream installer).
2. Drops the `opencode-serve` wrapper into `~/.local/bin`.
3. Generates a random server password + token in `~/.opencode-serve/` (mode 600),
   only if they don't already exist.
4. Installs and starts the service:
   - **Linux** → `~/.config/systemd/user/opencode-serve.service` (enables linger
     so it survives logout).
   - **macOS** → `~/Library/LaunchAgents/com.opencode.serve.plist`.

## How tailnet binding works

The service's only command is the `opencode-serve` wrapper. On **every start** it
resolves the bind host in this order:

```
OPENCODE_SERVE_HOST  ->  tailscale ip -4  ->  scan iface for 100.64.0.0/10  ->  127.0.0.1
```

So the server always follows the node's current Tailscale IP. Restart to rebind:

```bash
# Linux
systemctl --user restart opencode-serve
# macOS
launchctl kickstart -k gui/$(id -u)/com.opencode.serve
```

## Configuration

| Env var                 | Default            | Purpose                          |
| ----------------------- | ------------------ | -------------------------------- |
| `OPENCODE_SERVE_HOST`   | auto (tailnet IP)  | Force a specific bind host       |
| `OPENCODE_SERVE_PORT`   | `4096`             | Listen port                      |
| `OPENCODE_SERVE_DIR`    | `~/.opencode-serve`| Secrets directory                |

Set persistently for the service:

```bash
# Linux
systemctl --user edit opencode-serve      # add [Service] Environment=OPENCODE_SERVE_PORT=5000
# macOS: add to the plist EnvironmentVariables dict, then reload
```

## Secrets

| File                       | Contents                                    |
| -------------------------- | ------------------------------------------- |
| `~/.opencode-serve/env`    | `OPENCODE_SERVER_PASSWORD=<base64url 32B>`   |
| `~/.opencode-serve/token`  | `<base64url 32B>`                            |

Generated once via `openssl rand -base64 32` (URL-safe). Delete them and restart
the service to rotate.

## Logs

```bash
# Linux
journalctl --user -u opencode-serve -f      # or ~/.cache/opencode-serve/serve.log
# macOS
tail -f ~/Library/Logs/opencode-serve.log
```

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/dzianisv/opencode-serve/main/uninstall.sh | bash
# add --purge to also delete ~/.opencode-serve secrets:
#   ... /uninstall.sh | bash -s -- --purge
```

## Layout

```
opencode-serve/
├── install.sh                       # entry point (Linux + macOS)
├── uninstall.sh
├── bin/opencode-serve               # wrapper: tailnet bind + secrets + exec opencode serve
└── templates/
    ├── opencode-serve.service       # systemd --user unit
    └── com.opencode.serve.plist     # launchd LaunchAgent
```
