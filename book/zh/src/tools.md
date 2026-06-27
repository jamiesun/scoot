# 内建工具

每个回合，模型必须给出恰好一个 JSON 步骤：

```json
{ "thought": "one-line reasoning", "action": "<action>", "action_input": "<input>" }
```

`action` 必须是下面十四个内建动作之一——Scoot 绝不执行
自由格式文本。每个工具都在带 **硬超时**（`tools.timeout_ms`，默认 30 秒）的沙盒中运行，
其输出作为下一个 *观察* 返回给模型（会被裁剪以保持上下文精简）。某个动作是否
被允许，取决于当前生效的 [执行策略](policy.md)。

结构化工具（`file_*`、`grep`、`glob`、`http_request`）**无需
外部命令**，因此在最小化/嵌入式系统上行为完全一致。优先使用它们，而非外壳调用。

## 动作概览

| 动作 | 用途 | `action_input` | 只读 |
| --- | --- | --- | --- |
| `bash` | 运行一条 POSIX shell 命令 | 命令字符串 | 否 |
| `file_read` | 读取文件 | `{"path":...}` | 是 |
| `file_write` | 覆盖/创建文件 | `{"path":...,"content":...}` | 否 |
| `file_edit` | 替换一段精确文本 | `{"path":...,"old":...,"new":...}` | 否 |
| `grep` | 在文件内做正则搜索 | `{"pattern":...,"path":...}` | 是 |
| `glob` | 按 glob 模式列出文件 | `{"pattern":...,"root":"."}` | 是 |
| `outline` | 文件结构骨架 | `{"path":...}` | 是 |
| `http_request` | 一次 HTTP/HTTPS 请求 | `{"method":...,"url":...,"body":...}` | 取决于方法 |
| `mcp_call` | 调用已配置 MCP server 的工具 | `{"server":...,"tool":...,"args":{...}}` | 否 |
| `wasm_tool` | 运行本地 compute-only Wasm 包 | `{"package":...,"input":{...}}` | 是 |
| `skill` | 读取已加载技能的文件 | `{"name":...,"path":"SKILL.md"}` | 是（原生） |
| `recall` | 搜索当前会话 transcript 归档 | `{"query":...}` 或 `{"seq":...}` | 是（原生） |
| `parallel` | 1–4 个并发只读调用 | `{"calls":[...]}` | 是 |
| `final` | 返回答复并停止 | 答复文本 | — |

---

## `bash`

在带硬超时的沙盒中、于 POSIX `sh`（`/bin/sh`）下运行一条 shell 命令。
`action_input` 是原始命令字符串；其合并输出成为下一个观察。

- **仅使用可移植的 POSIX 语法**——避免 bash 特有写法，如 `[[ ]]`、数组、
  花括号展开 `{1..10}` 或 `$'...'`。
- stdout 与 stderr 各自最多捕获 1 MiB；观察会被裁剪。
- 用于非交互、可自行终止的命令。**在 `readonly` 模式下被完全
  拒绝**，在 `guarded` 模式下会针对灾难性命令做筛查。

对于文件、搜索与 HTTP，优先使用结构化工具——`bash` 用于处理其他一切。

## `file_read`

```json
{ "path": "src/main.zig" }
```

读取一个文件（最多 1 MiB）并返回其内容。观察会被裁剪
到约 8 KB，以免大文件淹没上下文；对大文件请读取定向范围或使用
`grep`。在每种策略模式下都允许。

## `file_write`

```json
{ "path": "notes.txt", "content": "full new file contents" }
```

用 **完整** 的新内容覆盖文件（不存在则创建）。
这是一个变更性动作：**在 `readonly` 下被拒绝**，在 `guarded` 模式下可
通过 `confine_writes` 限制在项目根目录内。参见 [策略](policy.md)。

## `file_edit`

```json
{ "path": "README.md", "old": "exact unique text", "new": "replacement text" }
```

替换一段精确文本。**`old` 必须在文件中恰好出现一次**——若
不确定，先 `file_read` 查看精确文本。歧义或缺失的匹配会干净地
失败且不做任何更改。策略处理与 `file_write` 相同。

## `grep`

```json
{ "pattern": "fn main", "path": "src/main.zig" }
```

在单个文件内逐行做正则搜索；返回匹配的行号与
文本。支持的正则子集：`.` `^` `$` `*` `+` `?` `[]` `()` `|` `\d` `\w`
`\s`。**不** 支持：捕获组反向引用、环视、惰性
量词。只读；在每种模式下都允许。

可加可选的 `context`，同时返回**每个命中前后各 N 行**（类似 `grep -C`），
这样无需再整读文件即可理解命中点：

```json
{ "pattern": "fn main", "path": "src/main.zig", "context": 3 }
```

命中行标注为 `行号:原文`，上下文行标注为 `行号-原文`；相邻/重叠的命中会合并，
块之间以 `--` 分隔。`context` 会被夹到 `0..20`。

## `glob`

```json
{ "pattern": "src/**/*.zig", "root": "." }
```

列出 `root`（默认 `.`）下匹配某个 glob 的文件路径。`*` `?` `[]` 不
跨越 `/`；`**` 跨越目录层级。返回的路径可直接喂给
`file_read` 或 `grep`。只读；在每种模式下都允许。

## `outline`

```json
{ "path": "src/agent.zig" }
```

返回单个文件的紧凑**结构骨架**——函数与类型签名、Markdown 标题，
各自带行号——而不是整文件内容。先用它给陌生文件画出地图，再用
`file_read` 的 `offset`/`limit` 窗口读真正需要的片段；以此避免把大文件
整块灌进上下文。

语言识别是**零依赖的行启发式**（不引入 AST / 外部解析器，保持 Scoot
单一自包含二进制）：Zig 与 Markdown 走精确规则；其余语言回退到关键字
引导的启发式（`def`/`class`/`func`/`function`/`struct`/`type`/`interface`/…），
属 best-effort，可能漏掉类型引导的定义（如 C/C++）。输出上限 400 条
（超出即标注已截断）。只读；在每种模式下都允许。

## `http_request`

```json
{ "method": "GET", "url": "https://example.com/api", "body": "optional" }
```

发起一次带硬超时的 HTTP/HTTPS 请求（绝不挂起）。`method` 是
`GET`/`POST`/`PUT`/`DELETE`/`HEAD`/`PATCH` 之一；HTTPS 会自动协商
（自定义根证书参见 `backend.ca_file`）。返回响应状态与正文（最多
1 MiB，观察会被裁剪）。

策略处理按方法划分：读式（`GET`/`HEAD`）vs 写式
（其他一切）。**`readonly` 阻止网络变更**；`guarded` 可通过
`block_internal_http` 阻止内部/元数据主机。参见 [策略](policy.md)。

## `mcp_call`

```json
{ "server": "demo", "tool": "lookup", "args": { "query": "example" } }
```

调用一个已配置 MCP server 上的工具。server 配置位于 `[[mcp.servers]]`；
`server` 名称必须存在，`tool` 必须显式列在该 server 的 `allowed_tools` 中。
`allowed_tools` 为空会拒绝全部 MCP 工具。

当前支持 `stdio`、Streamable HTTP（`http` 或 `streamable_http`）以及 legacy
`sse` transport。远程 transport 使用配置中的 `url`，复用工具硬超时；如果配置了
`backend.ca_file`，也会复用该 CA bundle。基于 header 的认证按 server 配置
`headers`；token 请使用 `value_env`，可配合 `prefix` 生成 `Bearer ...`。

MCP 调用按可能具有外部副作用的执行处理。`readonly` 会拒绝它；`guarded` 与
`unrestricted` 仍要求显式 server 与工具 allowlist。MCP 调用像其他工具一样进入审计，
并受同一个硬超时约束。

## `wasm_tool`

```json
{ "package": "examples/wasm-plugin-template", "input": { "expr": "1+2" } }
```

通过配置好的 `scoot-wasm` host 运行一个本地 Wasm 工具包，不经过 shell。
工具包必须通过同一套 `scoot wasm-tools check` 边界，使用 WASI command 入口
（`entry = "_start"`），并且 `policy.toml` 只能授予 `compute`。模型只提供包路径
和 JSON 输入；host argv 是可信运行时配置，不来自模型。

在 `guarded` 与 `readonly` 下，包路径必须是项目相对路径，不能包含绝对路径、
`..`、`~` 或 `$` 展开。当前 host 表面只有 stdio/args/environ/clock/random/proc-exit，
不会授予文件系统、网络或宿主环境变量访问。Wasm 工具足够时，用它替代通过 `bash`
拼命令。

## `skill`

```json
{ "name": "demo", "path": "SKILL.md" }
```

从 **已加载技能的** 目录中读取一个文件——`path` 默认为 `SKILL.md`，
也可指向另一个资源，如 `references/guide.md`。这是一个 **原生、
按设计绕过执行策略的只读能力**，因此即使在 `readonly`（`bash` 被拒绝）下技能仍可使用。

安全位于执行层而非策略层：读取被限制在指定技能的
目录内（绝对路径与 `..` 被拒绝），名称必须在已加载集合中
（未知名称返回一个可恢复的观察，列出可用项），并且
每次读取都被审计。内容最多返回约 32 KB。参见 [技能](skills.md)。

## `recall`

```json
{ "query": "old error text", "limit": 8 }
```

```json
{ "seq": 12, "context": 2 }
```

搜索 **当前会话的完整 transcript 归档**，返回带 `seq`、`role` 与
`content` 的 JSONL 风格原文消息行。这是原生只读能力，因此在 `readonly`
模式下也可用。

当上下文压缩只保留摘要，而模型需要较早的精确观察、命令或用户指令时使用它。
`query` 做字面量子串匹配；`seq` 从 1 开始，可带少量前后 `context`。
`limit` 会被封顶，避免召回结果重新撑爆上下文。

## `parallel`

```json
{ "calls": [
  { "action": "file_read", "input": "{\"path\":\"README.md\"}" },
  { "action": "grep", "input": "{\"pattern\":\"Scoot\",\"path\":\"AGENT.md\"}" }
] }
```

并发运行 **1–4 个独立的只读调用**，保留观察
顺序。仅允许 `file_read`、`grep`、`glob`、`outline` 与 HTTP `GET`/`HEAD`——
`bash`、写入、`skill`、`recall` 与嵌套的 `parallel` 都被拒绝。每个子调用
仍会经过正常的策略门。用它在一个回合中并行扇出独立的读取。

## `final`

`action_input` 是给用户的答复文本。给出 `final` 即结束 ReACT
循环。在 `-e` 模式下，这段文本就是打印到 stdout 的内容。

## 观察与截断

工具输出会作为观察反馈，但每个都会被 **裁剪** 以约束
上下文增长（大致为：`bash` ~2 KB，`file_read`/`http_request` ~8 KB，
`parallel` ~12 KB，`skill` ~32 KB，`recall` ~16 KB）。对于大数据，请收窄
你的读取——使用 `grep`、glob 路径、定向范围，或更精确的 `recall` 查询，
而不是倾倒整个文件。
