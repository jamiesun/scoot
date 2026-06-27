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

- `scoot-wasm` 现已能执行浮点 Wasm（W4）：f32/f64 算术（add/sub/mul/div）、
  一元运算（abs/neg/ceil/floor/trunc/nearest/sqrt）、min/max/copysign、有序
  比较、整数与浮点互转，以及会 trap 的截断（`iNN.trunc_fMM_s/u`）与饱和截断
  （`iNN.trunc_sat_fMM_s/u`），并与已支持的批量 `memory.copy`/`memory.fill`
  一同工作。NaN 结果会被规范化以保证跨 host 的确定性输出，而 abs/neg/copysign
  保留精确位模式；`nearest` 采用“就近取偶”并保留零的符号。静态类型验证器现在也会
  对浮点 opcode 做类型检查，因此浮点模块可端到端加载并运行。新增的健壮性
  测试套件会向加载器喂入截断的、单字节损坏的以及随机/恶意的模块字节，
  并断言每个输入都返回结构化的加载错误或 trap 而不是崩溃。超出当前支持
  子集的完整 spec 一致验证仍留待后续阶段（#100）。
- 新增原生 `wasm_tool` Agent 动作，用于运行 compute-only 本地 Wasm 包。它会校验
  package 边界，要求 `entry = "_start"` 且 `policy.toml` 只能授予 `compute`，
  并直接运行配置好的 `scoot-wasm` host argv，不再为了执行 Wasm 工具给模型宽泛的
  `bash` 命令。使用默认 host 配置时，Scoot 会先选择与当前 `scoot` 二进制同目录的
  `scoot-wasm`，找不到再回退 PATH。
- 新增可复制的 Wasm compressor 插件模板、确定性的 redactor compressor 示例，以及用于
  构建、校验和 smoke-test 示例包的 `scripts/check-wasm-examples.sh`。
- `scoot-wasm` 现在会在执行前对当前 host 子集做 W3 函数体静态类型验证。该验证会检查
  operand/control stack 形状、block/loop/if 签名、分支 label、直接与间接调用签名、
  local/global 访问、memory/table 是否存在，以及不可变 global 写入，使畸形类型/索引错误
  在模块加载阶段失败，而不是进入解释器后才暴露。超出当前支持子集的完整 spec 一致验证仍
  留待后续阶段（#100）。
- `scoot-wasm` 现已能在最小 WASI preview1 子集上运行 `wasm32-wasi` 命令模块（W2）：
  `scoot-wasm wasi <module.wasm> [参数...]` 实例化模块、执行 `_start`、把本进程的
  stdin 作为 fd 0 读入、转发模块的 stdout/stderr，并以其 `proc_exit` 状态退出。暴露的
  表面是纯数据变换沙箱：唯一通道是 stdin（`fd_read`，fd 0）、stdout/stderr
  （`fd_write`，fd 1/2）、argv（`args_*`）与 `proc_exit`。不暴露环境变量、时钟、
  随机数、文件或网络——`environ_*`、`clock_time_get`、`random_get` 以及其余所有
  WASI import 按构造 trap，使插件输出是 `(stdin, argv)` 的纯函数。越界 guest 指针
  返回 EFAULT，非 stdio 描述符返回 EBADF。这正是外部压缩插件的子进程 host（#100）。
- `scoot-wasm` 现已能执行整数 Wasm 函数（W1）：一个零依赖的纯 Zig 栈机，支持结构化
  控制流（block/loop/if/else/br/br_if/br_table/return/call/call_indirect）、
  i32/i64 算术、带边界检查的 64 KiB 页线性内存（load/store、memory.size/grow）、
  全局变量、funcref 表，以及 active data/element 段。任何故障都是结构化 trap
  （unreachable、除零、整数溢出、内存/表越界、间接调用类型不匹配），并由 fuel、
  调用深度与内存页上限兜底。用 `scoot-wasm run <module.wasm> <export> [整数参数...]`
  调用。引擎仅编译进独立的 `scoot-wasm` 二进制（`-Dwasm-host=true`），零依赖核心
  从不链接它。超出当前支持子集的完整 spec 一致验证留待后续阶段（#100）。
- 发布流程现在会为每个目标单独发布一个 `scoot-wasm-<target>.tar.gz` 压缩包
  （外加 `.sha256`），在同一个 job 中通过 `-Dwasm-host=true` 构建。可选的独立
  Wasm 计算单元 host 现在是可下载产物，不再只能从源码构建。
- 新增 Homebrew tap 发布 job（`brew install jamiesun/tap/scoot` 与
  `brew install jamiesun/tap/scoot-wasm`）。`scoot-wasm` formula 依赖 `scoot`，
  所以安装 host 会一并安装 agent；默认的 `wasm_host` 随后会从 `PATH` 解析
  `scoot-wasm`。该 job 仅在设置了 `HOMEBREW_TAP_TOKEN` secret 时运行，与可选的
  Docker Hub 发布保持一致。

### 变更

- 发布压缩包现在每个目标只发布单一 `ReleaseSafe` 变体，不再同时发布
  `ReleaseSafe` 与 `ReleaseSmall`。需要更小二进制的用户用
  `-Doptimize=ReleaseSmall` 从源码编译；发布说明带有一段固定脚注说明这一点以及
  可选的 Wasm host。

### 移除

- 移除 `-small`（`ReleaseSmall`）发布产物以及安装脚本的 `SCOOT_INSTALL_FLAVOR`
  变量。`install.sh` 现在只下载唯一发布的变体。

## [0.4.0] - 2026-06-26

### 新增

- 嵌入式运行现在会写入带 session 关联的审计事件，并生成每个 session
  自己的 JSONL 状态，便于回放和检查 API 驱动的运行（#140）。
- 新增只读 session 与 audit 命令：`scoot sessions list`、
  `scoot session show <id>`、`scoot audit show <session-id>`（#141）。
- 新增前台 `scoot serve` stdio NDJSON 协议，支持 `run`、`session.list`、
  `session.get`、`audit.query` 方法，用于本地 app-server 集成（#142）。

### 变更

- 加固 serve 与 daemon 生命周期：stdio `run` 使用请求级结果分配并继承默认重试语义；
  `daemon stop` 只有在 pid 与记录中的 running daemon 状态一致时才发送信号（#143）。

## [0.3.0] - 2026-06-23

### 新增

- Docker release 现在会向 GHCR 发布面向 `linux/amd64`、`linux/arm64` 和
  `linux/arm/v7` 的多平台 Linux 镜像；配置 Docker Hub 凭据时也会同步发布到
  Docker Hub。默认镜像使用极简 BusyBox/musl 运行时，对应的 Alpine 运行时标签使用
  `-alpine` 后缀。
- 新增 `scoot setup` 交互式命令，通过几步提问生成配置目录（配置目录并带覆盖确认、
  后端 `base_url`/`model`、token 来源 env/0600 文件/命令、`max_turns`、策略），创建运行
  目录树并写出 `config.toml`，且绝不内联 token —— 是在同一台主机上搭建多个隔离实例的
  快捷路径。
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
- MCP stdio 测试现在使用每进程独立的临时目录，使并行 `zig build test`
  的多个测试产物不再因共享 `/tmp` 路径而相互竞争（#122）。
- MCP SSE 传输现在对整个会话（建立连接、`receiveHead`、每次 POST 与每次事件
  读取）强制一个累计超时，使得「接受连接却始终不返回响应头」或「在每次单事件
  超时前才挤出一个事件」的服务器再也无法让 agent 永久挂起（#123）。
- MCP 远程 header 中来自环境变量（`value_env`）的取值现在也会校验 CR/LF，
  修复了此前只校验字面 `value` 与 `prefix`、却放过已解析环境变量取值的
  header 注入缺口（#124）。
- MCP stdio 传输现在会用配置的超时约束子进程 stdin 写入。此前当服务器始终不
  读取自己的 stdin 时，一旦 OS 管道缓冲被模型可控的请求写满，写入就会永久阻塞，
  且 `defer child.kill` 清理永远无法执行（#125）。
- `zig build test` 现在会顺序运行三个测试产物，而不是并行执行，因此在多个测试
  二进制间共享硬编码 `/tmp/scoot_*` 路径的测试不再相互竞争（某个二进制的
  `deleteTree` 删掉另一个正在 `exec` 的文件）；编译仍然并行（#127）。

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

[未发布]: https://github.com/jamiesun/scoot/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/jamiesun/scoot/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jamiesun/scoot/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jamiesun/scoot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jamiesun/scoot/compare/v0.0.2...v0.1.0
