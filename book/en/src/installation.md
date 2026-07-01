# Installation

Scoot is distributed as a single self-contained binary. You can build it from
source or download a tagged release artifact.

## Requirements

- **Zig 0.16.0 or newer** to build from source. No other build dependency.
- A reachable **OpenAI-compatible** Responses API (`/v1/responses`) backend
  (local or remote).
- A POSIX shell (`/bin/sh`) for the `bash` tool. The structured tools
  (`file_read`, `grep`, `glob`, `http_request`, …) need no external commands.

Supported release targets: `linux-amd64`, `linux-arm64`, `linux-armv7`,
`macos-amd64`, `macos-arm64`.

## Install Latest Release

The install script detects your host OS/CPU, downloads the matching latest
release archive plus its `.sha256` file, verifies the checksum, and installs the
`scoot` binary.

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | sh
```

By default it installs to `/usr/local/bin` and uses `sudo` if needed. To install
without sudo, choose a user-writable directory that is on your `PATH`:

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | env SCOOT_INSTALL_DIR="$HOME/.local/bin" sh
```

Pin a specific release when reproducibility matters:

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | env SCOOT_INSTALL_VERSION=v0.2.0 sh
```

Supported installer environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SCOOT_INSTALL_DIR` | `/usr/local/bin` | Destination directory for the binary. |
| `SCOOT_INSTALL_VERSION` | `latest` | Release tag to install, with or without leading `v`. |
| `SCOOT_INSTALL_BINARY` | `scoot` | Installed binary name. |
| `SCOOT_INSTALL_REPO` | `jamiesun/scoot` | GitHub repository to download from. |
| `SCOOT_INSTALL_EDGE` | unset (opt-in) | Set to any non-empty value to also download and install the optional `scoot-edge` fleet companion as `$SCOOT_INSTALL_DIR/scoot-edge`. Never installed unless explicitly requested. |

## Install With Homebrew (macOS)

A Homebrew tap publishes formulae for macOS:

```sh
brew install jamiesun/tap/scoot
```

To also run compute-only Wasm tool packages (the `wasm_tool` action), install the
optional standalone host. Its formula depends on `scoot`, so this single command
installs both the agent and the host:

```sh
brew install jamiesun/tap/scoot-wasm
```

To also observe/dispatch to this Scoot from a management center, install the
optional standalone fleet companion. Its formula likewise depends on `scoot`,
since `scoot-edge` launches the agent as a subprocess:

```sh
brew install jamiesun/tap/scoot-edge
```

All three land on Homebrew's `bin` (on your `PATH`), so the default
`wasm_host = ["scoot-wasm", "wasi", "{component}"]` resolves `scoot-wasm` from
`PATH` with no extra configuration, and `scoot-edge` finds `scoot` on `PATH` by
default too (override with `--scoot-bin`). The core `scoot` formula never pulls
in either optional companion, keeping the default install minimal.

## Install via apt (Debian/Ubuntu)

The optional `scoot-edge` fleet companion is also published to a shared apt
repository, [`jamiesun/apt-tap`](https://github.com/jamiesun/apt-tap), for the
`amd64`, `arm64`, and `armhf` architectures:

```sh
curl -fsSL https://jamiesun.github.io/apt-tap/pubkey.gpg | sudo gpg --dearmor -o /usr/share/keyrings/jamiesun-apt-tap.gpg
echo "deb [signed-by=/usr/share/keyrings/jamiesun-apt-tap.gpg] https://jamiesun.github.io/apt-tap stable main" | sudo tee /etc/apt/sources.list.d/jamiesun-apt-tap.list
sudo apt update
sudo apt install scoot-edge
```

Only `scoot-edge` is packaged for apt today, not the core `scoot` binary —
install `scoot` with the script or Homebrew above first, then use apt for
`scoot-edge` if you prefer it over the install script's `SCOOT_INSTALL_EDGE=1`
flag or the Homebrew formula. `jamiesun/apt-tap` is a repository shared across
several unrelated tools, the same shared-tap model `homebrew-tap` already uses
above.

## Release Build Flavor

Prebuilt release archives ship a single flavor — Zig `ReleaseSafe`, which keeps
runtime safety checks and clear fail-fast diagnostics. If you need a smaller
binary for probes, edge devices, or minimal containers, compile from source with
`ReleaseSmall` (see [Build From Source](#build-from-source)). Each target also
publishes a separate `scoot-wasm-*` archive containing only the optional Wasm
compute-unit host, and a separate `scoot-edge-*` archive containing only the
optional fleet companion.

## Build From Source

```sh
git clone https://github.com/jamiesun/scoot.git
cd scoot

zig build              # produces ./zig-out/bin/scoot
zig build test         # run the full test suite
zig build run -- --version
```

For a production / embedded build, prefer a release optimization mode:

```sh
zig build -Doptimize=ReleaseSafe   # recommended: keeps safety checks
zig build -Doptimize=ReleaseFast   # fastest, fewer safety checks
zig build -Doptimize=ReleaseSmall  # smallest, fewer safety checks
```

Put the binary on your `PATH` if you like:

```sh
install -m 0755 zig-out/bin/scoot /usr/local/bin/scoot
```

## Install A Release Artifact

Each tagged release publishes a `scoot-<target>.tar.gz` per target plus a
separate `scoot-wasm-<target>.tar.gz` (the optional Wasm host), a separate
`scoot-edge-<target>.tar.gz` (the optional fleet companion), and `.sha256`
checksums for each.

```sh
# Pick the archive for your platform from the Releases page, then:
sha256sum -c scoot-<target>.tar.gz.sha256
tar -xzf scoot-<target>.tar.gz
install -m 0755 scoot/scoot /usr/local/bin/scoot
scoot --version
```

## Run With Docker

Tagged releases also publish multi-platform Linux container images for
`linux/amd64`, `linux/arm64`, and `linux/arm/v7`.

Use these tags:

| Tag form | Runtime base | Example |
| --- | --- | --- |
| `<version>`, `<major>.<minor>`, `<major>`, `latest` | minimal BusyBox/musl runtime | `ghcr.io/jamiesun/scoot:latest` |
| `<version>-alpine`, `<major>.<minor>-alpine`, `<major>-alpine`, `latest-alpine` | Alpine runtime with `apk` available | `ghcr.io/jamiesun/scoot:latest-alpine` |

The image entrypoint is `scoot`, so arguments after the image name are normal
Scoot CLI arguments. Always set `SCOOT_HOME` to an explicit mounted directory in
containers; this keeps `config.toml`, state, sessions, skills, and logs outside
the image filesystem.

```sh
mkdir -p scoot-data
cp config.example.toml scoot-data/config.toml

docker run --rm \
  -e SCOOT_HOME=/scoot \
  -e OPENAI_API_KEY \
  -v "$PWD/scoot-data:/scoot" \
  ghcr.io/jamiesun/scoot:latest \
  --version
```

If the backend runs on the Docker host, `127.0.0.1` inside the container is the
container itself. Set `[backend] base_url` in the mounted config to a
container-reachable address:

```toml
[backend]
base_url = "http://host.docker.internal:11434/v1"
model = "qwen2.5"
api_key_env = "OPENAI_API_KEY"
```

On Docker Desktop and OrbStack, `host.docker.internal` is normally available.
On Linux Docker Engine, either add this flag to `docker run`:

```sh
--add-host=host.docker.internal:host-gateway
```

or use the backend's real LAN/container-network address.

### One-Off Container Runs

Use a one-off container when a human, CI job, or script wants one immediate
goal:

```sh
docker run --rm \
  -e SCOOT_HOME=/scoot \
  -e OPENAI_API_KEY \
  -v "$PWD/scoot-data:/scoot" \
  ghcr.io/jamiesun/scoot:latest \
  -e "Inspect the mounted project and summarize obvious risks."
```

### Unattended Scheduled Containers

`config.example.toml` keeps scheduling disabled:

```toml
[schedule]
enabled = false
```

That default is intentional. `scoot schedule run` and `scoot daemon run` fail
closed until the mounted config explicitly opts into unattended work. For
containerized scheduled jobs, edit `scoot-data/config.toml`:

```toml
[schedule]
enabled = true
poll_ms = 1000

[[schedule.jobs]]
id = "disk-check"
goal = "Inspect disk usage and summarize anomalies"
every_sec = 300
mode = "readonly"
```

Use `schedule run --ticks 1` when an external scheduler starts a fresh container
for each poll, such as host cron, CI, systemd timer, or a Kubernetes CronJob:

```sh
docker run --rm \
  -e SCOOT_HOME=/scoot \
  -e OPENAI_API_KEY \
  -v "$PWD/scoot-data:/scoot" \
  ghcr.io/jamiesun/scoot:latest \
  schedule run --ticks 1
```

Because scheduler runtime memory resets when each container exits, an
`every_sec` job is due on the first tick of each new container. For strict
calendar timing under an external scheduler, prefer a `cron` trigger that
matches the external schedule.

Use `daemon run` when the container itself should stay up and own the polling
loop. It stays in the foreground, writes `state/daemon.json` and
`state/daemon.pid`, and handles SIGTERM/SIGINT for clean container shutdown:

```sh
docker run -d --name scoot \
  -e SCOOT_HOME=/scoot \
  -e OPENAI_API_KEY \
  -v "$PWD/scoot-data:/scoot" \
  ghcr.io/jamiesun/scoot:latest \
  daemon run
```

For `docker compose`:

```yaml
services:
  scoot:
    image: ghcr.io/jamiesun/scoot:latest
    command: ["daemon", "run"]
    restart: unless-stopped
    environment:
      SCOOT_HOME: /scoot
      OPENAI_API_KEY: ${OPENAI_API_KEY}
    volumes:
      - ./scoot-data:/scoot
```

Use a writable mount for `/scoot` when running `daemon run`, because Scoot needs
to write state, session, and audit files. If you want the config file itself to
be read-only, mount a directory with writable `state/`, `logs/`, and `skills/`
subdirectories and keep `config.toml` owned by your deployment tooling.

## First-Run Setup

Scoot works with built-in defaults, but you will usually point it at your own
backend and token.

**1. Create the runtime directory and config.** Scoot uses `~/.scoot` by
default; copy the sample config there:

```sh
mkdir -p ~/.scoot
cp config.example.toml ~/.scoot/config.toml
```

**2. Choose a backend.** Edit `[backend]` in `~/.scoot/config.toml`:

```toml
[backend]
# Local Ollama-compatible endpoint (the default):
base_url = "http://127.0.0.1:11434/v1"
model    = "qwen2.5"

# Or a hosted OpenAI-compatible endpoint:
# base_url = "https://api.openai.com/v1"
# model    = "gpt-4o-mini"
```

**3. Provide a token without writing it into config.** Scoot resolves secrets
from an environment variable first, then a `0600` token file, then a credential
command. The simplest path:

```sh
export OPENAI_API_KEY="sk-..."
```

Or use a private token file:

```sh
umask 077
printf '%s' "sk-..." > ~/.scoot/token   # must be mode 0600
```

See [Configuration → Secrets](configuration.md#secrets) for the full resolution
order and the credential-command option.

**4. Verify.** `config` prints the resolved runtime directory and backend (with
secrets redacted); `doctor` runs local health checks:

```sh
scoot config
scoot doctor
```

`doctor` reports the runtime directory, config source, backend reachability
prerequisites, the resolved secret **source** (never the value), skill
discovery, and the audit log path. Fix anything it flags before running a goal.

## Backend Examples

Scoot speaks only the OpenAI-compatible Responses API (`/v1/responses`).
Ollama ≥ 0.13.3 and vLLM support it statelessly; anything else must sit behind a
Responses-compatible gateway.

### Ollama (local, default)

```toml
[backend]
base_url = "http://127.0.0.1:11434/v1"
model    = "qwen2.5"
# No api key needed for a local Ollama; leave OPENAI_API_KEY unset.
```

### OpenAI

```toml
[backend]
base_url = "https://api.openai.com/v1"
model    = "gpt-4o-mini"
api_key_env = "OPENAI_API_KEY"
```

### Azure / other providers with extra fields

Use `[backend.extra_body]` to pass provider-specific top-level request fields
without recompiling. Never put secrets here.

```toml
[backend]
base_url = "https://your-resource.openai.azure.com/openai/v1"
model    = "gpt-4o"

[backend.extra_body]
reasoning_effort = "high"
service_tier     = "priority"
```

### Custom CA bundle (stripped / embedded systems)

If the system root certificates are missing (common on minimal Linux images),
point `ca_file` at a PEM bundle shipped with your firmware:

```toml
[backend]
ca_file = "/etc/ssl/certs/ca-certificates.crt"
```

## Next Steps

- [Configuration](configuration.md) — every config key, with defaults.
- [CLI Reference](cli.md) — every command and flag.
- [Built-in Tools](tools.md) — what the agent can actually do.
- [Troubleshooting & FAQ](troubleshooting.md) — if something doesn't work.
