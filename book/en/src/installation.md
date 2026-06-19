# Installation

Scoot is distributed as a single self-contained binary. You can build it from
source or download a tagged release artifact.

## Requirements

- **Zig 0.16.0 or newer** to build from source. No other build dependency.
- A reachable **OpenAI-compatible** chat/completions backend (local or remote).
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
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | env SCOOT_INSTALL_VERSION=v0.1.0 sh
```

Supported installer environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SCOOT_INSTALL_DIR` | `/usr/local/bin` | Destination directory for the binary. |
| `SCOOT_INSTALL_VERSION` | `latest` | Release tag to install, with or without leading `v`. |
| `SCOOT_INSTALL_BINARY` | `scoot` | Installed binary name. |
| `SCOOT_INSTALL_REPO` | `jamiesun/scoot` | GitHub repository to download from. |

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
zig build -Doptimize=ReleaseFast   # smallest/fastest, fewer safety checks
```

Put the binary on your `PATH` if you like:

```sh
install -m 0755 zig-out/bin/scoot /usr/local/bin/scoot
```

## Install A Release Artifact

Each tagged release publishes a `.tar.gz` per target plus a `.sha256` checksum.

```sh
# Pick the archive for your platform from the Releases page, then:
sha256sum -c scoot-<target>.tar.gz.sha256
tar -xzf scoot-<target>.tar.gz
install -m 0755 scoot/scoot /usr/local/bin/scoot
scoot --version
```

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

Scoot speaks only the OpenAI-compatible `chat/completions` protocol. Anything
that implements it works.

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
