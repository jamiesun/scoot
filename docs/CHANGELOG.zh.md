# 更新日志

本文件记录项目的所有重要变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
并遵循[语义化版本](https://semver.org/lang/zh-CN/spec/v2.0.0.html)。

版本号的唯一事实源是
[`build.zig.zon`](../build.zig.zon)；发布流程会把某个 tag 对应的小节转换为
GitHub release 的发布说明（参见
[`.github/workflows/release.yml`](../.github/workflows/release.yml)）。请在文件顶部保留
`Unreleased` 小节，发布时将其内容移动到新的 `## [X.Y.Z]` 标题下。

English version: [CHANGELOG.md](../CHANGELOG.md)。

## [未发布]

### 新增

- Release workflow 现在会为每个支持目标发布带 `-small` 后缀的
  `ReleaseSmall` 产物。
- 安装脚本支持 `SCOOT_INSTALL_FLAVOR=small`，可选择 small release 产物，
  而不是默认的 `ReleaseSafe` 产物。
- 新增原生 `recall` 动作，可在活跃上下文压缩后，从当前会话 transcript
  归档中取回较早的精确原文消息（#99）。
- 稳定嵌入 API 现在把公共包根与 CLI/internal 模块分离，并加入会随测试编译的
  最小嵌入示例（#106）。
- 新增 `backend.store` 配置项与 `SCOOT_BACKEND_STORE` 覆盖，可选择让后端通过
  Responses API 在服务端持久化响应；默认关闭，以保持 Scoot 无状态、本地优先（#110）。
- 新增 client-side MCP 支持：通过受策略门控的 `mcp_call` 元动作与
  `[[mcp.servers]]` 配置调用外部 MCP server。当前 client 支持 stdio、Streamable
  HTTP 与 legacy SSE transport，并复用同一配置与策略接缝；远程 server 支持基于
  环境变量取值的 per-server header 认证（#103）。
- 新增外部上下文压缩插件：可通过 `agent.compactor = "plugin:<name>"`
  选择，并在 `[agent.compactor_plugin.<name>]` 下配置。插件包复用
  `wasm_tool` 描述符边界，使用 `kind = "compressor"`，执行时作为有界子进程运行，
  失败则回退到 `extractive`/`drop`（#98）。

### 变更

- Scoot 现在只讲 OpenAI Responses API（`/v1/responses`）：起始 system 消息映射为
  顶层 `instructions` 字段，其余进入 `input` 数组，且传输默认无状态（每轮重发完整
  `input`），让本地上下文压缩始终掌控全局。需要支持 Responses 的后端，例如
  Ollama >= 0.13.3、vLLM 或 OpenAI（#110）。
- `guarded` 模式现在默认把文件写入限制在项目根目录内，工具观察结果会用明确的
  不可信数据边界包裹，并且随仓库携带的 `<cwd>/.agents/skills` 需要显式开启（#113）。
- 上下文压缩现在通过 `Compressor` 策略接缝执行，`drop` 保留为最小兜底策略（#97）。
- 新增内置 `extractive` 压缩器，并支持通过 `agent.compactor` /
  `SCOOT_AGENT_COMPACTOR` 选择（#97）。

### 移除

- 移除 OpenAI Chat Completions 传输、`backend.api` 选择器与 `SCOOT_BACKEND_API`
  覆盖；Responses API 现在是唯一传输。仍设置 `api` 的旧配置会被忽略，并打印一行
  弃用警告（#110）。
- 移除 `backend.prompt_cache` 提示与 `SCOOT_BACKEND_PROMPT_CACHE` 覆盖（以及
  Anthropic 风格的 `cache_control` 断点）；`instructions` 字段已被原生缓存，手动提示
  已无意义。残留的旧键会被忽略并打印弃用警告（#110）。

### 修复

- `-e` 与 REPL 运行现在会获得每进程独立的 session transcript id，
  不再把所有运行追加进共享的 `cli.jsonl` 与 `repl.jsonl` 文件（#95）。
- 默认 agent 配置现在会开启保守的上下文预算，并使用 `extractive`
  压缩；`context_budget_bytes = 0` 仍可显式关闭该护栏（#96）。
- 灾难性 shell 命令检测现在也能拦截用空白字符混淆的 fork bomb 模式（#113）。
- GitHub workflows 现在把 action 引用固定到 commit SHA，并在解压前校验下载的
  Zig 工具链 tarball checksum（#113）。

## [0.2.0] - 2026-06-19

### 新增

- `SCOOT_*` 环境变量覆盖，用于零配置与 CI 运行（#67）
- `file_read` 支持 offset/limit 行窗口读取（#78）
- 到达上下文预算时压缩历史，而不是直接中止运行（#81）
- grep 支持匹配点前后的可选上下文行（#82）
- 面向稳定模型 prompt 的配置化 prompt-cache breakpoint（#84）
- 零依赖 `outline` 动作，用低 token 成本查看文件骨架（#85）
- POSIX release 安装脚本，可下载、校验并安装匹配当前主机的二进制（#90）
- CLI/REPL 运行结束后在 stderr 输出紧凑运行摘要，包含事件数、工具调用、策略拒绝、后端状态与 transcript 路径（#59）
- `schedule.jobs` 支持分钟级 5 字段 UTC cron 调度（#65）

### 变更

- `~/.agents/skills` 发现改为显式 opt-in，项目本地与 Scoot 本地 skills 仍默认启用（#87）
- 同一次运行中的重复只读观察会被去重（#83）
- Agent 观察结果会做 token 优化，包括去除 ANSI、head/tail 窗口与 token 上限（#80）
- 每轮 thought 不再持久化到运行历史（#79）
- 运行目录与 JSONL 审计/会话文件改为属主可读写，并对 JSONL 文件做有界 `.1` 轮转（#60、#61）
- GitHub workflow 改用 Node 24 兼容 actions，并用 shell 安装 Zig，避免 Node 20 action 告警（#63）
- `build_options` 同时导入可执行文件 root module 与库模块（#64）
- `parseStep` 现在容忍兼容后端用 Markdown 代码块包裹步骤 JSON、或一次连续输出多个 JSON 对象，只执行第一个步骤，保持单步 ReACT 语义

### 修复

- 语言切换入口移入 mdBook 导航图标区域（#86）
- 非法的枚举型 `SCOOT_*` 覆盖现在会告警并保留原值，不再静默改变 policy/mode/level（#68）
- `confine_writes` 现在会拒绝最终写入文件名本身为预置 symlink 的逃逸路径（#69）

### 文档

- 新增维护型 changelog，并让 release notes 从 changelog 派生（#66）
- 改进 README 与用户指南结构，包括安装器文档、设计理念、最佳实践案例和 daemon/运行模式说明（#90）
- 增加 Scoot logo、favicon 资产，以及带动效的文档站点入口页标识（#91）
- 将 logo 合入 README/mdBook 信息图，并移除重复的独立 logo 块（#92）

## [0.1.0] - 2026-06-18

自 `v0.0.2`（仅包含发布工作流的基础设施）以来的首个功能版本。

### 新增

- 交互式 REPL 中的 CLI 跟踪输出与 `--trace`（#7、#48）
- 实时的「thinking」/「running」跟踪标记，让 `--trace` 不再像卡住（#56）
- `doctor` 与策略 `check` 命令（#10）
- `scoot` home 覆盖标志（#11）
- 技能校验、技能包导出与技能审查元数据（#15、#17、#21）
- 原生技能读取及扩展的技能搜索路径（#35）
- 有界并行读取工具（#16）
- wasm 工具包边界（#20）
- 守护进程生命周期命令（#33）

### 修复

- 只读策略默认加固与受限读取路径（#13、#14）
- 重试瞬时的 eval 后端失败（#18）
- 解决所有开放问题 #22–#54（#34、#49、#55）
- 版本号现从 `build.zig.zon` 派生而非硬编码；发布构建嵌入 tag（#57）

### 文档

- 完善首页/许可证元数据、信息图与双语用户指南（#6、#19、#36）

[未发布]: https://github.com/jamiesun/scoot/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/jamiesun/scoot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jamiesun/scoot/compare/v0.0.2...v0.1.0
