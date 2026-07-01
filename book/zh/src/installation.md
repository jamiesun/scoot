# 安装

Scoot 以单个自包含二进制分发。你可以从源码构建，也可以下载某个 tag 版本的发布产物。

## 环境要求

- **Zig 0.16.0 或更新版本** 用于从源码构建。没有其他构建依赖。
- 一个可达的 **OpenAI 兼容** Responses API（`/v1/responses`）后端（本地或远程）。
- 一个 POSIX shell（`/bin/sh`）供 `bash` 工具使用。结构化工具
  （`file_read`、`grep`、`glob`、`http_request`……）无需任何外部命令。

支持的发布目标：`linux-amd64`、`linux-arm64`、`linux-armv7`、
`macos-amd64`、`macos-arm64`。

## 安装 latest release

安装脚本会识别当前主机的 OS/CPU，下载匹配的 latest release 压缩包和 `.sha256`
文件，校验通过后安装 `scoot` 二进制。

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | sh
```

默认安装到 `/usr/local/bin`，必要时会使用 `sudo`。如果想避免 sudo，请指定一个
已经在 `PATH` 中的用户可写目录：

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | env SCOOT_INSTALL_DIR="$HOME/.local/bin" sh
```

需要可复现安装时，可以固定版本：

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | env SCOOT_INSTALL_VERSION=v0.2.0 sh
```

安装脚本支持的环境变量：

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `SCOOT_INSTALL_DIR` | `/usr/local/bin` | 二进制安装目录。 |
| `SCOOT_INSTALL_VERSION` | `latest` | 要安装的 release tag，可带或不带开头的 `v`。 |
| `SCOOT_INSTALL_BINARY` | `scoot` | 安装后的二进制名称。 |
| `SCOOT_INSTALL_REPO` | `jamiesun/scoot` | 下载 release 的 GitHub 仓库。 |
| `SCOOT_INSTALL_EDGE` | 未设置（opt-in） | 设为任意非空值时，额外下载并安装可选的 `scoot-edge` 舰队伴生程序到 `$SCOOT_INSTALL_DIR/scoot-edge`。除非显式要求，否则永不安装。 |

## 用 Homebrew 安装（macOS）

一个 Homebrew tap 为 macOS 发布 formula：

```sh
brew install jamiesun/tap/scoot
```

如果还要运行只做计算的 Wasm 工具包（`wasm_tool` action），再安装可选的独立 host。
它的 formula 依赖 `scoot`，所以这一条命令会同时装上 agent 和 host：

```sh
brew install jamiesun/tap/scoot-wasm
```

如果还想让管理中心观测 / 派发任务到这台 Scoot，再安装可选的独立舰队伴生程序。
它的 formula 同样依赖 `scoot`，因为 `scoot-edge` 会把 agent 当子进程启动：

```sh
brew install jamiesun/tap/scoot-edge
```

三者都会落在 Homebrew 的 `bin`（已在 `PATH` 上），因此默认的
`wasm_host = ["scoot-wasm", "wasi", "{component}"]` 会从 `PATH` 解析到
`scoot-wasm`，无需额外配置；`scoot-edge` 默认也会从 `PATH` 找到 `scoot`
（可用 `--scoot-bin` 覆盖）。核心 `scoot` formula 永远不会带上任何一个可选伴生
程序，保持默认安装最小化。

## 用 apt 安装（Debian/Ubuntu）

可选的 `scoot-edge` 舰队伴生程序也发布到了一个共享的 apt 仓库
[`jamiesun/apt-tap`](https://github.com/jamiesun/apt-tap)，覆盖
`amd64`、`arm64`、`armhf` 三种架构：

```sh
curl -fsSL https://jamiesun.github.io/apt-tap/pubkey.gpg | sudo gpg --dearmor -o /usr/share/keyrings/jamiesun-apt-tap.gpg
echo "deb [signed-by=/usr/share/keyrings/jamiesun-apt-tap.gpg] https://jamiesun.github.io/apt-tap stable main" | sudo tee /etc/apt/sources.list.d/jamiesun-apt-tap.list
sudo apt update
sudo apt install scoot-edge
```

目前只有 `scoot-edge` 打包成了 apt 包，核心 `scoot` 二进制没有——请先用上面的
脚本或 Homebrew 安装 `scoot`，如果你更喜欢用 apt 而不是安装脚本的
`SCOOT_INSTALL_EDGE=1` 开关或 Homebrew formula，再用 apt 装 `scoot-edge`。
`jamiesun/apt-tap` 和上面的 `homebrew-tap` 一样，是多个不相关工具共享的同一个
仓库。

## 发布构建变体

预编译的 release 压缩包只发布一种变体——Zig `ReleaseSafe`，保留运行时安全检查与
清晰的 fail-fast 诊断。如果你需要更小的二进制（用于探针、边缘设备或极简容器），
请用 `ReleaseSmall` 从源码自行编译（见[从源码构建](#从源码构建)）。每个目标还会
单独发布一个 `scoot-wasm-*` 压缩包（只包含可选的 Wasm 计算单元 host）和一个
`scoot-edge-*` 压缩包（只包含可选的舰队伴生程序）。

## 从源码构建

```sh
git clone https://github.com/jamiesun/scoot.git
cd scoot

zig build              # produces ./zig-out/bin/scoot
zig build test         # run the full test suite
zig build run -- --version
```

用于生产 / 嵌入式构建时，优先使用某种 release 优化模式：

```sh
zig build -Doptimize=ReleaseSafe   # recommended: keeps safety checks
zig build -Doptimize=ReleaseFast   # fastest, fewer safety checks
zig build -Doptimize=ReleaseSmall  # smallest, fewer safety checks
```

如果愿意，可以把二进制放到 `PATH` 上：

```sh
install -m 0755 zig-out/bin/scoot /usr/local/bin/scoot
```

## 安装发布产物

每个 tag 版本会为每个目标发布一个 `scoot-<target>.tar.gz`，外加一个独立的
`scoot-wasm-<target>.tar.gz`（可选的 Wasm host）、一个独立的
`scoot-edge-<target>.tar.gz`（可选的舰队伴生程序），以及各自对应的 `.sha256` 校验和。

```sh
# Pick the archive for your platform from the Releases page, then:
sha256sum -c scoot-<target>.tar.gz.sha256
tar -xzf scoot-<target>.tar.gz
install -m 0755 scoot/scoot /usr/local/bin/scoot
scoot --version
```

## 用 Docker 运行

每个 tag release 还会发布面向 `linux/amd64`、`linux/arm64` 和
`linux/arm/v7` 的多平台 Linux 容器镜像。

标签规则：

| 标签形式 | 运行时基础镜像 | 示例 |
| --- | --- | --- |
| `<version>`、`<major>.<minor>`、`<major>`、`latest` | 极简 BusyBox/musl 运行时 | `ghcr.io/jamiesun/scoot:latest` |
| `<version>-alpine`、`<major>.<minor>-alpine`、`<major>-alpine`、`latest-alpine` | 带 `apk` 的 Alpine 运行时 | `ghcr.io/jamiesun/scoot:latest-alpine` |

镜像的 entrypoint 是 `scoot`，因此镜像名后面的参数就是普通 Scoot CLI 参数。
容器里建议始终显式设置 `SCOOT_HOME` 并挂载一个运行目录，避免 `config.toml`、
状态、会话、技能和日志留在镜像文件系统里：

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

如果后端运行在 Docker 宿主机上，容器内的 `127.0.0.1` 指的是容器自身。请把挂载
配置里的 `[backend] base_url` 改成容器可访问的地址：

```toml
[backend]
base_url = "http://host.docker.internal:11434/v1"
model = "qwen2.5"
api_key_env = "OPENAI_API_KEY"
```

Docker Desktop 和 OrbStack 通常内置 `host.docker.internal`。Linux Docker
Engine 可以给 `docker run` 增加：

```sh
--add-host=host.docker.internal:host-gateway
```

或者直接使用后端真实的 LAN / 容器网络地址。

### 一次性容器运行

当人、CI 或脚本只想立即执行一个目标时，使用一次性容器：

```sh
docker run --rm \
  -e SCOOT_HOME=/scoot \
  -e OPENAI_API_KEY \
  -v "$PWD/scoot-data:/scoot" \
  ghcr.io/jamiesun/scoot:latest \
  -e "Inspect the mounted project and summarize obvious risks."
```

### 无人值守调度容器

`config.example.toml` 默认关闭调度：

```toml
[schedule]
enabled = false
```

这是有意的安全默认值。`scoot schedule run` 和 `scoot daemon run` 会在挂载配置
没有显式启用调度时 fail-closed 退出。容器化调度任务需要编辑
`scoot-data/config.toml`：

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

当外部调度器每次拉起一个新容器时，例如宿主机 cron、CI、systemd timer 或
Kubernetes CronJob，使用 `schedule run --ticks 1`：

```sh
docker run --rm \
  -e SCOOT_HOME=/scoot \
  -e OPENAI_API_KEY \
  -v "$PWD/scoot-data:/scoot" \
  ghcr.io/jamiesun/scoot:latest \
  schedule run --ticks 1
```

因为每次容器退出后调度器运行时内存都会重置，`every_sec` 任务在每个新容器的第一轮
都会到期。如果需要严格日历时间，建议使用与外部调度频率一致的 `cron` 触发器。

当容器本身要长驻并负责持续轮询任务时，使用 `daemon run`。它保持前台运行，写入
`state/daemon.json` 与 `state/daemon.pid`，并处理 SIGTERM/SIGINT 以便容器干净停止：

```sh
docker run -d --name scoot \
  -e SCOOT_HOME=/scoot \
  -e OPENAI_API_KEY \
  -v "$PWD/scoot-data:/scoot" \
  ghcr.io/jamiesun/scoot:latest \
  daemon run
```

`docker compose` 示例：

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

运行 `daemon run` 时，`/scoot` 挂载目录需要可写，因为 Scoot 要写入 state、session
和 audit 文件。如果希望配置文件本身只读，可以让部署系统管理 `config.toml`，同时保留
可写的 `state/`、`logs/` 和 `skills/` 子目录。

## 首次运行设置

Scoot 在内置默认值下即可工作，但你通常会把它指向自己的后端与 token。

**1. 创建运行目录与配置。** Scoot 默认使用 `~/.scoot`；把示例配置复制到那里：

```sh
mkdir -p ~/.scoot
cp config.example.toml ~/.scoot/config.toml
```

**2. 选择一个后端。** 编辑 `~/.scoot/config.toml` 中的 `[backend]`：

```toml
[backend]
# Local Ollama-compatible endpoint (the default):
base_url = "http://127.0.0.1:11434/v1"
model    = "qwen2.5"

# Or a hosted OpenAI-compatible endpoint:
# base_url = "https://api.openai.com/v1"
# model    = "gpt-4o-mini"
```

**3. 提供 token，但不要写进配置。** Scoot 先从环境变量解析密钥，再尝试 `0600`
的 token 文件，最后是凭证命令。最简单的方式：

```sh
export OPENAI_API_KEY="sk-..."
```

或者使用一个私密的 token 文件：

```sh
umask 077
printf '%s' "sk-..." > ~/.scoot/token   # must be mode 0600
```

完整的解析顺序与凭证命令选项参见 [配置 → 密钥](configuration.md)。

**4. 验证。** `config` 打印解析出的运行目录与后端（密钥已脱敏）；
`doctor` 运行本地健康检查：

```sh
scoot config
scoot doctor
```

`doctor` 会报告运行目录、配置来源、后端可达性前置条件、解析出的密钥 **来源**
（绝不报告值本身）、技能发现，以及审计日志路径。在运行目标前，先修复它标记出的所有问题。

## 后端示例

Scoot 只讲 OpenAI 兼容 Responses API（`/v1/responses`）。Ollama ≥ 0.13.3 与 vLLM
支持这种无状态接口；其他后端需置于 Responses 兼容网关之后。

### Ollama（本地，默认）

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

### Azure / 其他带额外字段的厂商

使用 `[backend.extra_body]` 传递厂商专有的顶层请求字段，无需重新编译。绝不要把密钥放在这里。

```toml
[backend]
base_url = "https://your-resource.openai.azure.com/openai/v1"
model    = "gpt-4o"

[backend.extra_body]
reasoning_effort = "high"
service_tier     = "priority"
```

### 自定义 CA bundle（精简 / 嵌入式系统）

如果系统根证书缺失（在最小化 Linux 镜像上很常见），把 `ca_file` 指向随固件附带的 PEM bundle：

```toml
[backend]
ca_file = "/etc/ssl/certs/ca-certificates.crt"
```

## 下一步

- [配置](configuration.md)——每个配置键及其默认值。
- [CLI 参考](cli.md)——每个命令与标志。
- [内建工具](tools.md)——agent 实际能做什么。
- [故障排查与 FAQ](troubleshooting.md)——如果有东西不工作。
