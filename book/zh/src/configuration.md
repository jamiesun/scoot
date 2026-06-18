# 配置

Scoot 从其运行目录读取配置，并在缺失时回退到内置默认值，因此零配置即可运行。本页是
每个配置节与配置键的完整参考。

## 文件位置与加载顺序

运行目录默认是 `~/.scoot`。可用 `--scoot-home`（最高优先级）或
`SCOOT_HOME` 环境变量覆盖。

在该目录内，配置按以下顺序加载：

1. `config.toml`
2. `config.json`
3. 内置默认值

**合并语义：** 加载是 **按节、按字段** 进行的。任何缺失的节或字段都回退到其内置默认值，
并且 **未知字段会被忽略**。这意味着部分配置始终有效——你只需指定想要改动的部分。
从 [`config.example.toml`](https://github.com/jamiesun/scoot/blob/main/config.example.toml) 开始。

随时运行 `scoot config` 可打印 *解析出的* 运行目录与后端配置（密钥已脱敏）。

## 环境变量覆盖

每个非密钥配置字段都可被 `SCOOT_*` 环境变量覆盖。该覆盖层在 **内存中** 应用，优先级为：

```text
SCOOT_* 环境变量  >  config.toml / config.json  >  内置默认值
```

无论配置文件是否存在，**环境变量始终胜出**，因此你可以在 **完全没有配置文件** 的情况下运行
Scoot——把 `SCOOT_HOME` 指向一个临时目录，所有配置经环境变量传入即可。这非常适合 CI 以及
跑完即焚的一次性执行。

| 环境变量 | 覆盖 | 类型 |
| --- | --- | --- |
| `SCOOT_BACKEND_BASE_URL` | `backend.base_url` | 字符串 |
| `SCOOT_BACKEND_MODEL` | `backend.model` | 字符串 |
| `SCOOT_BACKEND_API_KEY_ENV` | `backend.api_key_env` | 字符串（指明持有 token 的变量名） |
| `SCOOT_BACKEND_API_KEY_FILE` | `backend.api_key_file` | 字符串 |
| `SCOOT_BACKEND_API_KEY_CMD` | `backend.api_key_cmd` | 字符串 |
| `SCOOT_BACKEND_CA_FILE` | `backend.ca_file` | 字符串 |
| `SCOOT_BACKEND_EXTRA_BODY` | `backend.extra_body` | JSON 对象 |
| `SCOOT_AGENT_DEFAULT_MODE` | `agent.default_mode` | 字符串（`goal`/`plan`） |
| `SCOOT_AGENT_MAX_TURNS` | `agent.max_turns` | 整数 |
| `SCOOT_AGENT_CONTEXT_BUDGET_BYTES` | `agent.context_budget_bytes` | 整数 |
| `SCOOT_TOOLS_POLICY` | `tools.policy` | 字符串（`guarded`/`readonly`/`unrestricted`） |
| `SCOOT_TOOLS_TIMEOUT_MS` | `tools.timeout_ms` | 整数 |
| `SCOOT_TOOLS_CONFINE_WRITES` | `tools.confine_writes` | 布尔（`true`/`false`/`1`/`0`） |
| `SCOOT_TOOLS_BLOCK_INTERNAL_HTTP` | `tools.block_internal_http` | 布尔 |
| `SCOOT_SKILLS_ENABLED` | `skills.enabled` | 布尔 |
| `SCOOT_AUDIT_LEVEL` | `audit.level` | 字符串 |
| `SCOOT_AUDIT_TO_FILE` | `audit.to_file` | 布尔 |

说明：

- **空值**（`""`）视为 *未设置*，不会覆盖默认值——便于 CI 中的可选输入。
- **类型错误** 的值（例如给 `SCOOT_AGENT_MAX_TURNS` 传非整数）会被 **忽略**，字段保留原值，
  并向 **stderr** 打印告警（绝不写 stdout，从而保证 `-e` 管道输出干净）。
- **绝不从 `SCOOT_*` 直接读取密钥。** token 仍只来自 `backend.api_key_env` 指明的来源
  （默认 `OPENAI_API_KEY`），遵循下文 [密钥](#密钥) 铁律。`SCOOT_BACKEND_API_KEY_ENV`
  只改变 *查询哪个* 变量，而非 token 本身。

### 在 GitHub Actions 中零配置运行

把 token 存为 GitHub **secret**，其余经 `env` 传入。无需提交或写出 `config.toml`；运行目录
在 runner 临时空间下即时创建，随任务一并销毁。

```yaml
jobs:
  ask:
    runs-on: ubuntu-latest
    env:
      SCOOT_HOME: ${{ runner.temp }}/scoot
      OPENAI_API_KEY: ${{ secrets.LLM_KEY }}        # token 值（机密）
      SCOOT_BACKEND_API_KEY_ENV: OPENAI_API_KEY     # 由哪个变量持有
      SCOOT_BACKEND_BASE_URL: https://api.openai.com/v1
      SCOOT_BACKEND_MODEL: gpt-4o-mini
      SCOOT_TOOLS_POLICY: readonly                  # CI 的安全默认
    steps:
      - uses: actions/checkout@v4
      - name: Install scoot
        run: |
          # 下载对应平台的 release 资产，然后：
          install -m755 scoot /usr/local/bin/scoot
      - name: Ask
        run: scoot -e "总结本仓库的最新改动"
```

`scoot -e` 会检查 `SCOOT_HOME`：目录不存在则用内置默认创建；已存在则在其之上叠加 `SCOOT_*`
覆盖。无论哪种情况，密钥都不会落盘。

## 配置节概览

| 配置节 | 用途 |
| --- | --- |
| `[backend]` | LLM 端点、模型、API key 来源、TLS、额外请求字段 |
| `[agent]` | ReACT 回合上限、认知模式、上下文预算 |
| `[tools]` | 工具超时、执行策略、可选加固 |
| `[skills]` | 技能发现开关与额外搜索路径 |
| `[audit]` | 审计日志级别与文件输出 |
| `[schedule]` | 无人值守的调度任务与轮询间隔 |

---

## `[backend]`

LLM 后端。Scoot **只** 讲 OpenAI 兼容的 `chat/completions` 协议。

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `base_url` | string | `http://127.0.0.1:11434/v1` | OpenAI 兼容端点的基础 URL。 |
| `model` | string | `qwen2.5` | 发送给后端的模型名。 |
| `api_key_env` | string | `OPENAI_API_KEY` | 作为 **第一** token 来源的环境变量名。 |
| `api_key_file` | string? | unset → `~/.scoot/token` | `0600` token 文件的路径。在环境变量来源之后使用。 |
| `api_key_cmd` | string? | unset | 打印 token 的命令（如 `pass show openai`）。最后使用。 |
| `ca_file` | string? | unset → system roots | 用于 HTTPS 的 PEM CA bundle。在缺少根证书的系统上设置它。 |
| `extra_body` | table? | unset | 合并进每个请求的额外顶层 JSON 字段。 |

### `[backend.extra_body]`

一个直通表，原样合并进顶层 `chat/completions` JSON。
用它来传递后端专有或较新的字段而无需重新编译——例如
`reasoning_effort`、`service_tier`、`top_p`。只接受 JSON **对象**；
非对象值会被忽略。**绝不要把密钥放在这里**，也不要覆盖
`model` 或 `messages` 等核心字段。

```toml
[backend]
base_url = "https://api.openai.com/v1"
model    = "gpt-4o-mini"
api_key_env = "OPENAI_API_KEY"

[backend.extra_body]
top_p = 0.9
reasoning_effort = "high"
```

---

## `[agent]`

认知引擎。

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `max_turns` | u32 | `32` | agent 停止前的最大 ReACT 回合数，用于约束失控循环。 |
| `default_mode` | string | `goal` | 认知模式。`goal` 现已实现；`plan` 是保留项（见路线图），目前尚不改变执行。 |
| `context_budget_bytes` | usize | `0` | 累积的提示历史预算，单位 **字节**。`0` 表示禁用。 |

**`context_budget_bytes`** 用于保护小上下文后端。当运行中的对话记录将超过该大小时，
agent 会在下一次后端调用 *之前* 以清晰的错误停止，而不是让请求无限增长并在后期失败。
字节是 token 的粗略代理——选一个低于后端上下文窗口的保守值（回合数仍由 `max_turns` 约束）。

```toml
[agent]
max_turns = 32
default_mode = "goal"
context_budget_bytes = 0          # e.g. 120000 for a ~32k-token backend
```

---

## `[tools]`

工具沙盒与执行策略。完整模型参见 [执行策略与安全](policy.md)。

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `timeout_ms` | u64 | `30000` | **每一次** 工具调用的硬超时，单位毫秒。 |
| `policy` | string | `guarded` | 执行策略：`guarded`、`readonly` 或 `unrestricted`（别名 `yolo`）。未知值回退到 `guarded`。 |
| `confine_writes` | bool | `false` | 可选项：把 `file_write`/`file_edit` 限制在项目根目录内。**仅 `guarded`。** |
| `block_internal_http` | bool | `false` | 可选项：阻止 `http_request` 访问内部/元数据主机（SSRF 防护）。**仅 `guarded`。** |

两个加固标志 **仅在 `guarded` 模式下生效**——`readonly` 已经
fail-closes 写入与网络。`confine_writes` 拒绝绝对路径、`..`
逃逸，以及 shell 风格的 `~`/`$VAR` 展开。`block_internal_http` 是一个
基于字面 IP 范围与已知内部名称的启发式判断；它 **不** 解析 DNS，因此 DNS 重绑定仍可绕过它——
若需真正隔离，请使用 `readonly` 或网络沙盒。

```toml
[tools]
timeout_ms = 30000
policy = "guarded"
confine_writes = false
block_internal_http = false
```

---

## `[skills]`

本地技能发现。参见 [技能](skills.md)。

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | 启用技能发现与注入。 |
| `extra_paths` | list of string | `[]` | 额外的技能搜索路径，追加在内置路径之后。 |

技能按 **优先级顺序** 发现（名称冲突时靠前者胜出）：

1. `<cwd>/.agents/skills`——项目本地，随仓库一起携带。
2. `~/.agents/skills`——跨 agent 的用户级技能（独立于 `SCOOT_HOME`）。
3. `~/.scoot/skills`——Scoot 自有的用户级目录。
4. 此处列出的 `extra_paths`。

读取技能的指令是一种原生只读能力，即使在 `readonly` 模式下也可工作；技能随后让模型运行的内容仍受策略门控。

```toml
[skills]
enabled = true
extra_paths = ["/opt/scoot/skills", "./skills"]
```

---

## `[audit]`

审计日志。参见 [会话与审计](sessions.md)。

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `level` | string | `info` | 详尽程度：`debug`、`info`、`warn` 或 `error`。 |
| `to_file` | bool | `true` | 将审计日志写入 `~/.scoot/logs/audit.jsonl`。 |

```toml
[audit]
level = "info"
to_file = true
```

---

## `[schedule]`

无人值守的调度任务。**默认禁用**——自主执行必须显式开启。参见 [调度与守护进程](scheduling.md)。

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | 启用调度器 / 守护进程循环。 |
| `poll_ms` | u64 | `1000` | 调度器轮询间隔，单位毫秒。 |
| `jobs` | list of table | `[]` | 调度任务定义（见下文）。 |

### `[[schedule.jobs]]`

每个任务是一个 array-of-tables 条目，带 **恰好一个** 触发器。

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `id` | string | — | 稳定的任务标识符（必填）。 |
| `goal` | string | `""` | agent 运行的自然语言目标。 |
| `every_sec` | u64? | unset | 触发器：固定间隔，单位秒。 |
| `at_unix` | i64? | unset | 触发器：一个固定的 Unix 时间点。 |
| `cron` | string? | unset | 触发器：cron 表达式——**已解析但尚不支持**。 |
| `mode` | string | `readonly` | 执行策略：`readonly`（默认，安全）或 `unrestricted`。 |

`every_sec` / `at_unix` / `cron` 中必须设置 **恰好一个**；否则该任务无效并被跳过并伴随警告
（在 `schedule list` 中显示为 `INACTIVE`）。在 cron 支持落地之前，`cron` 任务永远不会触发。

**安全：** 调度任务默认 `readonly`，且 `guarded` 在执行时会被矫正为等效
`readonly`。仅在你刻意接受无人值守的写入/网络风险时才使用 `unrestricted`。

```toml
[schedule]
enabled = true
poll_ms = 1000

[[schedule.jobs]]
id = "disk-check"
goal = "Inspect disk usage and summarize anomalies"
every_sec = 300
mode = "readonly"

[[schedule.jobs]]
id = "morning-brief"
goal = "Prepare today's task brief"
at_unix = 1893456000
mode = "readonly"
```

---

## 密钥

**绝不要把明文 API key 放进 `config.toml`/`config.json`。** Scoot 从三个来源解析
后端 token，按顺序尝试：

1. **环境变量**，由 `backend.api_key_env`（默认 `OPENAI_API_KEY`）命名。
2. **token 文件**，位于 `backend.api_key_file`，未设置时为 `~/.scoot/token`。该
   文件 **必须是 `0600` 权限**；若权限过于开放，Scoot 拒绝读取。
3. **凭证命令**，位于 `backend.api_key_cmd`（如 `pass show openai`）。
   请保持其有界且非交互。

解析出的值绝不会回写磁盘、被 `config`/`doctor` 打印，
或被记录进审计日志——只报告其 *来源*。密钥处理的铁律参见 [Agent
指南](agent.md)。

```sh
# Source 1 — environment:
export OPENAI_API_KEY="sk-..."

# Source 2 — private token file:
umask 077
printf '%s' "sk-..." > ~/.scoot/token

# Source 3 — credential command (in config):
#   api_key_cmd = "pass show openai"
```

## JSON 配置

如果你偏好 JSON，可在运行目录中创建 `config.json`（仅在
`config.toml` 缺失时使用）。其结构与 TOML 各节一一对应：

```json
{
  "backend": { "base_url": "https://api.openai.com/v1", "model": "gpt-4o-mini" },
  "agent":   { "max_turns": 32 },
  "tools":   { "policy": "guarded", "timeout_ms": 30000 }
}
```

## 带注释的示例

仓库附带一份完整注释的 [`config.example.toml`](https://github.com/jamiesun/scoot/blob/main/config.example.toml)。
复制它并编辑：

```sh
cp config.example.toml ~/.scoot/config.toml
```
