# Scoot Playground（中文）

一套完整、可提交到 git、可反复运行的 Scoot 端到端评估环境，无需改动 `~/.scoot`。
与个人临时目录不同，本目录纳入 git 管理：配置默认值、技能、Wasm 工具、任务和脚本是
共享的，而所有运行时状态与密钥都留在本地并被忽略。

English: see [README.md](README.md).

## 提交 vs 忽略

提交（即测试环境本体）：

- `config.default.toml` —— 默认运行时配置，不含任何密钥。
- `skills/` —— playground 专用技能（`playground-operator`、`playground-evaluator`）。
- `tools/wasm/byte-stats/` —— 一个 compute-only 的 Wasm 工具包（源码 + manifest/policy/schema）。
- `tasks/` —— 驱动可复现测试的提示词。
- `scripts/` —— 辅助脚本、评估脚本与清理脚本。
- `.env.example` —— 本地密钥/覆盖项模板。

忽略（见 `.gitignore`）：

- `.env` —— 你的 API key 与个人后端覆盖项。
- `config.toml` —— 运行时由 `config.default.toml` + `.env` 生成。
- `runs/`、`logs/`、`state/`、`reports/`、`tmp/` —— 所有运行时数据。
- `tools/wasm/*/component.wasm` —— 构建产物（可从源码复现）。

## 准备

```sh
# 1. 在仓库根目录构建 scoot（以及 wasm host）。
zig build
zig build -Dwasm-host=true   # 为 wasm_tool 动作提供 scoot-wasm

# 2. 创建本地 env 文件并填入 API key。
cp playground/.env.example playground/.env
$EDITOR playground/.env
```

`SCOOT_PLAYGROUND_API_KEY` 必填。可选设置 `SCOOT_PLAYGROUND_BASE_URL` 与
`SCOOT_PLAYGROUND_MODEL` 指向你自己的 OpenAI 兼容端点；否则使用提交的默认值
（本地 Ollama）。脚本会自动 source `.env` 并重新生成 `config.toml`。

## 常用命令

所有脚本以 `SCOOT_HOME=playground` 和仓库的 `zig-out/bin/scoot` 运行。

```sh
playground/scripts/check-backend.sh           # 验证后端可达
playground/scripts/build-wasm-tools.sh        # 构建 + 校验 Wasm 工具
playground/scripts/policy-dry-runs.sh readonly# 固定的策略 dry-run
playground/scripts/run-task.sh playground/tasks/smoke.txt
playground/scripts/run-mcp-server.sh          # 前台运行本地 MCP echo 服务
playground/scripts/recall-smoke.sh            # best-effort recall 探针（模型派发时验证真实 recall 动作）
playground/scripts/state-brief.sh             # 精简状态 + 审计计数
playground/scripts/evaluate.sh                # 完整评估 -> reports/*.md
playground/scripts/clean.sh                   # 清空运行时状态，保留 .env
```

## 完整评估

`evaluate.sh` 是一键评估套件，它会：

1. 打印解析后的配置与发现的技能；
2. 构建并校验 `byte-stats` Wasm 包；
3. 检查后端可达性；
4. 运行固定的策略 dry-run；
5. 运行全部任务提示（技能使用、写入工具、`wasm_tool`、`http_request`、`parallel`、策略、审计）；
6. 针对自管的本地 MCP 服务运行 `mcp_call`；
7. 运行 best-effort 的 `recall` 探针（模型派发时验证真实 recall 动作；非致命）；
8. 汇总审计/会话状态；
9. 将带时间戳的报告写入 `playground/reports/<stamp>-evaluation.md`。

`playground-evaluator` 技能封装了该流程，便于让一次 agent 运行来驱动评估、汇总报告
并按需重置状态。

## 重置以重新开始

```sh
playground/scripts/clean.sh
```

删除 `runs/`、`logs/`、`state/`、`reports/`、`tmp/`、生成的 `config.toml` 以及
构建出的 `component.wasm`；保留 `.env` 与所有提交资产，可立即从干净状态重跑。

## 覆盖范围

| 能力面 | 测试方式 |
| --- | --- |
| 技能（渐进式披露） | 通过 `skill` 动作使用 `playground-operator` / `playground-evaluator` |
| 内建只读工具 | `tasks/smoke.txt`、`tasks/policy_guard.txt`（grep/glob/outline/file_read） |
| 内建写入工具 | `tasks/file_write.txt`（`file_write` + `file_read`）、`tasks/file_edit.txt`（`file_edit`），均在 `guarded` 下 |
| 执行策略 | `policy-dry-runs.sh`、`tasks/policy_guard.txt` |
| `http_request` | `tasks/http_request.txt`（`guarded` 下放行的外部 GET；loopback 拒绝由 `policy-dry-runs.sh` 覆盖） |
| `recall` | `tasks/recall.txt`，由 `recall-smoke.sh` 做 best-effort 探针（派发时验证真实 recall 动作） |
| `parallel` | `tasks/parallel.txt`（有界只读并发：`file_read` + `grep`） |
| `wasm_tool` | `tasks/wasm_tool.txt` 针对 `tools/wasm/byte-stats` |
| `mcp_call` | `tasks/mcp_echo.txt` 针对 `playground-echo` 服务 |
| 审计 / 会话 | `state-brief.sh`、`tasks/state_audit.txt` |
| 调度 | `config.default.toml` 中的 `[[schedule.jobs]]`（默认关闭） |
