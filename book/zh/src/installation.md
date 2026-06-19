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

当体积比运行时安全检查更重要时，可以安装更小的 `ReleaseSmall` 构建：

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | env SCOOT_INSTALL_FLAVOR=small sh
```

安装脚本支持的环境变量：

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `SCOOT_INSTALL_DIR` | `/usr/local/bin` | 二进制安装目录。 |
| `SCOOT_INSTALL_VERSION` | `latest` | 要安装的 release tag，可带或不带开头的 `v`。 |
| `SCOOT_INSTALL_FLAVOR` | `safe` | `safe` 安装默认的 `ReleaseSafe` 产物；`small` 安装 `ReleaseSmall` 产物。 |
| `SCOOT_INSTALL_BINARY` | `scoot` | 安装后的二进制名称。 |
| `SCOOT_INSTALL_REPO` | `jamiesun/scoot` | 下载 release 的 GitHub 仓库。 |

## Safe 与 Small 发布构建

每个 tag 版本会为每个支持目标发布两种二进制：

| 变体 | Zig optimize 模式 | 什么时候用 |
| --- | --- | --- |
| 默认 | `ReleaseSafe` | 需要常规 release，保留运行时安全检查和更清晰的 fail-fast 诊断。 |
| `small` | `ReleaseSmall` | 需要极小二进制用于探针、边缘设备或极简容器，并接受更少运行时安全检查。 |

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

每个 tag 版本会为每个目标发布默认 `.tar.gz`、一个 `-small` 变体，以及对应的
`.sha256` 校验和。

```sh
# Pick the archive for your platform from the Releases page, then:
sha256sum -c scoot-<target>.tar.gz.sha256
tar -xzf scoot-<target>.tar.gz
install -m 0755 scoot/scoot /usr/local/bin/scoot
scoot --version
```

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
