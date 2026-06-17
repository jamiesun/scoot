# Configuration

Scoot loads config from the runtime directory:

1. `config.toml`
2. `config.json`
3. built-in defaults

The recommended starting point is:

- [`config.example.toml`](../../../config.example.toml)

## Main Sections

- `[backend]`: OpenAI-compatible endpoint, model, API key source, CA bundle, extra request fields.
- `[agent]`: turn limit and default mode.
- `[tools]`: timeout and execution policy.
- `[skills]`: skill discovery.
- `[audit]`: audit log behavior.
- `[schedule]`: scheduled jobs.

## Policy Modes

- `guarded`: interactive tripwire mode.
- `readonly`: fail-closed mode for read-only operation.
- `unrestricted`: no policy limit, still audited.

Scheduled jobs correct `guarded` to `readonly`.

## Secrets

Never put plaintext API keys in config. Use:

1. environment variable,
2. private token file,
3. credential command.

