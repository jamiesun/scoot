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

Debian/Ubuntu (apt, amd64/arm64/armhf):

```sh
curl -fsSL https://jamiesun.github.io/apt-tap/pubkey.gpg | sudo gpg --dearmor -o /usr/share/keyrings/jamiesun-apt-tap.gpg
echo "deb [signed-by=/usr/share/keyrings/jamiesun-apt-tap.gpg] https://jamiesun.github.io/apt-tap stable main" | sudo tee /etc/apt/sources.list.d/jamiesun-apt-tap.list
sudo apt update
sudo apt install scoot          # the agent
sudo apt install scoot-wasm     # optional Wasm compute-unit host (pulls in scoot)
sudo apt install scoot-edge     # optional fleet companion (pulls in scoot)
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
