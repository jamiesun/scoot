# Scoot

> 轻量级 AI Agent 守护进程（Daemon / CLI）—— 用纯 Zig 手搓的硬核自动化中枢。

Scoot 在纯文本环境下运行，作为本地算力或远程模型的执行中枢，依据**目标（Goal）**或**定时任务（Schedule）**自主调用底层系统能力（Shell、文件、网络），并把每一步思考与动作沉淀为可审计的日志。设计基调延续 C/C++ 时代的防御性编程：**轻量、无冗余、本地优先，宁可拒绝执行，也绝不盲目信任模型输出。**

> ⚠️ **当前状态：早期实现（early implementation）。** 模块结构已就位、可编译可运行；第一条纵向切片已打通——`scoot -e "…"` 走真实 OpenAI 协议往返（强制 `json_schema` + 防弹解析）并端到端输出，无后端时优雅失败。其余核心能力（工具沙盒、Skill 加载、调度、配置落盘等）多数仍为 stub。完整的目标画像、边界与方向见 [`ROADMAP.md`](./ROADMAP.md)。

## 环境要求

- [Zig](https://ziglang.org/) **0.16.0+**（无其他运行时依赖）

## 构建与运行

```sh
zig build                       # 编译到 zig-out/bin/scoot（Debug）
zig build run -- --version      # 构建并运行
zig build test                  # 运行全部测试
zig build -Doptimize=ReleaseSmall   # 轻量级单体二进制（约 161K）
```

直接运行已编译的二进制：

```sh
./zig-out/bin/scoot             # 进入交互式 REPL（默认，stub）
./zig-out/bin/scoot config      # 打印解析后的运行目录与后端配置
./zig-out/bin/scoot --version   # 显示版本
./zig-out/bin/scoot --help      # 显示帮助
./zig-out/bin/scoot -e "巡检服务器健康"   # 单次执行：一次 LLM 往返后输出并退出（需后端在运行）
```

## 项目结构

```text
build.zig            构建脚本：定义 scoot 库模块与可执行文件
build.zig.zon        包清单（name/version/fingerprint/minimum_zig_version）
ROADMAP.md           项目画像与方向（北极星 + 护栏）
AGENT.md             面向 AI Agent 的协作约定与红线
src/
  main.zig           CLI 入口：参数解析 → REPL / 单次执行 / 守护 / config
  root.zig           scoot 库模块根：再导出各子系统命名空间
  paths.zig          运行目录解析：~/.scoot（SCOOT_HOME 可覆盖）及各子路径
  config.zig         结构化配置（backend / agent / tools / skills / audit）
  secret.zig         密钥安全管理：env → 文件(0600) → 凭证命令，脱敏
  llm.zig            LLM 适配：仅 OpenAI /v1/chat/completions（json_schema + strict）
  jsonio.zig         共享 JSON 字符串转义（session / llm 复用）
  skill.zig          Skill 机制：发现 / 选择 / 按需加载（渐进式披露）
  session.zig        会话：跨回合存活的消息流 + JSONL 序列化（短期记忆载体）
  agent.zig          认知流引擎：ReACT 闭环 + 每回合 ArenaAllocator
  schedule.zig       调度引擎：every / at / cron 触发器
  audit.zig          审计日志：思考 / 工具调用 / 观察 留痕
  tools/             执行沙盒（均带硬超时）
    tools.zig        工具注册与统一结果类型
    bash.zig         shell 命令执行
    file.zig         file_read / file_write / file_edit
    search.zig       grep（内容）/ glob（路径）
    http.zig         http_request
```

## 运行目录

Scoot 把配置、密钥、技能与状态统一收敛在一个本地运行目录下，默认 `~/.scoot/`，可用环境变量 `SCOOT_HOME` 覆盖（`scoot config` 可查看解析结果）：

```text
~/.scoot/
  config.json   主配置（不存放明文密钥）
  token         可选的 API token 文件（要求权限 0600）
  skills/       用户级 skill 目录（每个子目录是一个 skill）
  logs/         审计 / 运行日志
  state/        本地状态（调度任务、会话等）
```

`config.json` 结构（缺省即用内置默认值）：

```json
{
  "backend": {
    "base_url": "http://127.0.0.1:11434/v1",
    "model": "qwen2.5",
    "api_key_env": "OPENAI_API_KEY",
    "api_key_file": null,
    "api_key_cmd": null
  },
  "agent":  { "max_turns": 32, "default_mode": "goal" },
  "tools":  { "timeout_ms": 30000 },
  "skills": { "enabled": true, "extra_paths": [] },
  "audit":  { "level": "info", "to_file": true }
}
```

## Token 安全管理

**默认绝不把明文密钥写进 `config.json` 或随仓库提交；token 只在内存中短暂存活，且绝不写进日志 / 审计。** 解析优先级（高 → 低）：

1. **环境变量**（默认 `OPENAI_API_KEY`，可由 `backend.api_key_env` 改名）—— Scoot 永不写回磁盘。
2. **独立 token 文件**（默认 `~/.scoot/token`，可由 `backend.api_key_file` 指定）—— 必须 `0600`，权限过宽则**拒绝读取**（仿 SSH / `.netrc`）。
3. **凭证命令**（`backend.api_key_cmd`，如 `pass show openai`）—— 其标准输出即 token，借助 `pass` / `gpg` / 钥匙串 CLI 等外部工具实现安全存储，**不引入平台钥匙串依赖**。
4. **（强烈不推荐）** `config.json` 内联 `api_key` —— 一旦检测到即告警。

附加防御：运行目录 `~/.scoot/` 期望 `0700`；日志与审计对 token 一律脱敏（`****`）。

## Skill 机制

Scoot 通过 **skill** 扩展能力，无需重新编译核心二进制。一个 skill 就是 `~/.scoot/skills/<name>/` 下的一个目录：

```text
<skill>/
  SKILL.md      必需：YAML front-matter(name, description, [when_to_use], [allowed_tools]) + 正文指令
  scripts/      可选：经工具沙盒执行的脚本（同样受硬超时约束）
  references/   可选：按需加载的参考资料
  assets/       可选：模板等资源
```

**渐进式披露**：启动时只读取每个 skill 的 `name`+`description` 建轻量索引并注入上下文；当任务匹配某 skill 时，才按需加载它的正文与资源——既能无限扩展能力，又不会一次性挤爆上下文。skill 携带的脚本一律经统一工具沙盒执行，不得绕过沙盒或越权。详见 [`ROADMAP.md`](./ROADMAP.md#方向与意图)。

## 子系统状态

| 子系统 | 入口 | 状态 |
| --- | --- | --- |
| CLI / 参数解析 | `src/main.zig` | ✅ 可用（含 `config` 命令；`-e` 单次执行已端到端打通；REPL 为占位） |
| 运行目录解析 | `src/paths.zig` | ✅ `~/.scoot` + `SCOOT_HOME` 覆盖可用；建目录待实现 |
| 配置加载 | `src/config.zig` | 🚧 结构 + 默认值可用，JSON 加载待实现 |
| 密钥管理 | `src/secret.zig` | 🚧 env 来源可用，文件(0600)/命令待实现 |
| LLM 适配（OpenAI） | `src/llm.zig` | ✅ HTTP 往返 + 强制 json_schema/strict + 防弹解析（含测试）；🚧 流式/Tool Calling 待实现 |
| Skill 机制 | `src/skill.zig` | 🚧 类型 + 注册表骨架，发现/加载待实现 |
| 认知流引擎（ReACT / Plan） | `src/agent.zig` | ✅ 单轮闭环（chat→防弹解析→落 Session，`-e` 端到端可用）；🚧 多轮 + 工具循环待实现 |
| 会话（短期记忆载体） | `src/session.zig` | ✅ 内存记录 + JSONL 序列化（含测试）；🚧 落盘持久化待实现 |
| 调度引擎（every/at/cron） | `src/schedule.zig` | 🚧 增删可用，时间循环待实现 |
| 审计日志 | `src/audit.zig` | 🚧 基础写入可用 |
| 执行沙盒（工具集） | `src/tools/` | ✅ `bash` 硬超时 + 输出上限 + cwd（含测试）；🚧 file / search / http 待实现 |

## 设计原则（节选）

- **防御优先于智能**：所有模型响应必须穿过严苛的 JSON Schema 校验才能落地为动作。
- **可审计胜过黑盒**：每一次思考与工具调用都留痕，可完整回溯。
- **稳定胜过功能堆叠**：长效守护的内存平稳、零泄漏、不卡死压倒一切短期便利。
- **轻量与简洁**：即插即用的单体二进制，无臃肿运行时依赖。

## 非目标（铁律）

不引入图形界面 · 不适配非 OpenAI 协议 · 不搞复杂云端同步 · 绝不信任未校验的模型输出 · 不为功能数量牺牲单体简洁。详见 [`ROADMAP.md`](./ROADMAP.md#非目标铁律)。

## 文档

- [`ROADMAP.md`](./ROADMAP.md) —— 项目画像、目标状态、非目标与方向。
- [`AGENT.md`](./AGENT.md) —— 给 AI Agent / 贡献者的工程约定与红线。

## 许可证

待定（TBD）。
