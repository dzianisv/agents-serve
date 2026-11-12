# agents-serve

```bash
curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh | bash
```

One-line installer that runs AI agent servers as background services.
`opencode` and `paperclip` are bound to your **Tailscale tailnet IP** (no
hardcoded address); `hermes` and `openclaw` are installed through their **own
native service managers**, because upstream already ships one — this repo does
not hand-roll a competing unit for them. Unix-agnostic: **systemd --user** on
Linux, **launchd** on macOS. Installs all four services by default; pass names
to install a subset.

## Services

| Service     | What it is                                   | Default port | Upstream install                                                                    | Service unit | Auth notes |
| ----------- | --------------------------------------------- | ------------ | ------------------------------------------------------------------------------------ | ------------ | ---------- |
| `opencode`  | [OpenCode](https://opencode.ai) headless server | `4096`       | `@opencode/cli` (mainstream v2) via npm, else `curl -fsSL https://opencode.ai/v2/install \| bash` | **this repo** (`opencode-serve.service`) — upstream has no service support | Server password + token, generated locally |
| `paperclip` | [Paperclip](https://paperclip.ing) AI agent server | `3100`     | `curl -fsSL https://paperclip.ing/install.sh \| bash -s -- --no-prompt --no-onboard`   | **this repo** (`paperclip-serve.service`) — upstream has no service support | Tailnet bind forces `authenticated`+`private` mode; JWT secret auto-generated locally |
| `hermes`    | [Hermes](https://github.com/NousResearch/hermes-agent) messaging gateway | — | `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \| bash` | **native** (`hermes gateway install`) | Hermes manages its own auth |
| `openclaw`  | [OpenClaw](https://openclaw.ai) gateway + web dashboard (Control UI) | `18789` | `curl -fsSL https://openclaw.ai/install.sh \| bash -s -- --no-onboard` | **native** (`openclaw gateway install`) | Password auth (`OPENCLAW_GATEWAY_PASSWORD`); required before any public Funnel |

`opencode` and `paperclip` are reachable at `http://<tailnet-ip>:<port>` once
the node is on your tailnet. `hermes` and `openclaw` follow whatever their own
service managers do — see [Native service managers](#native-service-managers-hermes--openclaw).

For the Hermes **browser dashboard** on a public HTTPS URL (loopback bind +
password auth + Tailscale Funnel), use the standalone installer in
[Hermes dashboard over Tailscale Funnel](#hermes-dashboard-over-tailscale-funnel).
It is not part of `install.sh`; its dashboard listener uses port `9119` by
default. Use `--port` if that port is already occupied.

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

# install openclaw only, and publish its dashboard publicly over HTTPS
OPENCLAW_SERVE_PUBLIC=1 \
  bash <(curl -fsSL https://raw.githubusercontent.com/dzianisv/agents-serve/main/install.sh) -s -- openclaw
```

Valid names: `opencode`, `paperclip`, `hermes`, `openclaw`, `all` (default when
no args are given). An unknown name aborts immediately with the valid list. Each
service is installed independently — if one fails (e.g. its upstream installer
is down), the others still proceed; the script reports a warning per failure and
exits non-zero at the end if anything failed.

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
2. **opencode / paperclip only:** drops the service's `bin/<name>-serve` wrapper
   into `~/.local/bin` (plus `opencode-cli` and `opencode-session-offload` for
   `opencode`) and installs the shared `lib/tailnet.sh` helper library to
   `~/.local/lib/agents-serve/tailnet.sh`.
3. Installs and (re)starts the service:
   - **opencode / paperclip** — this repo owns the unit:
     - **Linux** → `~/.config/systemd/user/<name>-serve.service` (enables linger
       so it survives logout).
     - **macOS** → `~/Library/LaunchAgents/com.agents-serve.<name>.plist`.
   - **hermes / openclaw** — delegates to the native service manager:
     - `hermes gateway install` (systemd --user / launchd)
     - `openclaw gateway install` (systemd --user / launchd)

## How tailnet binding works

`opencode-serve` and `paperclip-serve` are the single source of truth for their
own bind host, and share one resolution routine from `lib/tailnet.sh`. It's
resolved **at every start**, so the server always follows the node's current
Tailscale IP:

```
<service>_SERVE_HOST  ->  AGENTS_SERVE_HOST  ->  tailscale ip -4  ->  scan iface for 100.64.0.0/10  ->  127.0.0.1
```

Restart to rebind after the tailnet IP changes:

```bash
# Linux
systemctl --user restart opencode-serve      # or paperclip-serve
# macOS
launchctl kickstart -k gui/$(id -u)/com.agents-serve.opencode   # or .paperclip
```

`hermes` and `openclaw` do not use this helper: they own their bind settings
(`hermes gateway`, `gateway.bind` in `openclaw.json`) and their own units.

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

### Native service managers (hermes / openclaw)

Both agents already ship a service manager, so this installer never writes a
unit for them — a hand-written unit drifts from upstream (restart policy, stop
hooks, `ExecReload`) and leaves two owners for one process.

```bash
hermes gateway install        # systemd --user / launchd, owned by hermes
openclaw gateway install      # systemd --user / launchd, owned by openclaw
```

Consequences worth knowing:

- **Hermes dashboard is separate from its gateway.** Upstream does not provide
  a service for `hermes dashboard` or `hermes serve`; the default installer
  leaves it alone. The optional dashboard Funnel helper is documented
  separately and manages that distinct dashboard process.
- **OpenClaw's dashboard *is* the gateway.** The Control UI is served by the
  gateway process on the same port, so `openclaw gateway install` is all that
  is needed for a persistent dashboard.
- **OpenClaw config, not flags.** `openclaw gateway install` bakes no bind/auth
  flags into the unit; the gateway reads them from `~/.openclaw/openclaw.json`
  on every start. The installer sets:

  ```bash
  openclaw config set gateway.bind loopback        # OPENCLAW_SERVE_BIND overrides
  openclaw config set gateway.port 18789           # OPENCLAW_SERVE_PORT overrides
  openclaw config set gateway.auth.mode password
  ```

  and appends `OPENCLAW_GATEWAY_PASSWORD` to `~/.openclaw/.env` (mode 600) only
  when the key is missing — an existing password is never rotated. OpenClaw
  loads that file itself, so the native unit needs no `EnvironmentFile`.

### OpenClaw public dashboard (Tailscale Funnel)

Set `OPENCLAW_SERVE_PUBLIC=1` to enable OpenClaw's **managed** Funnel — it
claims `https://<host>.<tailnet>.ts.net` (HTTPS `:443`), publishes the origin
itself, and releases the route when the gateway stops.

OpenClaw refuses `gateway.tailscale.mode=funnel` unless password auth is
configured, which is exactly why the installer provisions the password first.

Two hard limits:

- **Funnel is always `:443`.** There is no port setting
  (`gateway.tailscale` exposes only `mode`). If another route already owns
  `:443`, the gateway will not start, so the installer detects that and leaves
  the Funnel mode off with a warning instead of breaking the gateway.
- **Funnel must be enabled for the tailnet** (admin console → DNS → HTTPS
  certificates + funnel node attribute).

If you need a second public dashboard on the same host, the second one has to
use a hand-managed route (`tailscale funnel --bg --https 8443 http://127.0.0.1:<port>`)
plus matching `gateway.publicOrigin` / `gateway.controlUi.allowedOrigins` —
OpenClaw's managed Funnel cannot share `:443`.

## Configuration

### Generic

| Env var             | Default             | Purpose                                            |
| -------------------- | -------------------- | --------------------------------------------------- |
| `AGENTS_SERVE_HOST`  | auto (tailnet IP)    | Force a bind host for opencode/paperclip (lowest-priority override, per-service vars win) |
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

### openclaw

| Env var                | Default     | Purpose                                                        |
| ---------------------- | ----------- | -------------------------------------------------------------- |
| `OPENCLAW_SERVE_PORT`  | `18789`     | Gateway port (written to `gateway.port`)                        |
| `OPENCLAW_SERVE_BIND`  | `loopback`  | `gateway.bind`: `loopback`, `tailnet`, `lan`, `auto`, `custom`  |
| `OPENCLAW_SERVE_PUBLIC`| `0`         | Set to `1` to enable OpenClaw's managed Funnel (public HTTPS `:443`) |
| `OPENCLAW_SERVE_NODE`  | auto        | Override Node executable pinned into the native service; auto-detects Node 24.16+ / 26.1+ |

### hermes

No env vars: the gateway is configured by Hermes itself (`hermes gateway`,
`~/.hermes/config.yaml`). This repo only runs `hermes gateway install`.

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
persist them locally (mode 600). Hermes and OpenClaw gateway authentication is
managed by their upstream CLIs. The optional dashboard Funnel helpers also
persist their access details locally, mode 600.

| File                          | Contents                                    |
| ------------------------------ | -------------------------------------------- |
| `~/.opencode-serve/env`        | `OPENCODE_SERVER_PASSWORD=<base64url 32B>`   |
| `~/.opencode-serve/token`      | `<base64url 32B>`                            |
| `~/.paperclip-serve/env`       | `PAPERCLIP_AGENT_JWT_SECRET=<base64url 32B>` |
| `~/.hermes/dashboard-funnel.env` | dashboard public URL + basic-auth password |
| `~/.openclaw/dashboard-funnel.env` | OpenClaw public URL + gateway password |
| `~/.openclaw/.env`             | `OPENCLAW_GATEWAY_PASSWORD=<generated once>` (OpenClaw's own file) |

Generated once via `openssl rand -base64 32` (URL-safe). Delete them and
restart the service to rotate. For OpenClaw, change the password in
`~/.openclaw/.env` and run `openclaw gateway restart`.

## Logs

| OS    | opencode                                                    | paperclip                                                  | hermes                          | openclaw                          |
| ----- | ------------------------------------------------------------ | ------------------------------------------------------------ | -------------------------------- | ---------------------------------- |
| Linux | `journalctl --user -u opencode-serve -f` (or `~/.cache/opencode-serve/serve.log`) | `journalctl --user -u paperclip-serve -f` (or `~/.cache/paperclip-serve/serve.log`) | `journalctl --user -u hermes-gateway -f` | `journalctl --user -u openclaw-gateway -f` |
| macOS | `tail -f ~/Library/Logs/opencode-serve.log`                  | `tail -f ~/Library/Logs/paperclip-serve.log`                 | `~/.hermes/logs/gateway.log`     | `openclaw gateway status` / `~/Library/Logs/openclaw-gateway.log` |

## Service management cheat-sheet

| Action        | opencode / paperclip (this repo)                | hermes / openclaw (native)     |
| -------------- | -------------------------------------------------- | ------------------------------ |
| Status         | `systemctl --user status opencode-serve`           | `hermes gateway status` / `openclaw gateway status` |
| Restart        | `systemctl --user restart opencode-serve`          | `hermes gateway restart` / `openclaw gateway restart` |
| Stop           | `systemctl --user stop opencode-serve`             | `hermes gateway stop` / `openclaw gateway stop` |
| Follow logs    | `journalctl --user -u opencode-serve -f`           | `journalctl --user -u hermes-gateway -f` / `-u openclaw-gateway` |

On macOS, opencode/paperclip use launchd
(`launchctl kickstart -k gui/$(id -u)/com.agents-serve.opencode`,
`launchctl unload ~/Library/LaunchAgents/com.agents-serve.opencode.plist`);
hermes/openclaw keep using the same CLI verbs above.

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
generates). `hermes` and `openclaw` are removed through their own service
managers (`hermes gateway uninstall`, `openclaw gateway uninstall`), and their
data (`~/.hermes`, `~/.openclaw`) is never touched.

## Layout

```
agents-serve/
├── install.sh                            # entry point (Linux + macOS), accepts service names
├── uninstall.sh                           # accepts the same service names
├── lib/tailnet.sh                         # shared tailnet-IP resolution, secrets, logging (opencode/paperclip)
├── bin/opencode-serve                     # opencode wrapper: tailnet bind + secrets + exec opencode serve
├── bin/opencode-cli                       # remote session lister + permission listener
├── bin/opencode-session-offload           # local session archive wrapper
├── bin/paperclip-serve                    # paperclip wrapper: tailnet bind + exec paperclipai run
├── bin/hermes-dashboard-funnel            # standalone: loopback dashboard + auth + Tailscale Funnel
├── bin/openclaw-dashboard-funnel          # standalone: OpenClaw Control UI + gateway password + Funnel
└── templates/                             # units only for services without native managers
    ├── opencode-serve.service             # systemd --user unit (opencode)
    ├── com.agents-serve.opencode.plist    # launchd LaunchAgent (opencode)
    ├── paperclip-serve.service            # systemd --user unit (paperclip)
    └── com.agents-serve.paperclip.plist   # launchd LaunchAgent (paperclip)
```

No Hermes gateway or OpenClaw wrapper/unit template exists on purpose: both
agents ship their own gateway service managers. The dashboard Funnel helpers
are separate tools; see their sections above for their behavior.
