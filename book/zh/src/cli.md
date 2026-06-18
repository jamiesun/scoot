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
| `--scoot-home <dir>` | 覆盖运行目录。优先于 `SCOOT_HOME`。 |
| `--trace` | 把 ReACT 执行轨迹打印到 **stderr**（答复/对话仍在 stdout）。`-e` 与交互式 REPL 模式均可用。 |
| `--ticks <N>` | 用于 `schedule run` / `daemon run`：运行 `N` 个轮询周期后退出（默认 `0` = 永久运行）。 |
| `-h, --help` | 显示用法。 |
| `-v, --version` | 显示版本。 |

## 命令

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
scoot daemon run                    # foreground long-running scheduler
scoot daemon run --ticks 3          # run three poll cycles then exit
scoot daemon stop                   # send SIGTERM to a running daemon
```

面向调度任务的前台长运行模式。它写入
`state/daemon.json` 与 `state/daemon.pid`，安装 SIGTERM/SIGINT 处理器，并
保持无人值守的 `readonly` 安全规则。它 **不会** fork 到后台——
请用 `systemd`、`launchd`、`tmux` 或 shell 作业来实现。参见
[调度与守护进程](scheduling.md)。

## 退出行为与管道

`-e` 模式把最终答复写入 **stdout**，把诊断/轨迹写入
**stderr**，因此你可以把 Scoot 组合进 shell 管道：

```sh
answer=$(scoot -e "print today's date in ISO 8601")
scoot --trace -e "audit open ports" 2> trace.log
```
