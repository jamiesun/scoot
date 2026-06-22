# Scoot

[English](../README.md) | 中文

<p align="center">
  <img src="assets/scoot-infographic.png" alt="Scoot - 纯 Zig 编写的本地优先 AI Agent 守护进程和 CLI" width="100%">
</p>

Scoot 是一个用纯 Zig 编写的本地优先 AI Agent CLI / 守护进程。它连接
OpenAI 兼容模型后端，让模型输出结构化 ReACT 步骤，再通过策略门执行本地
工具，并把会话和审计事件保存在你的机器上。

适合这些场景：你想在终端里运行一个轻量 Agent，让它检查项目、编辑文件、
执行受控命令、读取本地技能，或以只读方式执行无人值守的定时任务，同时不
引入庞大的应用栈。

## 为什么用 Scoot

| 需求 | Scoot 的做法 |
| --- | --- |
| 在终端里运行 Agent | 一个自包含二进制，同时支持单次任务和 REPL。 |
| 状态保存在本地 | 配置、会话、技能、日志和 daemon 状态默认位于 `~/.scoot`。 |
| 复用现有模型基础设施 | 支持本地或云端 OpenAI 兼容 Responses API 后端（Ollama >= 0.13.3、vLLM、OpenAI）。 |
| 降低误操作风险 | 所有工具调用经过 `guarded`、`readonly` 或 `unrestricted` 策略检查。 |
| 事后可审计 | Agent 步骤和工具决策都会落成本地 JSONL 状态。 |
| 扩展行为 | 从本地目录发现 skills，并在需要时渐进式读取。 |

## 为什么用 Zig

单个二进制发布不是 Zig 独有优势，Go 和 Rust 也能做到。Scoot 选择 Zig，是因为
它的优势更贴合这个 Agent 的部署场景：

1. **极小的独立部署形态。** Scoot 适合作为本地小工具、sidecar 或嵌入式
   Agent 运行；在这些机器上安装语言 runtime、包树或服务栈都是不必要的摩擦。
2. **资源受限设备上的可控内存。** Zig 让内存分配在代码里保持可见，这适合
   长期运行的 daemon，也适合低内存 Linux 主机、边缘设备、NAS 或其他资源受限环境。
3. **低依赖的跨平台迁移。** Zig 的交叉编译和 libc 处理能力，让同一个 Agent
   更容易迁移到不同 Linux/macOS 目标和 CPU 架构，同时保持较小的外部依赖面。

## 设计理念

Scoot 刻意保守。它优先追求安全、可审计、本地优先、小部署面和长时间运行稳定，
功能广度排在后面。

有些看起来像缺陷的地方，其实是选择：

- 不做 GUI，因为界面应保持可脚本化、可检查；
- 不扩散到厂商私有协议，因为模型边界保持 OpenAI 兼容；
- 不把 `guarded` 伪装成沙箱，因为无人值守应使用 `readonly` 和 OS 隔离；
- 不做原生插件运行时，因为 skills 应扩展行为，而不是扩大可信二进制面；
- daemon 保持前台运行，因为后台化、重启、日志和停止应交给 `systemd` 这类 supervisor。

铁律很简单：校验模型输出、所有效果经过策略门、外部工作必须有超时、密钥不能进入
文本产物、状态留在本地。完整目标、非目标和硬边界见
[设计理念](../book/zh/src/design-philosophy.md)。

## 当前状态

核心运行时已经可用：

- `scoot -e` 用于单次任务，`scoot` / `scoot repl` 用于交互模式。
- 内建工具覆盖 shell、文件读写编辑、正则搜索、glob、文件结构概览、
  HTTP、skills、transcript 召回和有界并行只读调用。
- 策略模式包括默认的 `guarded`、适合 fail-closed 场景的 `readonly`，
  以及明确接受完整本地访问风险时使用的 `unrestricted`。
- 配置优先 TOML，回落 JSON；密钥可从环境变量、文件或命令加载。
- 支持定时任务和前台 daemon 模式，无人值守的 `guarded` 任务会被强制
  以有效 `readonly` 运行。
- 会话和审计日志以 JSONL 保存在本地。

## 快速开始

### 1. 安装或构建

安装适合当前主机的 latest release：

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | sh
```

也可以安装到用户可写目录：

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | env SCOOT_INSTALL_DIR="$HOME/.local/bin" sh
```

安装脚本会识别 OS/CPU，下载匹配的 latest release 产物和 `.sha256` 文件，完成
校验后安装 `scoot`。

资源受限主机可以显式安装 small 构建：

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | env SCOOT_INSTALL_FLAVOR=small sh
```

默认 release 保留 Zig 运行时安全检查。small release 优先压缩二进制体积，并会
关闭这些检查；适合体积比 fail-fast 诊断更重要的场景。

如果要从源码构建，需要 **Zig 0.16.0 或更新版本**：

```sh
zig build
zig build test
./zig-out/bin/scoot --version
```

构建优化版本：

```sh
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSmall
```

### 2. 配置

最快的方式是交互式向导。它会为你创建运行目录并写出 `config.toml`，只需回答后端、token
来源、`max_turns` 与策略等少数问题 —— 它也是在同一台主机上搭建 **多个隔离实例** 的最简方式
（让每个实例各自指向自己的 `--scoot-home` / `SCOOT_HOME`）：

```sh
./zig-out/bin/scoot setup
./zig-out/bin/scoot --scoot-home /opt/scoot/instance-a setup
```

或者手动从示例配置开始。Scoot 默认使用 `~/.scoot`：

```sh
mkdir -p ~/.scoot
cp config.example.toml ~/.scoot/config.toml
```

编辑 `[backend]`，指向你的 OpenAI 兼容后端。Scoot 只讲 Responses API
（`/v1/responses`），后端必须提供该接口（Ollama >= 0.13.3、vLLM 或 OpenAI）：

```toml
[backend]
base_url = "http://127.0.0.1:11434/v1"
model = "qwen2.5"
api_key_env = "OPENAI_API_KEY"
```

不要把 token 写进会提交到仓库的配置。使用云端后端时，最简单的方式是：

```sh
export OPENAI_API_KEY="sk-..."
```

如果使用不需要鉴权的本地后端，例如 Ollama 兼容端点，可以不设置 token。

### 3. 验证

```sh
./zig-out/bin/scoot config
./zig-out/bin/scoot doctor
```

`config` 会显示解析后的运行目录和后端配置，并隐藏密钥。`doctor` 会检查本地
前置条件、配置加载、密钥来源、skills 和审计路径，也不会打印 token 值。

### 4. 运行一个目标

```sh
./zig-out/bin/scoot -e "总结这个仓库"
./zig-out/bin/scoot --trace -e "统计当前仓库中的 Zig 源文件数量"
./zig-out/bin/scoot
```

`-e` 只把最终答案写到 stdout，适合脚本化使用。`--trace` 会把 ReACT 执行
进度写到 stderr，并显示 `thinking:`、`running: <tool>` 之类的实时标记。

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `scoot` 或 `scoot repl` | 启动交互式 REPL。 |
| `scoot -e "<goal>"` | 执行一个目标后退出。 |
| `scoot --trace -e "<goal>"` | 执行一个目标，并把执行轨迹写到 stderr。 |
| `scoot setup` | 交互式生成配置目录（快速 / 多实例部署）。 |
| `scoot config` | 显示解析后的配置，密钥会被隐藏。 |
| `scoot doctor` | 执行本地健康检查。 |
| `scoot policy check <action> <input>` | 在指定策略下 dry-run 一个工具动作。 |
| `scoot skills` | 列出发现到的本地 skills。 |
| `scoot skills check [dir]` | 校验 skill 目录，不执行脚本。 |
| `scoot skills pack <dir> [out.tar]` | 导出可审查的 skill 包。 |
| `scoot wasm-tools check <dir>` | 静态校验 Wasm 工具包边界。 |
| `scoot schedule list` | 查看已配置的定时任务。 |
| `scoot daemon run` | 以前台 daemon loop 运行定时任务。 |

示例：

```sh
./zig-out/bin/scoot policy check bash "rm -rf /" --mode guarded
./zig-out/bin/scoot skills check docs/examples/skills/minimal
./zig-out/bin/scoot skills pack docs/examples/skills/minimal minimal.scoot-skill.tar
./zig-out/bin/scoot wasm-tools check path/to/tool
./zig-out/bin/scoot daemon run --ticks 1
```

## 选择合适的运行模式

Scoot 常见的运行方式有三种，它们的定位不同：

| 模式 | 目标来源 | 生命周期 | 什么时候用 |
| --- | --- | --- | --- |
| `scoot -e "<goal>"` | 命令行里的 prompt。 | 立刻运行，打印最终答案，然后退出。 | 人或脚本要执行一个即时任务。 |
| `scoot schedule run --ticks 1` | 配置里的 `[[schedule.jobs]]`。 | 轮询一次配置任务，执行到期任务，然后退出。 | 由 cron 或 systemd timer 这类外部调度器负责触发时间。 |
| `scoot daemon run` | 配置里的 `[[schedule.jobs]]`。 | 默认持续轮询；加 `--ticks N` 才会有界退出。 | 由 Scoot 自己负责调度循环，外部 supervisor 只负责托管进程。 |

`daemon run` 不是换了名字的 `-e`。`-e` 会立即执行一个明确的 prompt；
`daemon run` 会加载配置任务，根据 `every_sec`、`at_unix` 或 `cron` 判断
哪些任务到期，写入 daemon pid/state 文件，并使用无人值守任务的安全规则。
配合 `daemon run` 使用 `systemd` 的意义在于：Scoot 保持前台运行，systemd
负责启动、重启、日志、环境变量和停止。

## 配置模型

运行时文件默认位于 `~/.scoot`。可以用 `--scoot-home` 或 `SCOOT_HOME` 覆盖，
其中命令行参数优先级更高。

```text
~/.scoot/
  config.toml
  token
  skills/
  logs/
  state/
```

配置优先级：

```text
SCOOT_* 环境变量覆盖 > config.toml > 内置默认值
```

密钥刻意不走 `SCOOT_*` 覆盖。Scoot 会先读取 `backend.api_key_env` 指定的
环境变量，再读取 `backend.api_key_file`，最后尝试 `backend.api_key_cmd`。
完整表格和 CI 示例见
[配置 -> 环境变量覆盖](../book/zh/src/configuration.md#环境变量覆盖)。

## 安全模型

Scoot 会先校验模型输出的每一步，再根据当前策略检查工具调用：

| 模式 | 适用场景 | 行为 |
| --- | --- | --- |
| `guarded` | 普通交互式工作。 | 允许常规操作，但拦截已知灾难性 shell 模式。 |
| `readonly` | 不可信或无人值守任务。 | 禁止 shell、写入和网络；允许受限本地读取。 |
| `unrestricted` | 你完全信任这个目标。 | 允许所有工具动作，但仍会审计。 |

`guarded` 是默认便利模式，不是安全沙箱。不可信目标和无人值守任务应使用
`readonly`。如果需要强隔离，应再配合容器、只读挂载、网络隔离等操作系统
级机制。

## 内建能力

模型只能请求结构化动作。当前内建动作包括：

- `bash`：执行有超时限制的 POSIX shell 命令。
- `file_read`、`file_write`、`file_edit`：文件操作。
- `grep`、`glob`、`outline`：项目检查和定位。
- `http_request`：执行一次有界 HTTP/HTTPS 请求。
- `mcp_call`：调用已配置 MCP server 的工具，支持 stdio、Streamable HTTP 与 legacy SSE。
- `skill`：读取可信本地 skill 的说明和资源。
- `recall`：从当前会话 transcript 中取回较早的精确原文消息。
- `parallel`：一次执行 1-4 个彼此独立的只读调用。
- `final`：返回最终答案。

结构化文件、搜索和 HTTP 工具不依赖外部 shell 命令，因此在精简系统或嵌入式
环境中也能工作。

## 文档

完整用户指南是 [`book/`](../book/) 下的双语 mdBook：

- [安装](../book/zh/src/installation.md) - 构建、安装、后端配置。
- [设计理念](../book/zh/src/design-philosophy.md) - 目标、非目标和硬边界。
- [配置](../book/zh/src/configuration.md) - 每个配置项及默认值。
- [CLI 参考](../book/zh/src/cli.md) - 每个命令和选项。
- [内建工具](../book/zh/src/tools.md) - 所有 Agent 动作。
- [执行策略与安全](../book/zh/src/policy.md) - 模式和威胁模型。
- [技能](../book/zh/src/skills.md) - 编写和使用 skills。
- [调度与守护进程](../book/zh/src/scheduling.md) - 无人值守任务。
- [会话与审计](../book/zh/src/sessions.md) - 本地状态格式。
- [Wasm 工具包](../book/zh/src/wasm-tools.md) - 工具包边界。
- [嵌入 API](../book/zh/src/embed-api.md) - 稳定 Zig 包公共面。
- [最佳实践案例](../book/zh/src/best-practices.md) - CI、运维、探针与 runbook。
- [故障排查与 FAQ](../book/zh/src/troubleshooting.md)

英文章节位于 [`book/en/src/`](../book/en/src/)。

参考文档：

- 英文 README：[README.md](../README.md)
- 路线图：[ROADMAP.md](ROADMAP.md) / [ROADMAP.zh.md](ROADMAP.zh.md)
- Agent 指南：[AGENT.md](../AGENT.md) / [AGENT.zh.md](AGENT.zh.md)
- Daemon 生命周期：[DAEMON.md](DAEMON.md) / [DAEMON.zh.md](DAEMON.zh.md)
- Skills：[SKILLS.md](SKILLS.md) / [SKILLS.zh.md](SKILLS.zh.md)
- Wasm 工具包：[WASM_TOOLS.md](WASM_TOOLS.md) / [WASM_TOOLS.zh.md](WASM_TOOLS.zh.md)
- 更新日志：[CHANGELOG.md](../CHANGELOG.md) / [CHANGELOG.zh.md](CHANGELOG.zh.md)

本地构建文档：

```sh
mdbook build book/en
mdbook build book/zh
mkdir -p site
cp book/site-index.html site/index.html
mkdir -p site/assets
cp docs/assets/scoot-logo.svg docs/assets/scoot-favicon.svg docs/assets/scoot-favicon.png site/assets/
```

## 仓库结构

```text
src/                 Zig 源码
src/tools/           内建工具
docs/                项目文档与翻译文档
book/en/             英文 mdBook 站点
book/zh/             中文 mdBook 站点
.github/workflows/   CI、Release 与文档工作流
```

## 发布产物

推送版本标签后会发布：

- `linux-amd64`
- `linux-arm64`
- `linux-armv7`
- `macos-amd64`
- `macos-arm64`

每个目标还会发布一个用 `ReleaseSmall` 构建的 `-small` 变体。每个产物包含
`.tar.gz` 压缩包和 `.sha256` 校验文件。release 也会单独发布 `install.sh`，
并且每个压缩包中也包含同一份安装脚本。

## 文档同步规则

项目文档保持中英双语同步。根目录文档默认英文，中文文档放在 `docs/` 下并
使用 `.zh.md` 后缀。修改英文文档时，应在同一变更中更新中文对应文档。

## 许可证

MIT。详见 [LICENSE](../LICENSE)。
