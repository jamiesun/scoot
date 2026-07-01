# 会话与审计

Scoot 把自己做过的事以**追加写 JSONL** 持久化到本地磁盘 —— 短期会话记录与逐步审计日志。两者都是纯文本，便于回放、grep 或喂给其它工具。按设计**没有**长期语义记忆或向量库（见[路线图](roadmap.md)）。

## 会话

会话是一次交互的消息记录。`-e` 与 REPL 每个进程都会获得新的 id，例如
`cli-<ms>-<pid>` 或 `repl-<ms>-<pid>`，因此独立运行不会再追加进同一个
`cli.jsonl` 或 `repl.jsonl`。调度任务仍保留稳定的 `job-<id>`，因为它代表
一个持续的无人值守任务。给 `-e` 传入 `--session-id <id>` 可以用自定义 id
覆盖自动生成的 id，方便外部调用方用自己的 job id 关联一次运行——参见
[CLI 参考](cli.md)。

它持久化到：

```text
~/.scoot/state/sessions/<id>.jsonl
```

每行一条消息：

```json
{"role":"system","content":"..."}
{"role":"user","content":"count the Zig files"}
{"role":"assistant","content":"{\"thought\":\"...\",\"action\":\"glob\",\"action_input\":\"...\"}"}
```

`role` 为 `system`、`user` 或 `assistant`。写入是**追加式**的，故一个文件累积该会话完整的来回往复，可按序回放。resume / 载入旧 transcript 是独立能力，不会因为文件命名修复而自动开启。

会话只是短期记忆。它不会跨运行被索引或汇总；持久化是为了可审计与可检视，而非用于回忆。

### 检视会话

可以用只读 CLI 命令检视已经持久化的会话文件，不会启动 agent：

```bash
scoot sessions list
scoot session show <id>
```

`sessions list` 会列出本地 session id、修改时间戳、消息数与首条用户消息摘要。`session show <id>` 会把该会话 transcript 以 JSONL 打印出来，便于继续 pipe 给其它工具。

## 审计日志

当 `[audit] to_file = true`（默认）时，每个有意义的步骤都会记入审计日志：

```text
~/.scoot/logs/audit.jsonl
```

每行一个事件：

```json
{"seq":0,"ts":1718600000123,"session_id":"cli-1718600000000-4242","kind":"run","msg":"goal: count the Zig files"}
{"seq":1,"ts":1718600000456,"session_id":"cli-1718600000000-4242","kind":"thought","msg":"..."}
{"seq":2,"ts":1718600000789,"session_id":"cli-1718600000000-4242","kind":"tool_call","msg":"glob {\"pattern\":\"**/*.zig\"}"}
{"seq":3,"ts":1718600000900,"session_id":"cli-1718600000000-4242","kind":"observation","msg":"..."}
{"seq":4,"ts":1718600001000,"session_id":"cli-1718600000000-4242","kind":"final","msg":"There are 23 Zig files."}
```

| 字段 | 含义 |
| --- | --- |
| `seq` | 单调递增的事件序号（每个 logger 实例从 0 起）。 |
| `ts` | 墙钟时间戳，Unix **毫秒**。 |
| `session_id` | 本地会话 id，用于把审计事件关联到 `state/sessions/<id>.jsonl`。 |
| `run_id` | 可选的更细粒度运行关联字段。 |
| `kind` | 事件类型（见下）。 |
| `msg` | 消息文本，密钥已脱敏。 |

### 事件类型

| `kind` | 何时写入 |
| --- | --- |
| `run` | 一次运行的起点，携带用户目标（在日志里分隔多次运行）。 |
| `thought` | 模型对某步的一句话推理。 |
| `tool_call` | 即将执行的动作及其输入。 |
| `observation` | 回灌给模型的工具结果。 |
| `final` | 终态答复。 |
| `policy_deny` | 被策略门拒绝的动作。 |
| `system_error` | 内部/可恢复错误。 |

`run` 标记让你把单个追加文件切分成一次次运行，`seq` + `ts` 让你回放时间线并关联事件。`policy_deny` 条目正是策略门拦截了什么的审计轨迹。

要查看某个会话对应的审计事件：

```bash
scoot audit show <session-id>
```

该命令会按 `session_id` 过滤 `logs/audit.jsonl`，并以 JSONL 打印匹配事件，保留 `seq`、`ts`、可选 `run_id`、`kind` 与 `msg`。

## 详细程度

用 `[audit] level` 控制记录量 —— `debug`、`info`（默认）、`warn` 或 `error`。设 `to_file = false` 可完全关闭文件日志。`max_retained_generations`（默认 `8`）限定已轮转的审计代最多保留多少个，超出后淘汰最旧的一个；见[留存](#留存)。

```toml
[audit]
level = "info"
to_file = true
max_retained_generations = 8
```

## 密钥绝不入日志

后端 token 的值**绝不**写入会话或审计日志 —— 只会报告其*来源*（由 `config`/`doctor`）。审计消息写入前先经脱敏。见 [Agent 指南](agent.md)的密钥规则。

## 留存

会话记录是追加式 JSONL 文件。单个会话文件达到内置大小上限后，Scoot 会在追加前把它轮转为 `.1`，避免 daemon 长跑时单文件无界增长；只保留最新一份备份。

审计日志采用了更稳健的方案，让未来的 `scoot-edge` audit 搬运器永远不会静默丢失某一段（issue #187）：`logs/audit.jsonl` 达到大小上限后，会被退休为一个单调编号的 `logs/audit.jsonl.<gen>`，而不是覆盖式的单一 `.1` 备份。代数计数器持久记录在 `logs/audit.jsonl.gen` sidecar 里，因此能在进程重启后存活。最多在磁盘上保留 `[audit] max_retained_generations`（默认 `8`）个已退休代；只有超过这个上限时才会淘汰最旧的一个，且每一次淘汰都会以 `{gap_from, gap_to, ts}` 的形式持久记录进 `logs/audit.jsonl.gaps.jsonl`，而不是悄悄消失。若曾记录过任何 gap，`scoot doctor` 会把 `audit.retention` 报告为 `WARN`，因此一个有界的保留上限永远不会变成一次看不见的丢失。
