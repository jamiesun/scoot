# Scoot

<p align="center">
  <img src="assets/scoot-infographic.png" alt="Scoot —— 纯 Zig 编写的本地优先 AI Agent 守护进程 / CLI，展示 ReACT 闭环、内建工具与执行策略" width="100%">
</p>

Scoot 是一个用 Zig 编写的轻量级 AI Agent 守护进程 / CLI。它通过防御性的 ReACT 闭环对接本地或远程 OpenAI 兼容模型后端：

1. 让模型输出一个结构化步骤，
2. 校验步骤，
3. 经过执行策略门，
4. 运行选中的工具，
5. 写入审计与会话数据，
6. 把观察结果回灌给模型。

## 核心能力

- CLI 与 REPL 执行。
- 内建 shell、文件、搜索 / glob、HTTP 工具。
- 执行策略：`guarded`、`readonly`、`unrestricted`。
- 本地 skill 渐进式披露。
- 无人值守调度默认 `readonly` 安全档。
- JSONL 会话与审计日志。
- TOML/JSON 配置，密钥从环境变量、token 文件或凭证命令加载。

## 快速开始

```sh
zig build
zig build test
./zig-out/bin/scoot config
./zig-out/bin/scoot -e "统计当前仓库中的 Zig 文件数量"
```

## 运行目录

Scoot 默认使用 `~/.scoot`。可通过 `SCOOT_HOME` 隔离测试环境。

```text
~/.scoot/
  config.toml
  token
  skills/
  logs/
  state/
```

可从 `config.example.toml` 开始。

