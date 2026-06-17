# Configuration

Scoot loads config from the runtime directory:

1. `config.toml`
2. `config.json`
3. built-in defaults

The recommended starting point is:

- [`config.example.toml`](../../../config.example.toml)

## Main Sections

- `[backend]`: OpenAI-compatible endpoint, model, API key source, CA bundle, extra request fields.
- `[agent]`: turn limit, default mode, and context budget (`context_budget_bytes`, 0 = off).
- `[tools]`: timeout, execution policy, and opt-in guarded-mode hardening (`confine_writes`, `block_internal_http`).
- `[skills]`: skill discovery.
- `[audit]`: audit log behavior.
- `[schedule]`: scheduled jobs.

## Policy Modes

- `guarded`: interactive tripwire mode.
- `readonly`: fail-closed mode for read-only operation.
- `unrestricted`: no policy limit, still audited.

Scheduled jobs correct `guarded` to `readonly`.

## Guarded-Mode Hardening (opt-in)

Both default `false` and apply only in `guarded` mode (`readonly` already fail-closes writes and network):

- `confine_writes`: keep `file_write` / `file_edit` inside the project root; reject absolute paths, `..` escapes, and `~` / `$VAR` expansion.
- `block_internal_http`: reject `http_request` to loopback / private / link-local / cloud-metadata hosts (SSRF guard).

`block_internal_http` is a heuristic over literal IP ranges and known internal names; it does **not** resolve DNS, so DNS-rebinding can still bypass it. For real isolation use `readonly` or a network sandbox.

## Secrets

Never put plaintext API keys in config. Use:

1. environment variable,
2. private token file,
3. credential command.

