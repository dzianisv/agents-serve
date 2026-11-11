# agents-serve

```bash
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh | bash
```

One-line installer that runs AI agent servers as background services,
**auto-bound to your Tailscale tailnet IP** — no hardcoded address. Unix-agnostic:
**systemd --user** on Linux, **launchd** on macOS. Installs all three services by
default; pass names to install a subset.

## Services

| Service     | What it is                                   | Default port | Upstream install                                                                    | Auth notes |
| ----------- | --------------------------------------------- | ------------- | ------------------------------------------------------------------------------------ | ---------- |
| `opencode`  | [OpenCode](https://opencode.ai) headless server | `4096`        | `@opencode/cli` (mainstream v2) via npm, else `curl -fsSL https://opencode.ai/v2/install \| bash` | Server password + token, generated locally |
| `paperclip` | [Paperclip](https://paperclip.ing) AI agent server | `3100`        | `curl -fsSL https://paperclip.ing/install.sh \| bash -s -- --no-prompt --no-onboard`   | Tailnet bind forces `authenticated`+`private` mode; JWT secret auto-generated locally |
| `hermes`    | [Hermes](https://github.com/NousResearch/hermes-agent) AI agent server | `9119`        | `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \| bash` | **Requires auth configured** for non-loopback binds (see below) |

Each installed service is reachable at `http://<tailnet-ip>:<port>` once the
node is on your tailnet — no manual IP configuration needed.

For the Hermes **browser dashboard** on a public HTTPS URL (loopback bind +
password auth + Tailscale Funnel), use the standalone installer in
[Hermes dashboard over Tailscale Funnel](#hermes-dashboard-over-tailscale-funnel).
It is not part of `install.sh`, and it shares port `9119` with the `hermes`
service.

For the **OpenClaw Control UI** on a public HTTPS URL (loopback bind + gateway
password auth + Tailscale Funnel), use
[OpenClaw dashboard over Tailscale Funnel](#openclaw-dashboard-over-tailscale-funnel).
It is also standalone and can run alongside the Hermes dashboard on a different
Funnel HTTPS port.

## Install

```bash
# install ALL services
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh | bash

# install just one
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh | bash -s -- opencode

# install a subset
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh | bash -s -- paperclip hermes
```

Valid names: `opencode`, `paperclip`, `hermes`, `all` (default when no args are
given). An unknown name aborts immediately with the valid list. Each service is
installed independently — if one fails (e.g. its upstream installer is down),
the others still proceed; the script reports a warning per failure and exits
non-zero at the end if anything failed.

> **Fork migration:** older versions of this installer installed the
> `@vibetechnologies/opencode` fork. The installer now installs mainstream
> OpenCode v2 (`@opencode/cli`). If the fork is present as a global npm
> package it is uninstalled automatically first — it provides the same
> `opencode` binary and would otherwise shadow the mainstream install
> forever. A fork installed by other means (e.g. its own curl installer) is
> not detected: remove that `opencode` binary manually, then re-run.

The installer, per service:

1. Installs the upstream binary if missing (skipped if already on `PATH` / in
   its known install location).
2. Drops the service's `bin/<name>-serve` wrapper into `~/.local/bin` (plus
   `opencode-cli` and `opencode-session-offload` for `opencode`).
3. Installs the shared `lib/tailnet.sh` helper library to
   `~/.local/lib/agents-serve/tailnet.sh`.
4. Installs and (re)starts the service:
   - **Linux** → `~/.config/systemd/user/<name>-serve.service` (enables linger
     so it survives logout).
   - **macOS** → `~/Library/LaunchAgents/com.agents-serve.<name>.plist`.

## How tailnet binding works

Each wrapper (`opencode-serve`, `paperclip-serve`, `hermes-serve`) is the single
source of truth for its own bind host, and shares one resolution routine from
`lib/tailnet.sh`. It's resolved **at every start**, so the server always follows
the node's current Tailscale IP:

```
<service>_SERVE_HOST  ->  AGENTS_SERVE_HOST  ->  tailscale ip -4  ->  scan iface for 100.64.0.0/10  ->  127.0.0.1
```

Restart to rebind after the tailnet IP changes:

```bash
# Linux
systemctl --user restart opencode-serve      # or paperclip-serve / hermes-serve
# macOS
launchctl kickstart -k gui/$(id -u)/com.agents-serve.opencode   # or .paperclip / .hermes
```

### Why `paperclip-serve` resolves the IP itself

Paperclip's config supports `server.bind=tailnet`, but at server runtime it
resolves the tailnet address **only** from the `PAPERCLIP_TAILNET_BIND_HOST` env
var — its auto-detection helper shells out to a bare `tailscale` on `PATH`, and
that path isn't used when the server actually starts. Under launchd/systemd the
`PATH` is minimal, so `tailscale` isn't found and the server crash-loops with:

```
Paperclip server failed to start. server.bind=tailnet requires a detected
Tailscale address or PAPERCLIP_TAILNET_BIND_HOST
```

`paperclip-serve` works around this: it resolves the tailnet IP itself (same
logic as the other wrappers) and exports `PAPERCLIP_BIND=tailnet` +
`PAPERCLIP_TAILNET_BIND_HOST=<resolved ip>` before exec'ing. If no tailnet IP is
found, it leaves `PAPERCLIP_BIND`/`PAPERCLIP_TAILNET_BIND_HOST` unset so
paperclip falls back to its own default (loopback, `local_trusted`).

**Tailnet binding also forces `authenticated` + `private` deployment mode.**
Paperclip's env loader defaults `deploymentMode` to `local_trusted`, and
`local_trusted` always requires loopback binding — it silently *ignores*
`PAPERCLIP_BIND` (and `PAPERCLIP_BIND_HOST`/`HOST`) when set, so
`PAPERCLIP_BIND=tailnet` alone is a no-op and the server binds loopback while
looking like it started fine. `paperclip-serve` therefore also exports
`PAPERCLIP_DEPLOYMENT_MODE=authenticated` and
`PAPERCLIP_DEPLOYMENT_EXPOSURE=private` whenever it resolves a tailnet host
(this is the only mode/exposure combination that permits `bind=tailnet` —
`authenticated`+`public` rejects it outright). `authenticated` mode in turn
requires `PAPERCLIP_AGENT_JWT_SECRET`; the wrapper generates one once and
persists it to `~/.paperclip-serve/env` (mode 600), the same idiom
`opencode-serve` uses for its own secrets. An operator-supplied
`PAPERCLIP_AGENT_JWT_SECRET` always takes precedence over the generated one.

### Hermes non-loopback auth requirement

As of the June 2026 Hermes hardening, binding to any **non-loopback** host
requires an auth provider to be configured (password or OAuth) —
`--insecure` is a deprecated no-op. If you haven't configured auth yet, run
`hermes dashboard register` (or set up OAuth) *before* relying on the
tailnet-bound service, or `hermes serve` will refuse to start. The installer
prints this reminder after setting up the service.

## Configuration

### Generic

| Env var             | Default             | Purpose                                            |
| -------------------- | -------------------- | --------------------------------------------------- |
| `AGENTS_SERVE_HOST`  | auto (tailnet IP)    | Force a bind host for all services (lowest-priority override, per-service vars win) |
| `AGENTS_SERVE_RAW`   | this repo's `main`   | Raw base URL to fetch files when piped              |
| `OPENCODE_SERVE_RAW` | —                    | Back-compat alias for `AGENTS_SERVE_RAW`             |
| `PREFIX`             | `~/.local`           | Install prefix for wrappers + shared lib             |

### opencode

| Env var               | Default              | Purpose                             |
| ---------------------- | -------------------- | ------------------------------------ |
| `OPENCODE_SERVE_HOST`  | auto (tailnet IP)    | Force a specific bind host           |
| `OPENCODE_SERVE_PORT`  | `4096`               | Listen port                          |
| `OPENCODE_SERVE_DIR`   | `~/.opencode-serve`  | Secrets directory                    |
| `OPENCODE_PERMISSION`  | `{"*":"allow"}`      | Permission policy for headless mode  |
| `OPENCODE_SERVE_PUBLIC`| `0`                  | Set to `1` to expose publicly over HTTPS via Tailscale Funnel |
| `OPENCODE_SERVE_FUNNEL_PORT`| `443`           | HTTPS port of the public Funnel endpoint |

The wrapper configures OpenCode's supported permission policy so the headless
agent does not stop for approval prompts. This is equivalent to an auto-approve
mode; `opencode serve` does not support a `--autoso` flag. Set
`OPENCODE_PERMISSION` to a stricter JSON policy when needed.

## Public exposure (Tailscale Funnel)

By default `opencode-serve` binds to the node's tailnet address only. Set
`OPENCODE_SERVE_PUBLIC=1` in the installer environment to additionally expose
it publicly over HTTPS via Tailscale Funnel:

```bash
OPENCODE_SERVE_PUBLIC=1 OPENCODE_SERVE_FUNNEL_PORT=443 \
  bash <(curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh) -s -- opencode
```

The public URL is `https://<tailnet-host>.ts.net:<port>` (port defaults to
`443`, overridable with `OPENCODE_SERVE_FUNNEL_PORT`).

Funnel is disabled in the tailnet admin console by default; enable it once at
the link printed by the installer (or run `tailscale funnel`). If
`tailscale serve` already serves `ts.net:443`, pick another port, e.g.
`OPENCODE_SERVE_FUNNEL_PORT=8443`.

### Security

The exposed server runs with `OPENCODE_PERMISSION={"*":"allow"}` — anyone who
knows the basic-auth password (`opencode:<password in ~/.opencode-serve/env>`)
can execute code on this machine over HTTPS. Keep the URL private, rotate the
password by deleting `~/.opencode-serve/env` and restarting the service, or
front it with Cloudflare Access / an IP allowlist if you need a published
address.

### paperclip

| Env var                        | Default            | Purpose                                        |
| -------------------------------- | ------------------- | ------------------------------------------------ |
| `PAPERCLIP_SERVE_HOST`          | auto (tailnet IP)   | Force a specific bind host                       |
| `PAPERCLIP_SERVE_PORT`          | `3100`              | Listen port (maps to paperclip's own `PORT`)     |
| `PAPERCLIP_HOME`                | `~/.paperclip`      | Paperclip data directory                         |
| `PAPERCLIP_INSTANCE_ID`         | `default`           | Instance name passed to `paperclipai run --instance` |
| `PAPERCLIP_SERVE_DIR`           | `~/.paperclip-serve`| Secrets directory (auto-generated JWT secret)    |
| `PAPERCLIP_DEPLOYMENT_MODE`     | `authenticated`\*   | Deployment mode when tailnet-bound               |
| `PAPERCLIP_DEPLOYMENT_EXPOSURE` | `private`\*         | Deployment exposure when tailnet-bound           |
| `PAPERCLIP_AGENT_JWT_SECRET`    | auto-generated      | Auth secret; an operator-supplied value always wins |

\* Only set/defaulted when a tailnet host is resolved; left untouched on the
loopback fallback so paperclip keeps its own `local_trusted` default.

### hermes

| Env var              | Default            | Purpose                     |
| --------------------- | ------------------- | ----------------------------- |
| `HERMES_SERVE_HOST`  | auto (tailnet IP)   | Force a specific bind host    |
| `HERMES_SERVE_PORT`  | `9119`              | Listen port                   |

Set persistently for a service:

```bash
# Linux
systemctl --user edit opencode-serve      # add [Service] Environment=OPENCODE_SERVE_PORT=5000
# macOS: add to the plist's EnvironmentVariables dict, then reload
```

## Hermes dashboard over Tailscale Funnel

The `hermes` service above binds Hermes' server to the **tailnet** IP. If you
want the **browser dashboard** instead — loopback bind, password auth forced on,
and a public HTTPS URL via Tailscale Funnel — use the standalone installer:

```bash
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/bin/hermes-dashboard-funnel | bash
```

It is **Linux / systemd --user only** and:

1. installs `hermes-dashboard.service`, bound to `127.0.0.1:9119`;
2. sets `HERMES_DASHBOARD_PUBLIC_URL` to the Funnel hostname, which forces
   Hermes' auth gate on (the proxy connects from loopback, so without it the
   dashboard would be unauthenticated);
3. generates a basic-auth password and writes it with the public URL to
   `~/.hermes/dashboard-funnel.env` (mode `600`);
4. runs `tailscale funnel --bg --https=443 http://127.0.0.1:9119`;
5. prints the public URL, or the Tailscale admin link to enable Funnel.

Manage it with the same one-liner:

```bash
# status / login URL / funnel state
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/bin/hermes-dashboard-funnel | bash -s -- --status

# print the login credentials
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/bin/hermes-dashboard-funnel | bash -s -- --show-password

# rotate the generated password
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/bin/hermes-dashboard-funnel | bash -s -- --reset-password

# stop and remove the service + funnel mount
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/bin/hermes-dashboard-funnel | bash -s -- --remove
```

Prerequisites:

- Tailscale is up and MagicDNS + HTTPS certificates are enabled.
- Funnel is enabled once in the tailnet admin console. The installer prints the
  enable link when it isn't.
- The CLI needs a one-time operator grant to write Serve/Funnel config without
  sudo:
  ```bash
  sudo tailscale set --operator=$USER
  ```

> **Port conflict:** the dashboard service uses `127.0.0.1:9119`, the same
> default port as `hermes-serve.service`. Install only one of them, or pass
> `--port` to the dashboard installer.

> **Restarts:** Hermes can take up to a minute to boot on a cold dependency
> check, and Funnel returns `502` while the backend is down. Re-running the
> installer is idempotent: it leaves a healthy, unchanged service running.

## OpenClaw dashboard over Tailscale Funnel

The OpenClaw Gateway serves its Control UI (the dashboard) on
`127.0.0.1:18789`. To publish that dashboard on a public HTTPS URL, protected by
a generated gateway password, use the standalone installer:

```bash
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/bin/openclaw-dashboard-funnel | bash
```

It is **Linux / systemd --user only** and:

1. ensures `openclaw-gateway.service` exists and listens on `127.0.0.1:18789`;
2. switches `gateway.auth.mode` to `password` and stores the generated secret in
   `~/.openclaw/.env` as `OPENCLAW_GATEWAY_PASSWORD`;
3. sets `gateway.publicOrigin`, `gateway.trustedProxies` and
   `gateway.controlUi.allowedOrigins` so the Control UI accepts traffic from the
   Funnel proxy (which connects over loopback);
4. writes the public URL + credentials to `~/.openclaw/dashboard-funnel.env`
   (mode `600`);
5. runs `tailscale funnel --bg --https=<port> http://127.0.0.1:18789` and prints
   the public URL.

The installer picks the first free Funnel HTTPS port (`443`, `8443`, `10000`),
so it can run alongside a Hermes dashboard already using `443` without stealing
its route. Pass `--https-port` to force one.

Manage it with the same one-liner:

```bash
# status / public URL / funnel state
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/bin/openclaw-dashboard-funnel | bash -s -- --status

# print the login credentials
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/bin/openclaw-dashboard-funnel | bash -s -- --show-password

# rotate the generated password
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/bin/openclaw-dashboard-funnel | bash -s -- --reset-password

# stop the funnel mount and remove the local env file
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/bin/openclaw-dashboard-funnel | bash -s -- --remove
```

Prerequisites:

- Tailscale is up and MagicDNS + HTTPS certificates are enabled.
- Funnel is enabled once in the tailnet admin console. The installer prints the
  enable link when it isn't.
- The CLI needs a one-time operator grant to write Serve/Funnel config without
  sudo:
  ```bash
  sudo tailscale set --operator=$USER
  ```

> **Auth:** the Control UI has no username field. The installer prints
> `openclaw` as a display name; the actual login is the generated gateway
> password (enter it in **Gateway secret** on the login screen).

> **Security:** Funnel is public, and the Control UI is an admin surface (chat,
> config, exec approvals). The password is the only gate. Keep the URL private
> and rotate the password if it leaks.

## Secrets

`opencode-serve` and `paperclip-serve` each generate their own secrets once and
persist them locally (mode 600); `hermes-serve` manages its own auth outside
this repo's control. The Hermes dashboard installer generates a basic-auth
password and writes it to `~/.hermes/dashboard-funnel.env` (mode 600). The
OpenClaw dashboard installer generates a gateway password and writes it to
`~/.openclaw/dashboard-funnel.env` (mode 600), with the same value in
`~/.openclaw/.env` so the Gateway can resolve it at startup.

| File                          | Contents                                    |
| ------------------------------ | -------------------------------------------- |
| `~/.opencode-serve/env`        | `OPENCODE_SERVER_PASSWORD=<base64url 32B>`   |
| `~/.opencode-serve/token`      | `<base64url 32B>`                            |
| `~/.paperclip-serve/env`       | `PAPERCLIP_AGENT_JWT_SECRET=<base64url 32B>` |
| `~/.hermes/dashboard-funnel.env` | dashboard public URL + basic-auth password |
| `~/.openclaw/dashboard-funnel.env` | OpenClaw public URL + gateway password |
| `~/.openclaw/.env`             | `OPENCLAW_GATEWAY_PASSWORD=<generated>`     |

Generated once via `openssl rand -base64 32` (URL-safe). Delete them and
restart the service to rotate.

## Logs

| OS    | opencode                                                    | paperclip                                                  | hermes                                                  |
| ----- | ------------------------------------------------------------ | ------------------------------------------------------------ | ---------------------------------------------------------- |
| Linux | `journalctl --user -u opencode-serve -f` (or `~/.cache/opencode-serve/serve.log`) | `journalctl --user -u paperclip-serve -f` (or `~/.cache/paperclip-serve/serve.log`) | `journalctl --user -u hermes-serve -f` (or `~/.cache/hermes-serve/serve.log`) |
| macOS | `tail -f ~/Library/Logs/opencode-serve.log`                  | `tail -f ~/Library/Logs/paperclip-serve.log`                 | `tail -f ~/Library/Logs/hermes-serve.log`                  |

## Service management cheat-sheet

| Action        | Linux (systemd --user)                          | macOS (launchd)                                                        |
| -------------- | -------------------------------------------------- | -------------------------------------------------------------------------- |
| Status         | `systemctl --user status opencode-serve`           | `launchctl list \| grep com.agents-serve.opencode`                       |
| Restart        | `systemctl --user restart opencode-serve`          | `launchctl kickstart -k gui/$(id -u)/com.agents-serve.opencode`           |
| Stop           | `systemctl --user stop opencode-serve`             | `launchctl unload ~/Library/LaunchAgents/com.agents-serve.opencode.plist` |
| Follow logs    | `journalctl --user -u opencode-serve -f`           | `tail -f ~/Library/Logs/opencode-serve.log`                               |

Swap `opencode` for `paperclip` / `hermes` (unit names: `paperclip-serve`,
`hermes-serve`; labels: `com.agents-serve.paperclip`, `com.agents-serve.hermes`).

## Remote CLI (opencode)

List sessions on a running server:

```bash
opencode-cli --remote '******hostname:4096'
```

Keep listening for permission requests and approve them with OpenCode's
`always` response:

```bash
opencode-cli --remote '******hostname:4096' --autoapprove
```

The URL must include the server's HTTP basic-auth credentials. `--autoapprove`
is intentionally opt-in and keeps running until interrupted. Use HTTPS when
the connection leaves a trusted private network. The client requires `curl` and
`jq` on the client machine.

## Session offload (opencode)

> **Fork-only:** `session-offload` is not part of mainstream OpenCode — it
> only exists in builds that add it (e.g. the `@vibetechnologies/opencode`
> fork this installer previously installed). With a mainstream build the
> wrapper exits with a clear error; use `opencode session export` /
> `opencode session import` there instead.

Archive and remove sessions inactive for seven days. The command prints archive
bytes, database size, and reusable SQLite space:

```bash
OPENCODE_DISABLE_CHANNEL_DB=1 opencode-session-offload \
  --export /Volumes/archive/opencode/sessions \
  --older-than 7 \
  --delete
```

Add `--vacuum` only after stopping every OpenCode process using the database.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/uninstall.sh | bash                # all services
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/uninstall.sh | bash -s -- opencode  # just one
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/uninstall.sh | bash -s -- --purge   # all + delete opencode's secrets
```

`--purge` only deletes `~/.opencode-serve` (the secrets this installer itself
generates). It never touches paperclip's `$PAPERCLIP_HOME` or hermes' own data
— those are managed by their upstream tools, not by this repo.

## Layout

```
agents-serve/
├── install.sh                            # entry point (Linux + macOS), accepts service names
├── uninstall.sh                           # accepts the same service names
├── lib/tailnet.sh                         # shared tailnet-IP resolution, secrets, logging
├── bin/opencode-serve                     # opencode wrapper: tailnet bind + secrets + exec opencode serve
├── bin/opencode-cli                       # remote session lister + permission listener
├── bin/opencode-session-offload           # local session archive wrapper
├── bin/paperclip-serve                    # paperclip wrapper: tailnet bind + exec paperclipai run
├── bin/hermes-serve                       # hermes wrapper: tailnet bind + exec hermes serve
├── bin/hermes-dashboard-funnel            # standalone: loopback dashboard + auth + Tailscale Funnel
├── bin/openclaw-dashboard-funnel          # standalone: OpenClaw Control UI + gateway password + Funnel
└── templates/
    ├── opencode-serve.service             # systemd --user unit (opencode)
    ├── com.agents-serve.opencode.plist    # launchd LaunchAgent (opencode)
    ├── paperclip-serve.service            # systemd --user unit (paperclip)
    ├── com.agents-serve.paperclip.plist   # launchd LaunchAgent (paperclip)
    ├── hermes-serve.service               # systemd --user unit (hermes)
    └── com.agents-serve.hermes.plist      # launchd LaunchAgent (hermes)
```
