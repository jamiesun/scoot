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
| `SCOOT_BACKEND_TIMEOUT_MS` | `backend.timeout_ms` | 整数 |
| `SCOOT_BACKEND_API_KEY_ENV` | `backend.api_key_env` | 字符串（指明持有 token 的变量名） |
| `SCOOT_BACKEND_API_KEY_FILE` | `backend.api_key_file` | 字符串 |
| `SCOOT_BACKEND_API_KEY_CMD` | `backend.api_key_cmd` | 字符串 |
| `SCOOT_BACKEND_CA_FILE` | `backend.ca_file` | 字符串 |
| `SCOOT_BACKEND_STORE` | `backend.store` | 布尔（`true`/`false`/`1`/`0`） |
| `SCOOT_BACKEND_EXTRA_BODY` | `backend.extra_body` | JSON 对象 |
| `SCOOT_AGENT_DEFAULT_MODE` | `agent.default_mode` | 字符串（`goal`/`plan`） |
| `SCOOT_AGENT_COMPACTOR` | `agent.compactor` | 字符串（`drop`/`extractive`/`plugin:<name>`） |
| `SCOOT_AGENT_MAX_TURNS` | `agent.max_turns` | 整数 |
| `SCOOT_AGENT_CONTEXT_BUDGET_BYTES` | `agent.context_budget_bytes` | 整数 |
| `SCOOT_TOOLS_POLICY` | `tools.policy` | 字符串（`guarded`/`readonly`/`unrestricted`） |
| `SCOOT_TOOLS_TIMEOUT_MS` | `tools.timeout_ms` | 整数 |
| `SCOOT_TOOLS_CONFINE_WRITES` | `tools.confine_writes` | 布尔（`true`/`false`/`1`/`0`） |
| `SCOOT_TOOLS_BLOCK_INTERNAL_HTTP` | `tools.block_internal_http` | 布尔 |
| `SCOOT_SKILLS_ENABLED` | `skills.enabled` | 布尔 |
| `SCOOT_SKILLS_INCLUDE_PROJECT_SKILLS` | `skills.include_project_skills` | 布尔 |
| `SCOOT_SKILLS_INCLUDE_AGENTS_SKILLS` | `skills.include_agents_skills` | 布尔 |
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
| `[agent]` | ReACT 回合上限、认知模式、上下文预算、压缩插件 |
| `[tools]` | 工具超时、执行策略、guarded 加固 |
| `[skills]` | 技能发现开关与额外搜索路径 |
| `[mcp]` | `mcp_call` 可调用的外部 MCP server 声明 |
| `[audit]` | 审计日志级别与文件输出 |
| `[schedule]` | 无人值守的调度任务与轮询间隔 |

---

## `[backend]`

LLM 后端。Scoot **只** 讲 OpenAI 兼容 Responses API（`/v1/responses`）。
默认情况下，Scoot 每回合都会重发完整 `input`，以保持本地上下文压缩有效，并约束
token 用量。

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `base_url` | string | `http://127.0.0.1:11434/v1` | OpenAI 兼容端点的基础 URL。 |
| `model` | string | `qwen2.5` | 发送给后端的模型名。 |
| `api_key_env` | string | `OPENAI_API_KEY` | 作为 **第一** token 来源的环境变量名。 |
| `timeout_ms` | u64 | `120000` | 单次后端 Responses API 调用的硬超时，单位毫秒。`0` 会被矫正为内建默认值，绝不表示“无 deadline”。 |
| `api_key_file` | string? | unset → `~/.scoot/token` | `0600` token 文件的路径。在环境变量来源之后使用。 |
| `api_key_cmd` | string? | unset | 打印 token 的命令（如 `pass show openai`）。最后使用。它会由 Scoot 执行，因此应视为可信配置。 |
| `ca_file` | string? | unset → system roots | 用于 HTTPS 的 PEM CA bundle。在缺少根证书的系统上设置它。 |
| `store` | bool | `false` | 通过 Responses API 的 `store` 标志请求后端在服务端持久化响应。默认关闭，以保持 scoot 无状态、本地优先。 |
| `extra_body` | table? | unset | 合并进每个请求的额外顶层 JSON 字段。 |

### `[backend.extra_body]`

一个直通表，原样合并进顶层模型请求 JSON。
用它来传递后端专有或较新的字段而无需重新编译——例如
`reasoning_effort`、`service_tier`、`top_p`。只接受 JSON **对象**；
非对象值会被忽略。**绝不要把密钥放在这里**，也不要覆盖
`model`、`messages` 或 `input` 等核心字段。

```toml
[backend]
base_url = "https://api.openai.com/v1"
model    = "gpt-4o-mini"
# store = false
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
| `compactor` | string | `extractive` | 上下文压缩策略：`extractive` 写入确定式纪要；`drop` 保持旧的计数标记；`plugin:<name>` 运行外部压缩器包。 |
| `context_budget_bytes` | usize | `80000` | 累积的提示历史预算，单位 **字节**。`0` 表示禁用。 |
| `compactor_plugin` | table | unset | 按名称组织的动态插件配置，位于 `[agent.compactor_plugin.<name>]`。 |

**`context_budget_bytes`** 用于保护小上下文后端。当运行中的对话记录将超过该大小时，
agent 会先按 `agent.compactor` **压缩历史**。默认 `extractive` 会写入确定式导航纪要，
例如读过/改过的文件、命令与退出码、策略拒绝和明显的 TODO 观察。`drop` 是最小兜底行为：
把更早的工具记录替换为计数标记。`plugin:<name>` 会先运行已配置的外部压缩器；若包无效、
策略拒绝、超时、输出格式错误，或生成的 marker 仍会超预算，则回退到 `extractive` 再到
`drop`。仅当压缩后对话记录仍超预算
（预算过小、连最小保留集都放不下）时，才在下一次后端调用 *之前* 以清晰的错误 fail-fast。
字节是 token 的粗略代理；默认值只是可靠性护栏，不是精确模型窗口保证。应把它设为低于后端
上下文窗口的保守值，或设为 `0` 显式关闭（回合数仍由 `max_turns` 约束）。

```toml
[agent]
max_turns = 32
default_mode = "goal"
compactor = "extractive"          # 或 "drop"
context_budget_bytes = 80000      # 0 表示关闭；按后端窗口调小
```

### `[agent.compactor_plugin.<name>]`

外部压缩插件复用 Wasm 工具包的静态描述符边界，但 `manifest.toml` 必须设置
`kind = "compressor"`。Scoot 不内嵌 Wasm runtime；压缩由有界子进程完成。插件从 stdin
接收 JSON `CompactionRequest`，并在 stdout 输出类似 `{"marker":"..."}` 的 JSON 对象。

包策略只能授予 `compute`。任何非 `compute` 能力、坏输出、超时、非零退出码或超预算 marker
都会被判为不可用，并进入内置回退链。

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `package` | string | 必填 | 由 `wasm_tool.validatePackage` 校验的目录。 |
| `host` | list of string | unset | 命令 argv 模板。占位符：`{package}`、`{component}`、`{entry}`。若未设置，Scoot 尝试 `{package}/{entry}`。 |
| `timeout_ms` | u64? | `tools.timeout_ms` | 子进程硬超时。`0` 会被矫正为内建默认值，绝不表示“无 deadline”。 |
| `stdout_limit` | usize? | `1048576` | 接受的最大 stdout 字节数。 |
| `stderr_limit` | usize? | `262144` | 接受的最大 stderr 字节数。 |

如果可选的独立 host 已安装在 `PATH` 上，可直接使用 `scoot-wasm wasi {component}`
（否则把 `scoot-wasm` 换成绝对路径）：

```toml
[agent]
compactor = "plugin:tiny"

[agent.compactor_plugin.tiny]
package = "/opt/scoot/compressors/tiny"
host = ["scoot-wasm", "wasi", "{component}"]
timeout_ms = 30000
stdout_limit = 1048576
stderr_limit = 262144
```

---

## `[tools]`

工具沙盒与执行策略。完整模型参见 [执行策略与安全](policy.md)。

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `timeout_ms` | u64 | `30000` | **每一次** 工具调用的硬超时，单位毫秒。 |
| `policy` | string | `guarded` | 执行策略：`guarded`、`readonly` 或 `unrestricted`（别名 `yolo`）。未知值回退到 `guarded`。 |
| `confine_writes` | bool | `true` | 把 `file_write`/`file_edit` 限制在项目根目录内。**仅 `guarded`。** |
| `block_internal_http` | bool | `true` | 阻止 `http_request` 访问内部/元数据主机（SSRF 防护）。**仅 `guarded`。** |
| `wasm_host` | 字符串数组 | `["scoot-wasm", "wasi", "{component}"]` | `wasm_tool` 使用的可信 argv。使用默认值时，Scoot 会先尝试与当前 `scoot` 二进制同目录的 `scoot-wasm`，找不到再回退 PATH。占位符：`{package}`、`{entry}`、`{component}`。 |

两个加固标志 **仅在 `guarded` 模式下生效**——`readonly` 已经
fail-closes 写入与网络。`confine_writes` 拒绝绝对路径、`..`
逃逸，以及 shell 风格的 `~`/`$VAR` 展开。`block_internal_http` 是一个
基于字面 IP 范围与已知内部名称的启发式判断；它 **不** 解析 DNS，因此 DNS 重绑定仍可绕过它——
若需真正隔离，请使用 `readonly` 或网络沙盒。

```toml
[tools]
timeout_ms = 30000
policy = "guarded"
confine_writes = true
block_internal_http = true
wasm_host = ["./zig-out/bin/scoot-wasm", "wasi", "{component}"]
```

### `[tools.policy_hook]`（可选）

可选的外部策略钩子，在内建策略门放行某个 action *之后* 被咨询；它只能把 `allow` 收紧为 `deny`，永不放松内建的 deny，任何错误都 fail-closed 拒绝。未设置 `package` 即不启用。参见 [执行策略](policy.md#策略钩子可选纵深防御)。

| 键 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `package` | string | _(空)_ | 本地 Wasm 工具包（manifest kind 为 `policy`，仅 `compute`）。为空表示不启用钩子。 |
| `host` | 字符串数组 | 解析后的 `wasm_host` | argv 模板。占位符：`{package}`、`{entry}`、`{component}`。 |
| `timeout_ms` | u64 | `tools.timeout_ms` | 钩子每次调用的硬超时。 |

```toml
[tools.policy_hook]
package = "/opt/scoot/policy/org-guard"
host = ["scoot-wasm", "wasi", "{component}"]
timeout_ms = 5000
```

---

## `[skills]`

本地技能发现。参见 [技能](skills.md)。

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | 启用技能发现与注入。 |
| `include_project_skills` | bool | `false` | 是否加载 `<cwd>/.agents/skills` 这个随仓库携带的项目技能目录。仅对可信仓库开启。 |
| `include_agents_skills` | bool | `false` | 是否加载 `~/.agents/skills` 这个跨 agent 的用户级技能目录。 |
| `extra_paths` | list of string | `[]` | 额外的技能搜索路径，追加在内置路径之后。 |

技能按 **优先级顺序** 发现（名称冲突时靠前者胜出）：

1. `<cwd>/.agents/skills`——项目本地，仅在 `include_project_skills=true` 时加载。
2. `~/.agents/skills`——跨 agent 的用户级技能，仅在 `include_agents_skills=true` 时加载。
3. `~/.scoot/skills`——Scoot 自有的用户级目录。
4. 此处列出的 `extra_paths`。

项目本地技能默认关闭，因为仓库可以携带不可信指令。只应在可信工作区内显式开启。

读取技能的指令是一种原生只读能力，即使在 `readonly` 模式下也可工作；技能随后让模型运行的内容仍受策略门控。

```toml
[skills]
enabled = true
include_project_skills = false
include_agents_skills = false
extra_paths = ["/opt/scoot/skills", "./skills"]
```

---

## `[mcp]`

外部 Model Context Protocol server 声明，通过 `mcp_call` 这个元动作调用。Scoot
这里只做 MCP client：启动或连接已配置的 server 并调用其工具，不对外暴露 MCP server。

调用默认 fail-closed。目标 `server` 必须存在于 `[[mcp.servers]]`，请求的 `tool`
也必须出现在 `allowed_tools`；`allowed_tools` 为空表示拒绝所有工具。`readonly`
策略会完全拒绝 `mcp_call`，因为外部 MCP 工具可能绕过 Scoot 静态工具分类去读写文件或访问网络。
`guarded` 与 `unrestricted` 仍然要求显式 server 与工具 allowlist。

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `servers` | array | `[]` | MCP server 声明列表。 |

每个 `[[mcp.servers]]` 条目：

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `name` | string | `""` | `mcp_call.server` 使用的名称。 |
| `transport` | string | `stdio` | 支持 `stdio`、Streamable HTTP（`http` / `streamable_http`）和 legacy `sse`。 |
| `command` | string | `""` | stdio transport 要启动的命令。 |
| `args` | list of string | `[]` | 传给 `command` 的参数。 |
| `env` | list of `{ name, value }` | `[]` | 子进程环境覆盖块。若设置，请包含子进程需要的一切变量，例如 `PATH`。 |
| `allowed_tools` | list of string | `[]` | 显式工具 allowlist。为空即拒绝全部。 |
| `policy` | string | `readonly` | 用于审计和未来策略扩展的 server 姿态声明。 |
| `url` | string? | 未设置 | HTTP/SSE transport 的远程端点 URL。 |
| `headers` | header object 列表 | `[]` | 远程 transport 的额外 HTTP header。密钥请用 `value_env`。 |

Header object 支持 `name`、`value`/`value_env` 二选一，以及可选 `prefix`。
`Accept`、`Content-Type`、`MCP-Protocol-Version`、`Mcp-Session-Id` 等协议头由
Scoot 管理，不能覆盖。`value_env` 缺失或为空时，调用会 fail-closed。

```toml
[[mcp.servers]]
name = "demo"
transport = "stdio"
command = "/path/to/mcp-server"
args = ["--flag", "value"]
env = [{ name = "SERVER_MODE", value = "readonly" }]
allowed_tools = ["lookup", "read_resource"]
policy = "readonly"

[[mcp.servers]]
name = "remote-demo"
transport = "http"
url = "https://example.com/mcp"
allowed_tools = ["lookup"]
headers = [
  { name = "Authorization", value_env = "REMOTE_MCP_TOKEN", prefix = "Bearer " },
]

[[mcp.servers]]
name = "legacy-sse-demo"
transport = "sse"
url = "https://example.com/sse"
allowed_tools = ["lookup"]
headers = [
  { name = "X-API-Key", value_env = "REMOTE_MCP_API_KEY" },
]
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

### `[audit.hook]`（可选）

可选的 PostToolUse 式可观测性钩子。当一个工具 action 完成后 —— 无论是被放行并执行，
还是被策略闸门拒绝 —— 它都会收到一条结构化 JSON 事件，可转发给外部 SIEM、分析管线或
组织审计引擎。与[策略钩子](#toolspolicy_hook可选)一样，它把事件送入同样经过 realpath
校验的 Wasm 数据转换边界（manifest kind 为 `audit`，仅 `compute` 能力），而非裸 shell 调用。
它是纯**观测性**的：永不参与放行/拒绝判定，没有 allow/deny 返回；投递是**尽力而为**的 ——
任何失败（包缺失/非法、kind 错误、非 compute 能力、spawn 失败、超时、输出过大、非零退出）
都会被计数并在 flush 时作为警告呈现，绝不影响本次运行。仅当设置了 `package` 时启用。

| 键 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `package` | string | _(空)_ | 本地 Wasm 工具包（manifest kind 为 `audit`，仅 `compute`）。为空表示不启用钩子。 |
| `host` | string array | 解析后的 `wasm_host` | argv 模板。占位符：`{package}`、`{entry}`、`{component}`。 |
| `timeout_ms` | u64 | `tools.timeout_ms` | 钩子单次调用的硬超时。 |

事件是写入钩子 stdin 的每行一个 JSON 对象：

```json
{"version":1,"kind":"observation","session_id":"cli-...","action":"bash","input":"<工具输入>","observation":"<工具结果>","mode":"guarded"}
```

`kind` 为 `observation` 表示已执行的工具，`policy_deny` 表示被拦截的工具。

```toml
[audit.hook]
package = "/opt/scoot/audit/org-sink"
host = ["scoot-wasm", "wasi", "{component}"]
timeout_ms = 5000
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
| `cron` | string? | unset | 触发器：5 字段 UTC cron 表达式。 |
| `mode` | string | `readonly` | 执行策略：`readonly`（默认，安全）或 `unrestricted`。 |

`every_sec` / `at_unix` / `cron` 中必须设置 **恰好一个**；否则该任务无效并被跳过并伴随警告。
cron 支持分钟/小时/日/月/周字段，以及 `*`、逗号列表、范围和 `/step`。

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
