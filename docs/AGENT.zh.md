# AGENT.zh.md

面向在本仓库工作的 AI Agent 与贡献者的工程约定。**动手前先读这里，再读 [`ROADMAP.zh.md`](./ROADMAP.zh.md) / [`ROADMAP.md`](./ROADMAP.md)。** ROADMAP 是事实来源与红线；本文件是落地时的操作手册。

## 文档语言同步规则

所有项目文档更新必须同步维护英文与中文版本。

- 根目录文档默认英文。
- 中文项目文档放在 `docs/` 下，使用 `.zh.md` 后缀。
- 代码注释、代码字符串、测试描述默认使用英文。
- 后续 GitHub issue 与 pull request 默认使用英文。
- 修改根目录 [`AGENT.md`](../AGENT.md) 时，必须同步修改本文件。
- 修改根目录 [`README.md`](../README.md) 时，必须同步修改 [`README.zh.md`](./README.zh.md)。
- 修改 [`ROADMAP.md`](./ROADMAP.md) 时，必须同步修改 [`ROADMAP.zh.md`](./ROADMAP.zh.md)。
- 修改 mdBook 内容时，`book/en` 与 `book/zh` 的导航、范围、命令和安全规则必须保持一致。

## 一句话项目定位

Scoot 是用**纯 Zig（0.16.0+）**手搓的轻量级 AI Agent 守护进程（Daemon / CLI）。基调：轻量、无冗余、本地优先、防御性编程。**当前已落地北极星五大支柱**（均有测试守护，`zig build test` 应保持全绿）：`scoot -e` 单次执行与默认 REPL 多轮交互跑完整 ReACT 闭环（结构化步骤 + 执行护栏 + 审计落盘）；**内建动作/工具集自包含**（bash + file_read/write/edit + grep/glob/outline + http_request + skill/recall/parallel + mcp_call + wasm_tool，核心读写搜索工具进程内实现，外部执行路径均经策略门与硬超时）；Skill 渐进式披露；Schedule 无人值守自主调度（强制 readonly 安全档）；密钥三来源安全管理。`grep -rn NotImplemented src` 现已无实现桩——新增能力时这是「扩展」而非「填空」。

## 常用命令

```sh
zig build            # 编译 → zig-out/bin/scoot（默认 Debug）
zig build run -- ARGS   # 构建并运行（如 zig build run -- --version）
zig build test       # 运行全部测试（提交前必跑）
zig build -Doptimize=ReleaseSmall   # 校验轻量级单体二进制
zig build -Doptimize=ReleaseSafe    # 嵌入式 / 生产部署推荐档（见下）
```

改动任何 `.zig` 后，至少跑通 `zig build` 与 `zig build test` 再交付。

**部署优化档（安全决策，非纯性能）**：嵌入式 / 生产部署推荐 **`ReleaseSafe`**——它保留整数溢出、越界、`unreachable` 等 safety check，触发时是**可被审计捕获的 panic**（与铁律 #4「绝不 panic」配套：结构性不可达一旦被破坏能立刻暴露，而非静默走错）。`ReleaseFast` 会把这些变成**静默未定义行为**，最危险的生产场景反而最不安全，**不推荐用于部署**。交付前应确认 `ReleaseSafe` 构建和测试套件同样通过。

## 本地 CI 与 git 钩子

提 PR 前，先在本地镜像 GitHub Actions 的 `zig` 任务（格式检查、Debug 构建、测试、ReleaseSafe 构建与 `--version` 冒烟）：

```sh
make ci          # 或：./scripts/local-ci.sh
```

每个克隆启用一次受版本管理的 pre-push 钩子，让 `git push` 先跑本地 CI（按 git 设计，它不会自动安装）：

```sh
make hooks       # 设置 core.hooksPath=.githooks
```

用 `git push --no-verify` 或 `SKIP_LOCAL_CI=1 git push` 绕过本地 CI 是**异常流程**，不是省事路径。只有 CI 基础设施故障、纯文档改动且已单独跑过 mdBook、或已经执行了等价验证时才允许绕过；必须在 PR 或交接说明里写清绕过原因和替代验证。`LOCAL_CI_CROSS=1` 与 `LOCAL_CI_DOCS=1` 会追加交叉编译与 mdBook 任务。

文档构建：

```sh
mdbook build book/en
mdbook build book/zh
mkdir -p site
cp book/site-index.html site/index.html
```

## 代码地图

| 路径 | 职责 |
| --- | --- |
| `src/main.zig` | CLI 入口：参数解析、setup/config/doctor、REPL、单次执行、skills、schedule、daemon、serve |
| `src/root.zig` | 稳定公开包根：只暴露窄口径 embedding API facade |
| `src/internal.zig` | CLI 与仓库测试使用的内部模块根；私有子系统从这里导出 |
| `src/api.zig` | 稳定 embedding 生命周期 facade：`Runtime`、`Options`、`start`、`run`、`stop` |
| `src/paths.zig` | 运行目录解析：`~/.scoot`（`SCOOT_HOME` 覆盖）及各子路径 |
| `src/config.zig` | 结构化配置（backend / agent / tools / skills / MCP / audit / schedule）；TOML 优先 / JSON 回落 |
| `src/toml.zig` | 自研零依赖 TOML 子集解析器（→ `std.json.Value`，复用 JSON 类型映射） |
| `src/secret.zig` | 密钥管理：env → 文件(0600) → 凭证命令，脱敏 |
| `src/llm.zig` | LLM 适配（OpenAI Responses API `/v1/responses`）：HTTP 往返 + 强制 json_schema/strict + 防弹解析 |
| `src/jsonio.zig` | 共享 JSON 字符串转义（session / llm 复用） |
| `src/regex.zig` | 本地 Thompson-NFA 正则引擎：线性时间、抗 ReDoS；支撑 `grep` |
| `src/skill.zig` | Skill 机制：发现 / 审查元数据 / 打包 / 渐进式披露 |
| `src/session.zig` | 会话：跨回合存活的消息流 + JSONL 序列化（短期记忆载体） |
| `src/compressor.zig` | 上下文压缩策略与外部 compressor plugin 边界 |
| `src/obs.zig` | 观察优化器：在工具输出进入会话历史前做 token 预算内的收缩 |
| `src/agent.zig` | 认知流引擎：多轮 ReACT 闭环、动作解析、策略门、工具执行、观察回灌 |
| `src/daemon.zig` | 前台 daemon 生命周期状态、pid 处理、stop/status 辅助逻辑 |
| `src/schedule.zig` | 调度引擎：every / at / 5 字段 UTC cron |
| `src/audit.zig` | 审计日志 |
| `src/policy.zig` | 执行策略门与路径/网络护栏 |
| `src/tools/*.zig` | 执行沙盒：bash / file / search / http / MCP client / Wasm runner shim |
| `src/wasm_*.zig` | 可选独立 `scoot-wasm` host/engine 支撑；除显式构建外不链接进核心二进制 |
| `src/edge_main.zig` | 可选独立 `scoot-edge` 舰队伴生程序；默认关闭且不链接进核心二进制 |
| `build.zig`, `build.zig.zon` | 构建与包清单 |

新增内部子系统：在 `src/` 建文件，并在 `src/internal.zig` 用 `pub const xxx = @import("xxx.zig");` 导出，使其纳入内部测试图。不要把私有子系统导出到 `src/root.zig`：该文件是稳定公开 embedding API，并有白名单测试守护。扩展它必须先做明确的 API 边界决策并同步文档。

## Zig 0.16 关键习惯（容易踩错，务必遵守）

本仓库用的是较新的 Zig，许多旧 API 已变化。**不要套用 0.11–0.14 的写法。**

- **入口签名**：`pub fn main(init: std.process.Init) !void`。不要用旧的 `pub fn main() !void` + `GeneralPurposeAllocator`。
- **进程级分配器**：`const arena = init.arena.allocator();`（进程生命周期，适合“活到进程结束”的分配）。
- **命令行参数**：`const args = try init.minimal.args.toSlice(arena);`，`args[0]` 是程序名。
- **I/O 需要 `init.io`**。写 stdout：

  ```zig
  var buf: [4096]u8 = undefined;
  var w: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
  const out = &w.interface;   // *std.Io.Writer
  defer out.flush() catch {}; // 别忘了 flush
  try out.print("...{s}\n", .{x});
  ```

  `std.debug.print` 走的是 **stderr**，仅用于调试。程序真正的输出走 stdout writer。
- **`std.ArrayList(T)` 是 unmanaged**：初始化 `= .empty`，方法都要带分配器——`list.append(gpa, x)`、`list.deinit(gpa)`、`list.orderedRemove(i)`、`list.pop()`。
- **环境变量**：`getEnvVarOwned` 已不存在。用 `init.environ_map.get("KEY")`（返回 `?[]const u8`，借用值，进程内有效）。类型为 `*std.process.Environ.Map`。需要把 env 传进子系统时，签名用 `env: *const std.process.Environ.Map`。
- **文件系统是 `Io` 驱动的**：`std.fs.cwd()` 已移除，文件 / 目录操作走 `std.Io`。需要 I/O 的函数把 `io: std.Io` 显式传进去（即便当前是 stub，也按真实签名预留），路径字符串用 `std.fs.path.join(allocator, &.{...})` 拼。
- **测试可见性**：每个文件用 `test { std.testing.refAllDecls(@This()); }` 强制编译并校验其声明。

## 内存纪律（核心约束）

服务于 ROADMAP「长效守护零泄漏」：

- 每个推理回合在长寿命 backing 分配器之上派生一个局部 arena，**回合末整体释放**：

  ```zig
  var arena_state = std.heap.ArenaAllocator.init(backing);
  defer arena_state.deinit();
  const arena = arena_state.allocator();
  ```

- 回合内的临时分配（消息组装、JSON 解析等）一律走该 arena，**不要**用 backing 分配器做回合内临时对象，避免常驻碎片。
- 长寿命状态（调度任务表、配置）才用 backing/gpa，并配对 `deinit`。

## 运行目录 / 配置 / 密钥 / Skill 约定

- **运行目录**：一切配置、密钥、技能、状态收敛在 `~/.scoot/`（`SCOOT_HOME` 可覆盖）。解析逻辑在 `src/paths.zig`；新写盘的东西放对应子目录（`config.toml`（或 `config.json`）/ `token` / `skills/` / `logs/` / `state/`），不要散落到别处或 `$HOME` 根下。`scoot config` 可打印解析结果。
- **配置**：结构化分节（backend / agent / tools / skills / MCP / audit / schedule）在 `src/config.zig`，`config.toml` 优先、`config.json` 兼容回落；默认值即可用，**不要**改默认值的含义。
- **密钥**：解析在 `src/secret.zig`，优先级 env → 文件(0600) → 凭证命令。实现文件分支时**必须**先 `assertPrivate` 校验 0600，权限过宽要拒绝。任何日志 / 错误 / 审计输出 token 前先过 `secret.redact`。
- **Skill**：机制在 `src/skill.zig`。坚持渐进式披露——发现阶段只读 front-matter（name+description），正文按需在 `activate` 时加载（搜索优先级：可选的 `<cwd>/.agents/skills`（`skills.include_project_skills=true`，默认关闭）> 可选的 `~/.agents/skills`（`skills.include_agents_skills=true`）> `~/.scoot/skills` > 配置的 `extra_paths`）。`extra_paths` 只能指向专用 skill root，绝不能指向 `$HOME`、仓库根、`~/.scoot`、运行期 `logs/` / `state/`，或任何可能混有密钥和无关项目文件的目录。读取技能指令/资源是原生只读能力（`skill` 动作），收口在技能目录内、照常审计，刻意不受策略门控制——故 `readonly` 下技能仍可激活。但 skill 携带的**脚本/命令**必须经 `src/tools/` 沙盒执行（带硬超时），不得新开绕过沙盒的执行路径。
- **会话 / 记忆**：`src/session.zig` 持有单次交互的消息流，**用 backing/gpa 拥有**（追加时复制内容），使其跨回合存活——绝不把对话历史放进会被 `deinit` 的 per-turn arena。持久化用 JSONL 追加写到 `state/sessions/<id>.jsonl`（纯文本、可回溯）。**跨会话长期记忆不做成子系统**：用 Skill 注入知识或 `state/` 摘要文件 + 文件工具承载，不引入向量库 / embedding（撞「单体简洁」铁律）。

## 红线（铁律，不得违反）

违反前必须先回到 ROADMAP 与用户确认是否改边界：

1. **不引入图形界面**：只有 CLI + 配置文件。不写 Web UI / GUI / 托盘。
2. **只对接 OpenAI 协议**：仅支持 OpenAI 兼容 Responses API（`/v1/responses`），强制结构化 JSON Schema 输出。Chat Completions 已移除；**不要**为 Chat Completions 或 Anthropic / Google 等非 OpenAI 格式写胶水代码。
3. **不搞复杂云端同步**：状态严格本地（`~/.scoot/`，JSONL / 纯文本本地状态）。不引入远程数据库、E2E 同步，不与特定网络栈强耦合。
4. **绝不信任模型输出**：任何未经 Schema 校验的模型响应都不得直接执行；解析失败要包装成 System Error 回灌触发重试，**不准 panic**。
5. **不为功能数量牺牲单体简洁**：不堆重型运行时、不做需要动态链接 / 加载原生代码的二进制插件体系。新增依赖前先问：它会破坏“单文件、零臃肿依赖”吗？（Skill 加载的是指令 + 数据 + 沙盒脚本，不是原生插件，不在此列。）
6. **工具必须有硬超时**：任何子进程 / 网络调用超时即猎杀（SIGKILL 或等效）并记录，绝不让单个任务卡死拖垮主循环。
7. **密钥零泄漏**：token 绝不编译进二进制、绝不内联进随仓库提交的配置、绝不打印进日志 / 审计 / 报错。不强依赖特定 OS 钥匙串；安全存储通过外部凭证命令接入。
8. **Skill 执行不越权**：skill 的**脚本/命令执行**不得绕过工具沙盒、不得自动联网拉取远程代码执行、不得获得超出已注册工具的能力。（读取技能指令/资源是原生只读能力，收口在技能目录内、照常审计，刻意置于策略门之外，使技能在 `readonly` 下仍可用。）
9. **Wasm 插件只做纯数据变换**：插件运行在纯数据变换沙箱中，唯一通道是 stdin（输入）、stdout/stderr（输出）、argv（配置）以及进程退出码。host 不得暴露文件系统、网络/套接字、数据库、环境变量、时钟或随机数能力；任何此类 import 一律 trap。插件输出必须是 `(stdin, argv)` 的纯函数；若插件需要时间戳、种子或 nonce，由 host 作为输入字节传入——绝不通过环境 syscall 提供。
10. **文档必须双语同步**：修改项目文档时，英文与中文对应版本必须一起更新；mdBook 的导航、范围、命令和安全规则必须保持一致。

## 新增 / 扩展一个能力的推荐流程

1. 在 `docs/ROADMAP.md` / `docs/ROADMAP.zh.md` 里确认这条能力服务于哪个目标画像 / 方向，是否触碰红线。
2. 定位落点：扩展既有子系统（如给 `agent.zig` 加一个 `Action`、给某工具加分支）还是新建文件；核心逻辑已基本无 `error.NotImplemented` 桩，多数是「在既有结构上扩展」而非「填空」。
3. 先写最小可用实现 + 对应 `test` 块；保持函数签名稳定，必要时再扩展。
4. 防御式编码：先校验输入与模型输出，再执行；外部交互全部加超时。
5. 如果新增内部模块，从 `src/internal.zig` 导出；只有刻意改变稳定 embedding API 时才导出到 `src/root.zig`。
6. `zig build && zig build test` 通过后再交付。

## 风格与提交

- 只为需要解释的地方写注释；公共 API 用 `///` 文档注释说明意图与边界。
- 注释、代码字符串、测试描述默认使用英文；项目文档必须中英同步，根目录文档默认英文。
- 改动保持外科手术式：不顺手重构无关代码，不偷偷放宽红线。
- 当代码与 ROADMAP / 本文件冲突时，以**可运行的代码与测试**为事实来源，并同步修订文档对应处。
