# CLI 参考

```text
scoot [options] [command]
```

不带命令时，Scoot 启动交互式 REPL。全局选项可以位于命令之前或之后。运行目录默认是
`~/.scoot`，可用 `--scoot-home` 或 `SCOOT_HOME` 覆盖。

## 全局选项

| 选项 | 说明 |
| --- | --- |
| `-e, --eval <prompt>` | 运行单个目标至完成，打印答复，然后退出。 |
| `--retries <N>` | `-e` 模式下针对瞬时后端错误的重试次数（默认 `2`，`0` 禁用）。 |
| `--unattended` | `-e` 一次性运行表示**无人值守**：把策略钳制到 `edge.max_job_policy`（默认 `readonly`），并把 `guarded` 矫正为 `readonly`。 |
| `--policy <mode>` | `-e` 一次性策略覆盖（`guarded`/`readonly`/`unrestricted`）；带 `--unattended` 时只能降到 `edge.max_job_policy` 天花板以下。 |
| `--session-id <id>` | 用于 `-e`：把 session 文件名固定为指定值，而非自动生成的 id，方便外部调用方用自己的 job id 关联一次运行。 |
| `--scoot-home <dir>` | 覆盖运行目录。优先于 `SCOOT_HOME`。 |
| `--trace` | 把 ReACT 执行轨迹打印到 **stderr**（答复/对话仍在 stdout）。`-e` 与交互式 REPL 模式均可用。 |
| `--ticks <N>` | 用于 `schedule run` / `daemon run`：运行 `N` 个轮询周期后退出（默认 `0` = 永久运行）。 |
| `--json` | 用于 `daemon status`：打印机器可读的状态快照，而非人类可读文本。 |
| `-h, --help` | 显示用法。 |
| `-v, --version` | 显示版本。 |

## 命令

### 选择运行模式

| 模式 | 工作来源 | 退出行为 | 什么时候用 |
| --- | --- | --- | --- |
| `scoot -e "<goal>"` | 命令行 prompt。 | 返回一个答案后退出。 | 要立即执行一个任务。 |
| `scoot serve` | stdin 上的 NDJSON 请求。 | 一直运行到 stdin 关闭。 | 本地 app 需要长期 stdio peer。 |
| `scoot schedule run --ticks 1` | 配置里的 `[[schedule.jobs]]`。 | 轮询一次调度器后退出。 | cron、systemd timer 或 CI 负责调度时间。 |
| `scoot daemon run` | 配置里的 `[[schedule.jobs]]`。 | 默认持续运行。 | Scoot 负责调度循环，外部 supervisor 负责保活。 |

`daemon run` 不是 `-e` 的快捷写法：它不接收命令行里的临时 prompt，而是加载
配置任务、检查触发器、写入 daemon pid/state 文件，并使用无人值守任务的安全规则。

### `repl`（默认）

```sh
scoot              # or: scoot repl
```

启动交互式的读取-求值-打印循环（Read-Eval-Print loop）。输入一个目标，看着 agent 工作，
得到答复，再循环。输入 `/exit` 退出。每个提示都会在所配置的策略下运行完整的 ReACT 循环。
加上 `--trace` 可把每一轮的 ReACT 轨迹流式输出到 **stderr**，对话仍保留在 stdout：

```sh
scoot --trace            # 交互式 REPL，执行轨迹输出到 stderr
```

### `-e, --eval` — 一次性

```sh
scoot -e "count the Zig source files in this repository"
scoot --retries 4 -e "summarize README.md"
scoot --trace -e "list the largest files under src/"
```

运行一个目标，并 **仅把最终答复** 打印到 stdout——非常适合脚本与管道。`--trace` 会在
stderr 上附加逐步轨迹，便于调试而不污染答复。轨迹会在每个阻塞步骤**之前**先打印实时进度
标记——调用模型前打印 `thinking:`，执行工具前打印 `running: <工具>`——这样等待期间也能看到
agent 当前在做什么，轨迹不会显得卡死。`--retries` 控制对瞬时后端失败（限流、5xx）的重试。

对于**无人值守**（无人在场）的运行，请加上 `--unattended`。它会**在子进程内**把有效策略计算为 `correctUnattended(privilegeMin(requested, edge.max_job_policy))`：本地的 `[edge].max_job_policy` 天花板（默认 `readonly`）封顶，`guarded` 被矫正为 `readonly`，命令行永远只能把策略*降*下来，绝不能抬到天花板之上。可选的 `--policy <mode>` 覆盖请求的 mode——带 `--unattended` 时会被钳制到天花板，不带 `--unattended`（有人在场）时则作用于交互式 `tools.policy` 默认值且可以抬高。这正是可选的 `scoot-edge` fleet 伴生程序启动任务所经的钳制，因此一个有 bug 或受中心影响的 edge 无法越权。抬高无人值守天花板需要刻意设置本地 `edge.max_job_policy = unrestricted`。

```sh
scoot --unattended -e "总结所有未完成的 TODO"                   # 钳制到 readonly
scoot --unattended --policy unrestricted -e "..."             # 除非 edge.max_job_policy=unrestricted，否则仍是 readonly
```

用 `--session-id <id>` 把 session 文件名固定下来，而不是让 Scoot 自动生成，
这样外部调用方就能用自己的 job id 关联一次运行。可选的 `scoot-edge` 伴生程序
正是这样把一个派发出去的任务和它产生的 session 关联起来的（`--session-id job-<job_id>`）：

```sh
scoot --session-id my-fixed-id -e "summarize README.md"
```

### `serve` — stdio app-server

```sh
printf '%s\n' '{"id":"1","method":"session.list","params":{}}' | scoot serve
```

以前台进程运行本地 app 集成用的 stdio 协议。协议是换行分隔 JSON：stdin 每一行
是一条请求，stdout 每一行是一条响应；响应会带回同一个 `id`、`ok`，以及
`result` 或 `error`。

支持的方法：

| 方法 | 参数 | 结果 |
| --- | --- | --- |
| `run` | `{ "goal": "..." }` | `{ "session_id": "...", "reply": "..." }` |
| `session.list` | `{}` | `{ "sessions": [...] }` |
| `session.get` | `{ "id": "..." }` | `{ "id": "...", "messages": [...] }` |
| `audit.query` | `{ "session_id": "..." }` | `{ "session_id": "...", "events": [...] }` |

`serve` 不打开 TCP/UDS，不做鉴权，不把自己后台化，也不做多任务并发状态机。
进程生命周期、重启和日志归调用方或 supervisor 管理。

### `setup`

```sh
scoot setup
scoot --scoot-home /opt/scoot/instance-a setup
```

通过几步交互式提问生成配置目录，让你无需手写 TOML 即可快速搭建一个实例。它会询问
**配置目录**（默认 `~/.scoot`，或解析出的 `--scoot-home` / `SCOOT_HOME`）、后端的
`base_url` 与 `model`、**token 来源**（`env`、一个 `0600` 文件，或一条命令）、`max_turns`
以及工具 `policy`。随后创建运行目录树（`skills/`、`logs/`、`state/sessions/`）并写出
`config.toml`。

token 值本身 **绝不会写入 `config.toml`**——只记录其来源。如果选择文件来源并粘贴了
token，Scoot 会把它写入 token 文件并收紧为 `0600`，以便[密钥加载](configuration.md)能够接受。
若 `config.toml` 已存在，会先请你确认再覆盖。提示未覆盖到的选项，可在生成后直接编辑该文件
（参见 `config.example.toml`）。

由于每个生成的目录都是自包含的，`setup` 是在同一台主机上运行 **多个隔离实例** 的快捷路径——
让每个实例各自指向自己的 `--scoot-home` / `SCOOT_HOME`。每个运行目录只允许一个守护进程的规则
参见[调度与守护进程](scheduling.md)。

### `config`

```sh
scoot config
```

打印解析出的运行目录与后端配置。密钥被 **脱敏**——只显示解析出的来源，绝不显示 token 值。
用它来确认当前生效的是哪个配置文件与运行目录。

### `doctor`

```sh
scoot doctor
scoot --scoot-home /tmp/scoot-test doctor
```

运行本地健康检查且不打印任何密钥：运行目录与权限、配置来源、后端前置条件、解析出的
**密钥来源**、技能发现、调度状态，以及审计日志路径。出现异常时先运行它。

### `policy check`

```sh
scoot policy check <action> <input> [--mode <mode>]
```

针对某个策略模式对工具动作进行试运行（dry-run），并解释它会被 **允许** 还是 **拒绝**，
而不实际执行任何东西。`<mode>` 为 `guarded`（默认）、`readonly` 或 `unrestricted`。

```sh
scoot policy check bash "rm -rf /" --mode guarded      # deny
scoot policy check bash "ls -la"   --mode readonly     # deny (no shell in readonly)
scoot policy check file_read '{"path":"README.md"}' --mode readonly  # allow
scoot policy check skill '{"name":"demo"}' --mode readonly           # allow (native)
scoot policy check recall '{"query":"old"}' --mode readonly          # allow (native)
```

这是理解策略模型最快的方式——参见
[执行策略与安全](policy.md)。

### `skills`

```sh
scoot skills                       # list discovered skills (name / description / dir)
scoot skills check [dir]           # validate a skill dir, or all search paths if omitted
scoot skills pack <dir> [out.tar]  # validate and export a reviewable tar package
```

- `skills` 打印解析出的搜索路径与每个被发现的技能。
- `skills check [dir]` 校验结构，**不执行** 任何技能脚本。一个有效的技能拥有
  带非空 `name` 与 `description` 的 `SKILL.md`；可选的
  `capabilities`、`allowed_tools` 与 `scope` 元数据也会被校验。
- `skills pack` 先校验再导出一个带 `.scoot-skill.json` 评审
  manifest 的 tar。它包含常规的非隐藏文件，拒绝符号链接等不安全类型，且不授予任何策略绕过。

撰写细节参见 [技能](skills.md)。

### `wasm-tools check`

```sh
scoot wasm-tools check <dir>
```

静态校验本地 Wasm 工具包的边界——`manifest.toml`、
`policy.toml`、被引用的 JSON schema，以及安全的相对路径。它 **绝不
加载或执行** Wasm。参见 [Wasm 工具包](wasm-tools.md)。

### `schedule`

```sh
scoot schedule list                 # show configured jobs and their state
scoot schedule run                  # run the scheduler loop (foreground)
scoot schedule run --ticks 1        # run one poll cycle then exit
```

列出或运行调度任务。无人值守的运行强制执行 fail-closed 的 `readonly`
安全级别。运行需要 `schedule.enabled = true`。参见
[调度与守护进程](scheduling.md)。

### `daemon`

```sh
scoot daemon status                 # print last recorded daemon state
scoot daemon status --json          # 机器可读的状态快照
scoot daemon run                    # foreground long-running scheduler
scoot daemon run --ticks 3          # run three poll cycles then exit
scoot daemon stop                   # state/pid 一致时才发送 SIGTERM
```

`daemon status --json` 把同样的状态打印成单个 JSON 对象而非人类可读文本——
适合写脚本，也是可选的 `scoot-edge` 伴生程序用来采集心跳数据的方式。

面向调度任务的前台长运行模式。它写入
`state/daemon.json` 与 `state/daemon.pid`，安装 SIGTERM/SIGINT 处理器，并
保持无人值守的 `readonly` 安全规则。它 **不会** fork 到后台——
请用 `systemd`、`launchd`、`tmux` 或 shell 作业来实现。每个运行目录只允许一个守护进程；
若要在同一主机上运行多个，请为每个实例分配各自的 `--scoot-home` / `SCOOT_HOME`
（可用 `scoot setup` 来搭建）。参见
[调度与守护进程](scheduling.md)。

## 退出行为与管道

`-e` 模式把最终答复写入 **stdout**，把诊断/轨迹写入
**stderr**，因此你可以把 Scoot 组合进 shell 管道：

```sh
answer=$(scoot -e "print today's date in ISO 8601")
scoot --trace -e "audit open ports" 2> trace.log
```
