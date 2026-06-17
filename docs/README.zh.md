# Scoot

[English](../README.md) | 中文

<p align="center">
  <img src="assets/scoot-infographic.png" alt="Scoot —— 纯 Zig 编写的本地优先 AI Agent 守护进程 / CLI，展示 ReACT 闭环（模型、校验、策略、工具、审计）、内建工具与 guarded/readonly/unrestricted 执行策略" width="100%">
</p>

Scoot 是一个用纯 Zig 编写的轻量级 AI Agent 守护进程 / CLI。它在纯文本环境下运行，对接 OpenAI 兼容模型后端，校验模型输出的结构化步骤，通过策略门执行本地工具，并把每一步记录为可审计的本地状态。

项目设计刻意保守：

- 本地优先保存运行状态，
- 单体轻量二进制，
- 不做 GUI，
- 不扩散到多供应商私有协议，
- 不把明文密钥写进随仓库提交的配置，
- 不执行未经校验的模型输出。

## 当前状态

核心底座已经可用：

- `scoot -e` 单次执行和交互式 REPL 可运行 ReACT 闭环，
- 内建工具覆盖 shell、文件操作、搜索 / glob、HTTP，
- 执行策略支持 `guarded`、`readonly`、`unrestricted`，
- skill 通过本地目录发现并渐进式披露，
- 调度任务默认以有效 `readonly` 档运行，
- 会话和审计事件以 JSONL 落盘，
- 配置优先 TOML，回落 JSON，密钥从环境变量 / 文件 / 命令加载。

## 环境要求

- Zig 0.16.0 或更新版本。

## 构建与运行

```sh
zig build
zig build test
zig build run -- --version
```

运行已构建的二进制：

```sh
./zig-out/bin/scoot --help
./zig-out/bin/scoot config
./zig-out/bin/scoot doctor
./zig-out/bin/scoot --scoot-home /tmp/scoot-test doctor
./zig-out/bin/scoot policy check bash "rm -rf /" --mode guarded
./zig-out/bin/scoot skills
./zig-out/bin/scoot skills check
./zig-out/bin/scoot skills check docs/examples/skills/minimal
./zig-out/bin/scoot skills check docs/examples/skills/metadata
./zig-out/bin/scoot skills pack docs/examples/skills/minimal minimal.scoot-skill.tar
./zig-out/bin/scoot wasm-tools check path/to/tool
./zig-out/bin/scoot schedule list
./zig-out/bin/scoot daemon status
./zig-out/bin/scoot daemon run --ticks 1
./zig-out/bin/scoot daemon stop
./zig-out/bin/scoot -e "统计当前仓库中的 Zig 源文件数量"
./zig-out/bin/scoot --retries 4 -e "统计当前仓库中的 Zig 源文件数量"
./zig-out/bin/scoot --trace -e "统计当前仓库中的 Zig 源文件数量"
```

`--trace` 用于单次 CLI 调试：ReACT 执行轨迹打印到 stderr，最终答复仍保持在 stdout。`--retries` 控制 `-e` 遇到限流、5xx 等临时后端错误时的重试次数。

`doctor` 执行本地健康检查且不会打印密钥。`--scoot-home` 可覆盖运行目录，方便隔离测试。`policy check` 可在 `guarded`、`readonly` 或 `unrestricted` 策略档下 dry-run 某个工具动作。

`skills check [dir]` 用于校验本地 skill 结构，不会执行 skill 脚本。合法 skill 目录需要包含 `SKILL.md`，且 YAML front matter 中必须有非空 `name` 与 `description`；可选的 `capabilities`、`allowed_tools`、`scope` 审查元数据也会被校验。兼容性声明暂未定义执行门槛，出现时会给出明确失败。

`skills pack <dir> [out.tar]` 会先校验 skill，再导出带 `.scoot-skill.json` 审查清单的 tar 包。它只包含非隐藏普通文件，拒绝符号链接等不支持的文件类型，也不会执行脚本或绕过 policy。

模板见 [docs/examples/skills/minimal/SKILL.md](examples/skills/minimal/SKILL.md) 和 [docs/examples/skills/metadata/SKILL.md](examples/skills/metadata/SKILL.md)。

`wasm-tools check <dir>` 校验本地 Wasm 工具包边界，包括 `manifest.toml`、`policy.toml`、引用的 JSON schema 和安全相对路径。它只做静态校验，不会加载或执行 Wasm。

`daemon run` 是 scheduled job 的前台长运行模式。它会写入 `state/daemon.json` 和 `state/daemon.pid`，处理 SIGTERM/SIGINT，并保留 scheduled job 的安全规则：无人值守的 `guarded` job 会以有效 `readonly` 运行。

Agent 也可以使用有界 `parallel` 动作一次执行 1-4 个彼此独立的只读工具调用。观察结果按输入顺序返回，shell、写操作和嵌套 parallel 会被拒绝，每个子调用仍然经过正常 policy gate。

## 配置

使用 `--scoot-home` 或 `SCOOT_HOME` 指定运行目录。`--scoot-home` 优先级高于环境变量。默认运行目录是 `~/.scoot`。

```text
~/.scoot/
  config.toml
  token
  skills/
  logs/
  state/
```

可从 [config.example.toml](../config.example.toml) 开始。

## 文档

- 英文 README：[README.md](../README.md)
- 英文路线图：[ROADMAP.md](ROADMAP.md)
- 中文路线图：[ROADMAP.zh.md](ROADMAP.zh.md)
- 英文 Agent 指南：[AGENT.md](../AGENT.md)
- 中文 Agent 指南：[AGENT.zh.md](AGENT.zh.md)
- 英文 Daemon 生命周期：[DAEMON.md](DAEMON.md)
- 中文 Daemon 生命周期：[DAEMON.zh.md](DAEMON.zh.md)
- 英文 Skills 指南：[SKILLS.md](SKILLS.md)
- 中文 Skills 指南：[SKILLS.zh.md](SKILLS.zh.md)
- 英文 Wasm 工具包：[WASM_TOOLS.md](WASM_TOOLS.md)
- 中文 Wasm 工具包：[WASM_TOOLS.zh.md](WASM_TOOLS.zh.md)
- mdBook 源码：[book/](../book/)

本地构建文档：

```sh
mdbook build book/en
mdbook build book/zh
mkdir -p site
cp book/site-index.html site/index.html
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

## 文档同步规则

项目文档必须保持中英双语同步。根目录文档默认英文。中文文档放在 `docs/` 下并使用 `.zh.md` 后缀。修改英文文档时，必须在同一变更中更新中文对应文档。

## 发布产物

推送版本标签后会发布：

- `linux-amd64`
- `linux-arm64`
- `linux-armv7`
- `macos-amd64`
- `macos-arm64`

每个产物包含 `.tar.gz` 压缩包和 `.sha256` 校验文件。

## 许可证

MIT。详见 [LICENSE](../LICENSE)。
