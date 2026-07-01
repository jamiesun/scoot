---

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | sh
```

Add `SCOOT_INSTALL_EDGE=1` to the same command to also install the optional
`scoot-edge` fleet companion (never installed unless requested).

macOS (Homebrew):

```sh
brew install jamiesun/tap/scoot          # the agent
brew install jamiesun/tap/scoot-wasm      # optional Wasm compute-unit host (pulls in scoot)
brew install jamiesun/tap/scoot-edge      # optional fleet companion (pulls in scoot)
```

### Build flavors

Prebuilt archives are **`ReleaseSafe`** only (runtime safety checks on). If you
need a smaller binary, compile from source:

```sh
zig build -Doptimize=ReleaseSmall   # smallest, fewer safety checks
```

Each target also ships a separate `scoot-wasm-*` archive (the optional
standalone Wasm host) and a separate `scoot-edge-*` archive (the optional
fleet companion). The zero-dependency core `scoot` binary never embeds either.
