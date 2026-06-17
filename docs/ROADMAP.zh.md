# Scoot 项目画像与方向

> 本文是 Scoot 的北极星与护栏：讲清它**应该成为什么样**、**绝不能变成什么样**，把目标与边界焊死，而把“具体怎么实现”留给执行者。它不是施工图，也不是任务排期表。

## 项目概述

Scoot 是一个运行在纯文本环境下的轻量级 AI Agent 守护进程（Daemon / CLI）。它作为本地算力或远程模型的执行中枢，能在无人干预的情况下，依据设定的目标（Goal）或定时任务（Schedule），安全、自主地调用底层系统能力——执行 Shell、读写文件、发起网络请求——并把每一步思考与动作沉淀为可审计的日志。

它服务于有硬核自动化需求的系统管理员、开发者与技术向高级用户，目标是把 AI 的思考能力转化为**可审计、可干预、可信任**的系统级操作。设计基调延续 C/C++ 时代的防御性编程：轻量、无冗余、本地优先，宁可保守拒绝，也不盲目放行。

- 架构图

```text
                +---------------------------+
                |       User / Operator     |
                |  CLI · REPL · Daemon mode |
                +-------------+-------------+
                              |
                              v
 +-------------------------------------------+    (OpenAI API Spec)      +--------------------------+
 |             Scoot Core (CLI)              | <----------------------> |        LLM Backend       |
 |  Cognitive Engine: ReACT / Plan & Act     |  JSON Schema·strict:true  |     Local / Remote       |
 |  Memory: per-loop Arena Allocator         |   token: env/file/cmd     | (OpenAI-compatible only) |
 +----+---------------------------------+----+                          +--------------------------+
      |                                 |
      | (skill 渐进式披露)               |  (Spawn / I/O · 硬超时 Hard Timeout)
      v                                 v
 +---------------------------+    +-------------------------------------------------------+
 |        Skill Engine       |    |                  Execution Sandbox                    |
 |  discover · select · load |    |  bash · grep · glob · file_read/write/edit · http     |
 +---------------------------+    +-------------------------------------------------------+
      |                                 |
      |                                 |  (Async / Timer)
      v                                 v
 +-------------------------------+    +-------------------------------+
 |        Schedule Engine        |    |    Local State & Audit Log    |
 |     every · at · cron         |    |    SQLite / 纯文本日志        |
 +-------------------------------+    +-------------------------------+

 运行目录 ~/.scoot/（环境变量 SCOOT_HOME 可覆盖）:
   config.toml（或 config.json）· token (0600) · skills/ · logs/ · state/
```

## 项目画像（目标状态）

做好之后，Scoot 是这样一个东西：

- **即插即用的单体二进制。** 拿到源码后，只用基础语言工具链就能编译出唯一一个可执行文件，没有臃肿的运行时依赖，体积保持在轻量级预期内。部署等于拷贝一个文件。
- **可审计胜过黑盒自动化。** Agent 的每一次“思考（Thought）”与“工具调用（Tool Execution）”都留下明确日志。用户在任何时刻都能回溯“它当时在想什么、做了什么、看到了什么”，而不是面对一个不可解释的黑盒。
- **防御优先于智能。** 面对模型吐出的脏数据（残缺 JSON、Markdown 包裹、幻觉参数），Scoot 的第一反应是严格校验与拒绝，而不是将就执行。所有模型响应都必须穿过严苛的 JSON Schema 解析才能落地为动作。
- **稳定胜过功能堆叠。** 作为常驻守护进程，长期运行的内存平稳、无泄漏、不卡死，比多加一个花哨功能更重要。
- **纯 CLI 交互。** 通过命令行、REPL 与配置文件完成一切，支持前台交互与后台守护两种形态。
- **Skill 即能力扩展。** 把"打包好的能力 + 指令集"以目录形式丢进 `~/.scoot/skills`，Scoot 无需重新编译就能发现并按需挂载——能力随用户增长，核心二进制始终精简。
- **密钥默认不落盘明文。** API token 优先取自环境变量或带严格权限的外部来源，绝不内联进配置、绝不写进日志；状态与配置统一收敛在本地运行目录 `~/.scoot/`。

**品质冲突时的优先级（从高到低）：**

1. **安全与可控** —— 宁可拒绝执行、宁可慢一拍，也绝不让未经验证的模型输出直接落到系统上。
2. **稳定与零泄漏** —— 长效守护的平稳压倒一切短期便利。
3. **轻量与简洁** —— 能不引入的依赖与抽象就不引入。
4. **功能丰富度** —— 永远排在最后；功能让位于上面三条。

## 当前能力清单

> 现状核验：本仓库已落地北极星五大支柱——ReACT 认知流 / 内建工具集（零外部命令依赖）/ 执行护栏 / Skill / Schedule，外加审计、会话、配置、密钥三大支撑，`zig build` / `zig build test` 全绿（112 项，Debug 与 ReleaseSafe 双档）。`grep -rn NotImplemented src` 现已无实现桩。下列条目标注 ✅（核心逻辑已实现并有测试守护）/ 🚧（明确暂缓或增量待定，见各条尾注与「暂缓」）。

- **✅ 基础工具集（Core Toolset）**
  对 `bash`、`grep`、`glob`、`file_read`、`file_write`、`file_edit`、`http_request` 的底层封装，构成 Agent 可调用的执行原语，**全部进程内自包含、零外部命令依赖**（裁剪 / 嵌入式 Linux 可用）。`bash`（`src/tools/bash.zig`）经 `/bin/sh -c` 执行、**硬超时**强制终止、输出上限与可选 cwd 沙盒；`file_*`（`src/tools/file.zig`）进程内读 / 覆盖写 / 唯一匹配编辑，自带大小上限；`grep`/`glob`（`src/tools/search.zig`）—— grep 走**自研 Thompson NFA 正则引擎**（`src/regex.zig`，线性时间、ReDoS 免疫，不依赖第三方正则），glob 走 `std.fs` 遍历；`http_request`（`src/tools/http.zig`）发 HTTP/HTTPS、**`std.Io.Select` 竞速硬超时**（真正中断挂死连接）、可配 CA。各工具均有单元测试守护（含黑洞地址超时实测）。

- **✅🚧 OpenAI 协议适配（API Integration）**
  仅对接 `/v1/chat/completions`；强制开启 `response_format: { type: "json_schema" }` 与 `strict: true`，从协议层把模型输出约束成结构化数据。`src/llm.zig` 已实现真实 HTTP 往返（`std.http.Client.fetch`）、紧凑请求体构造（强制 `json_schema` + `strict:true`，有测试验证）、防弹响应解析（`std.json` 容错，结构不符即 `MalformedResponse` 不 panic）与**可配 CA**（嵌入式 HTTPS-to-LLM）。🚧 流式（`stream`）与后端原生 Tool Calling 字段刻意不做——ReACT 经 `response_format` 约束结构化输出，对本地小模型更稳健（见「方向与意图」）。

- **✅ 调度引擎（Scheduler）**
  基于时间循环的触发器，支持 `every`（间隔）、`at`（固定时间点）两类调度——`src/schedule.zig` 已实现：`dueAt` 纯函数到点判定（时间可注入，便于防弹单测）、`tick`/`runForever` 守护循环（真实单调时钟，`--ticks N` 支持有界运行）。`scoot schedule list` 列出任务与**有效执行档**，`scoot schedule run` 进入守护循环到点唤起 Agent。**安全前置（铁律 #1）**：被调度 job 是无人在场的自主执行，故默认强制 `readonly` 安全档，`guarded` 绊线一律由 `effectiveMode` 矫正为 `readonly`（结构性保证，无人值守绝不跑在 guarded 之上）；用户可显式 `unrestricted`（自担风险，仍全程审计）。每个 job 用可重置 arena 承载 scratch，跑完即回收以保长效零泄漏。`cron`（Cron 表达式）暂不支持——`dueAt` 对其恒返回 false，不半实现一个会出错的解析器（反过载）。`schedule.enabled` 默认关闭，自主无人值守必须显式开启。

- **✅ 认知流引擎（ReACT Loop）**
  经典“思考–行动–观察”（Thought–Action–Observation）闭环状态机，驱动 Agent 自主推进任务。`src/agent.zig` 已实现**多轮**闭环：每回合用强制 json_schema 让模型产出结构化步骤 `{thought, action, action_input}`（`action ∈ {bash, file_read, file_write, file_edit, grep, glob, http_request, final}`），动作**先过执行护栏校验、再**经统一工具沙盒（硬超时）执行、输出作为「观察」回灌续推，`final` 即终态；非法步骤防弹捕获并回灌纠错触发重试；`max_turns` 防失控；每回合派生可重置 arena、回合末整体释放（长效零泄漏）。`scoot -e` 单次执行与默认 **REPL 多轮交互**（复用会话、每轮独立审计、出错不中断、收尾落盘）均已端到端打通（含真实工具调用）。设计上不依赖后端原生 tool_calls（对本地小模型更稳健），有脚本化大脑驱动的循环测试守护。

- **✅ 执行护栏（Execution Policy）—— 兑现「安全与可控」铁律**
  模型产出的动作在落到系统前必须穿过策略门（`src/policy.zig`），绝不直接执行未经验证的输出。`bash` 走命令串审查 `evaluate`，**内建工具按能力分类**走 `evaluateTool`（读 `file_read`/`grep`/`glob` → `.read`，写 `file_write`/`file_edit` → `.write`，`http_request` 按方法 GET/HEAD→`.net_read`、写类→`.net_write`，畸形/未知 fail-closed）。三档模式：`guarded`（拦截 `rm -rf /`、fork bomb、`| sh`、`mkfs`、`shutdown` 等灾难性命令绊线，交互默认）/ `readonly`（无人值守安全档：禁 shell、禁网络、只放行项目内相对路径且避开常见敏感片段的进程内本地读工具，写类结构性拒绝，fail-closed）/ `unrestricted`（不设限，仍被审计）。被拒动作不执行、留痕 `policy_deny`、并把拒绝理由作为「观察」回灌让模型改道。诚实边界：`guarded` 是灾难性命令**绊线**而非沙箱，`readonly` 是更保守的 fail-closed 策略，但仍需要后续明确 project-dir / OS 隔离来成为强安全边界。含单测 + 端到端冒烟（`rm -rf /` 被拦、审计可证未执行）。

- **🧱✅🚧 会话（Session）—— 短期记忆载体**
  一段有边界交互（REPL 对话 / `-e` 调用 / 被调度的 job）的消息流。承载在长寿命分配器上，使对话历史跨越认知回合的 per-turn arena 重置依然存活。内存记录（追加即复制副本）、JSONL 序列化与追加落盘（`state/sessions/<id>.jsonl`）均已实现并有测试（`src/session.zig`）。**跨会话的长期记忆不在此实现**——交由 Skill 机制（知识注入）或 `state/` 纯文本摘要 + 文件工具承载，避免引入向量库等重依赖而撞穿铁律。

- **✅ Skill 机制（Skill Engine）— 必备能力**
  以目录形式挂载"能力 + 指令集"，从 `~/.scoot/skills`（及配置的额外路径）发现、按需加载。`src/skill.zig` 已实现渐进式披露：遍历各路径子目录、**防弹解析** `SKILL.md` 的 YAML front-matter（name/description 及可选 `capabilities` / `allowed_tools` / `scope` 审查元数据，任意截断/畸形输入只得 null 绝不 panic）、按名去重建轻量索引；清单（name+描述+路径）注入 system 上下文，模型判断相关时**用既有 bash 工具读取正文激活**（正文绝不预注入，上下文恒定轻量），脚本经统一沙盒执行不获特权。`scoot skills` 可列出已发现技能，`scoot skills check/pack` 可校验和导出审查 manifest。skill 元数据仅供审查，不授予权限，真正执行仍由全局 policy gate 决定。

- **🧱🚧 运行目录与配置（Runtime & Config）**
  统一运行目录 `~/.scoot/`（`SCOOT_HOME` 可覆盖），含 `config.toml`（或 `config.json`）/ `token` / `skills/` / `logs/` / `state/`。结构化配置（backend / agent / tools / skills / audit / schedule）见 `src/config.zig`；路径解析、`scoot config` 命令、配置文件加载（**TOML 优先、JSON 回落**：自研零依赖 TOML 子集解析→`std.json.Value`，复用 std.json 按节合并——缺省回落默认、未知字段忽略、畸形配置清晰报错）、启动时幂等建目录树（`paths.ensure`）均已可用。🚧 目录权限收紧（home 0700 / token 0600 的 mkdir 强制）仍用系统默认权限，待硬化（非阻断）。

- **✅ 密钥安全管理（Secret）**
  token 解析优先级 env → 文件(0600) → 凭证命令，明文绝不入库、绝不进日志。`src/secret.zig` 已实现逐源解析：env（非空）→ token 文件（`assertPrivate` 仿 SSH 私钥，`mode & 0o077 != 0` 即拒读，**读文件前先校验**绝不把世界可读密钥读进内存）→ 凭证命令（复用 bash 沙盒，**10s 硬超时**，stdout 即 token）。权限过宽明示提示 `chmod 600`，`redact` 脱敏，config 刻意不暴露内联明文字段。含 7 项单测 + 二进制四例冒烟守护。

- **✅🚧 可审计日志与本地状态**
  每轮思考与工具调用以 JSONL 写入审计日志（`logs/audit.jsonl`），会话快照落 `state/sessions/`，状态严格本地、纯文本可回放（`src/audit.zig` + `src/session.zig` 已实现并有测试）。🚧 SQLite 索引 / 日志轮转 / 时间戳等增强待定。

## 非目标（铁律）

以下是不可越界的硬规则，除非用户明确修改边界，否则一律视为禁止项：

- **绝不引入图形界面。** 不做任何 Web UI、桌面 GUI 或系统托盘。一切交互通过 CLI 与配置文件完成——这是“轻量、无冗余”的直接体现。
- **绝不适配非标准 API。** 不为 Anthropic、Google 等非 OpenAI 格式的接口编写胶水代码。所有 LLM 后端必须经统一的 OpenAI 兼容接口接入（本地模型服务自带兼容层或外部网关自行抹平差异），避免多协议带来的维护熵增。
- **绝不搞复杂的云端同步。** 不引入远程数据库，不做端到端加密的状态同步，不与任何特定网络栈强耦合。状态数据严格留在本地。
- **绝不信任模型输出。** 任何未经 Schema 校验的模型响应都不得直接作为系统命令执行；校验不通过即拒绝并回灌错误，而非将就放行。
- **绝不为功能数量牺牲单体简洁。** 不堆叠重型运行时、不做需要动态链接 / 加载原生代码的二进制插件体系；新增能力若会破坏“单文件、零臃肿依赖”的底盘，就不做。（注：Skill 机制加载的是**指令与数据**及经沙盒执行的脚本，不是可动态链接的原生插件，二者不冲突。）
- **绝不把明文密钥固化或外泄。** API token 绝不编译进二进制、绝不内联进随仓库提交的配置、绝不打印进日志或审计。不强依赖特定 OS 钥匙串（避免平台耦合）；需要安全存储时通过外部凭证命令（如 `pass`/`gpg`）接入。
- **Skill 绝不绕过沙盒。** skill 携带的脚本与动作一律经统一工具沙盒执行，受同样的硬超时与防御校验约束；skill 不得获得超出已注册工具的能力，也不得自动联网拉取远程代码执行。

## 方向与意图

> 描述未来想去的地方与原因，用结果与能力表达；不规定版本顺序、排期或实现细节。文中提到的具体技术（Arena、SIGKILL、DAG 等）是当前设想的实现手段，可被更优方案替换，真正不可让步的是它们服务的目标。

- **方向一：稳健的回合制内存管理。**
  服务于“长效守护零泄漏”这一目标状态。意图是让常驻进程在处理海量 JSON 反序列化时，内存占用曲线始终平坦——通过每个推理循环重置局部 Arena Allocator（或等效的回合制内存回收策略），从根上消除碎片与泄漏。

- **方向二：双轨认知模式（Goal & Plan）。**
  服务于“适配不同任务复杂度”的体验目标。
  - **目标模式（Goal Mode）**：给出宏大指令，允许 Agent 自主探索与纠错（ReACT 闭环）。
  - **计划模式（Plan Mode）**：Agent 先产出一份固定的执行 DAG（有向无环图），经用户确认或审计后，再严格按步骤执行——把“可审计、可干预”落到任务编排层。

- **方向三：CLI 交互式的 Schedule 管理。**
  服务于“把 AI 能力与传统定时任务融合”的取向，让 Scoot 成为个人的智能 Cronjob 中枢，定时唤起 Agent 处理后台任务。**当前已落地**声明式形态：任务在配置文件（`config.toml` / `config.json`）的 `schedule.jobs` 声明，`scoot schedule list` 查看（含有效执行档与非法标记）、`scoot schedule run` 进入守护循环执行。交互式增删（类 IRC / Slack bot 的 `/schedule add`、`/schedule remove` 运行时改配）为后续增量——声明式配置已能覆盖核心场景，避免过早引入运行时任务 CRUD 与持久化复杂度。

- **方向四：本地 Skill 机制（渐进式披露）。**
  服务于“Skill 即能力扩展”与“轻量化”两个画像。意图是让用户把"能力 + 指令集"做成 `~/.scoot/skills` 下的目录（`SKILL.md` 描述 + 可选脚本/资源），Scoot 启动时只读取 name/description 建轻量索引并注入上下文，模型选中后才加载该 skill 的正文与资源。如此既能无限扩展能力，又不会让所有 skill 的正文一次性挤爆上下文，也无需为加新能力重新编译。skill 自带脚本必须经统一沙盒执行。

- **方向五：本地优先的密钥与运行目录治理。**
  服务于“密钥默认不落盘明文”画像与“本地优先”边界。意图是把配置、密钥、日志、状态统一收敛到 `~/.scoot/`（`SCOOT_HOME` 可覆盖），并对密钥采取分层来源（环境变量 → 0600 权限文件 → 外部凭证命令），对权限过宽的密钥文件直接拒绝读取，让“安全”成为默认而非附加项。

## 完成的样子

> 当下面这些**可观察的结果**真实出现时，才算 Scoot 的底盘真正焊死。具体阈值与手段（30 秒、SIGKILL、SQLite 等）是举例，重点是结果本身能被观测到。

- **防弹级 JSON 解析。** 当本地小模型“发疯”、吐出带 Markdown 标记的残缺 JSON 时，Scoot 不 Panic、不崩，而是稳稳捕获异常，把它包装成一条 System Error 回灌给 LLM 触发重试。

- **可靠的硬超时干预。** 当被调度执行的某个 bash 脚本意外卡死（死锁、等待输入），超过设定阈值（如 30 秒）时，主进程能精准猎杀该子进程（SIGKILL 或等效手段），记录超时日志，并继续下一个处理循环——一个子任务卡死绝不拖垮整条守护。

- **长效守护零泄漏。** 开启多个定时 Schedule、让 Agent 连续处理后台任务（如每 5 分钟巡检服务器健康）数周后，内存占用曲线保持平坦，无任何持续攀升迹象。

- **极简构建。** 任意开发者拿到源码，仅凭基础语言工具链（`zig build`），就能在极短时间内编出唯一的二进制单体文件，体积符合轻量级预期。

- **可回溯的审计链路。** 任取一次历史运行，都能从日志完整还原其“思考 → 工具调用 → 观察结果”的链条，无需附加外部追踪系统。

- **零编译的 Skill 热插拔。** 往 `~/.scoot/skills` 丢一个新的 skill 目录，重启（或刷新）后 Scoot 即能在能力清单里发现它；当任务匹配其描述时按需加载其正文并使用，全程无需改动或重新编译核心二进制。

- **密钥零泄漏。** 仅设置环境变量或 `~/.scoot/token`（0600）即可让 Scoot 取到 token；若该文件被改成 group/other 可读，Scoot 拒绝启动并给出明确提示；任何日志、审计、错误信息里都搜不到 token 明文。
