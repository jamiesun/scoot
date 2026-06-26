# 调度与守护进程

Scoot 可通过前台守护循环运行**无人值守**的调度任务。自主执行**默认关闭** —— 必须显式启用。完整的生命周期/恢复参考见 [`docs/DAEMON.md`](https://github.com/jamiesun/scoot/blob/main/docs/DAEMON.md)。

## 应该使用哪种模式

在 `-e`、`schedule run` 和 `daemon run` 之间选择时，先看这张表：

| 模式 | 是否读取配置任务 | 默认是否常驻 | 触发时间由谁负责 | 适用场景 |
| --- | --- | --- | --- | --- |
| `scoot -e "<goal>"` | 否 | 否 | 调用方 | 人或脚本要执行一个即时任务。 |
| `scoot schedule run --ticks 1` | 是 | 否 | cron、systemd timer、CI | 外部调度器周期性唤起 Scoot。 |
| `scoot schedule run` | 是 | 是 | 当前终端或进程管理器 | 简单前台调度循环，不需要 daemon 状态文件。 |
| `scoot daemon run` | 是 | 是 | Scoot 循环 + systemd/launchd 等托管 | 长期无人值守调度，并需要 pid/state/stop/status 支持。 |

`-e` 和 scheduled execution 是不同入口。`-e` 会立即运行命令行传入的 prompt，
并使用普通配置里的工具策略。调度任务来自 `[[schedule.jobs]]`，由 `every_sec`、
`at_unix` 或 `cron` 触发，并使用无人值守安全规则：job 的 mode 默认是
`readonly`，`guarded` 会被矫正为有效 `readonly`。

只有当你需要进程托管时，`systemd` 才有意义。使用 `scoot daemon run` 时，
Scoot 负责调度循环，systemd 负责启动、重启、日志、环境变量、资源限制和
SIGTERM 停止。如果你希望 systemd 也负责触发时间，请使用 systemd timer 调用
`scoot schedule run --ticks 1`。

## 启用调度

```toml
[schedule]
enabled = true
poll_ms = 1000

[[schedule.jobs]]
id = "disk-check"
goal = "Inspect disk usage and summarize anomalies"
every_sec = 300
mode = "readonly"
```

每个任务需要**恰好一个**触发器：

| 触发器 | 含义 |
| --- | --- |
| `every_sec` | 按固定间隔触发（秒）。 |
| `at_unix` | 在某个固定 Unix 时间点触发一次。 |
| `cron` | 按 5 字段 UTC cron 表达式触发。 |

触发器为零个或多个的任务非法，会被跳过并告警。每个字段见[配置 → `[[schedule.jobs]]`](configuration.md)。

## 无人值守安全

调度任务在**结构上**强制安全，而非靠约定：

- 任务的 `mode` 默认为 `readonly`；
- `guarded` 任务在执行时被**矫正为等效 `readonly`**；
- 只有显式设置 `unrestricted` 才会生效，意味着你接受无人值守的写/网络风险。

这意味着无人值守任务不会意外写盘或触网，除非你刻意选择。见[执行策略与安全](policy.md)。

## 运行调度器

```sh
scoot schedule list             # show jobs and whether each is ACTIVE/INACTIVE
scoot schedule run              # run the loop in the foreground
scoot schedule run --ticks 1    # run exactly one poll cycle, then exit
```

`--ticks N` 便于测试和 cron 驱动的一次性调用：轮询 `N` 次后退出（`0` = 持续运行）。

## 守护进程模式

`daemon` 是调度任务的长驻前台进程。它**不**派生到后台 —— 需要后台托管时请配合 `systemd`、`launchd`、`tmux` 或 shell 作业。

```sh
scoot daemon run                # foreground; requires schedule.enabled = true
scoot daemon run --ticks 3      # run three poll cycles then exit
scoot daemon status             # print the last recorded daemon state
scoot daemon stop               # running state 与 pid 一致时才 SIGTERM
```

`daemon run` 加载有效任务、写入生命周期状态、安装 SIGTERM/SIGINT 处理器，并运行与 `schedule run` 相同的循环。`stop` 时，Scoot 只有在 `state/daemon.json` 显示 `running` 且匹配 `state/daemon.pid` 时才发信号；否则把 pid 文件视为陈旧文件。运行中的守护进程会跑完当前一轮、写入 stopped 状态、删除其 pid 文件。

### 每个运行目录只允许一个守护进程

守护进程的存活通过每个运行目录下的 `state/daemon.json` 与 `state/daemon.pid` 跟踪。当**同一**目录已有守护进程存活时再启动 `daemon run` 会被拒绝，因此两个守护进程绝不会共享同一套调度与状态目录：

```text
[scoot] refusing to start: detected daemon already running (pid=… started_at=…).
Run `scoot daemon stop` first.
```

该守卫用信号 `0` 探测所记录的 pid；崩溃残留的过期 pid 会被视为非正常停止，并在下一次运行时恢复。

要在**同一主机上运行多个守护进程**，给每个实例分配各自的运行目录，它们便完全隔离 —— 配置、任务、会话、日志与生命周期文件各自独立：

```sh
scoot --scoot-home /opt/scoot/web   setup     # 搭建实例 "web"
scoot --scoot-home /opt/scoot/batch setup     # 搭建实例 "batch"

SCOOT_HOME=/opt/scoot/web   scoot daemon run &
SCOOT_HOME=/opt/scoot/batch scoot daemon run &
```

`scoot setup` 是搭建每个目录的最快方式。由于单守护进程守卫是按目录隔离的，不同的 home 永不冲突。

### 生命周期文件

```text
~/.scoot/
  logs/audit.jsonl       # audit events
  state/daemon.json      # status, pid, timestamps, stop reason, job count, poll interval
  state/daemon.pid       # present while running; removed on clean shutdown
  state/sessions/        # per-run session transcripts
```

若进程崩溃，下一次 `daemon run` 会发现上次状态仍为 `running`，并在写入新状态前打印一条重启恢复告警。

### 恢复契约

恢复刻意保守 —— Scoot 在进程死亡后**不**续跑进行到一半的模型回合：

- 已完成的会话保留在 `state/sessions/`；
- 已落盘的审计事件保留在 `logs/audit.jsonl`；
- `every_sec` / `at_unix` 的运行时计时在重启后重置；
- 配置仍是「有哪些任务」的唯一真相源；
- 残留的 `running` 状态被视为不干净的停止并被覆盖。

## 示例：一个 systemd 单元

```ini
[Unit]
Description=Scoot daemon
After=network-online.target

[Service]
ExecStart=/usr/local/bin/scoot daemon run
Restart=on-failure
Environment=SCOOT_HOME=%h/.scoot

[Install]
WantedBy=default.target
```

本版本中日志与会话文件均为追加写；长期部署请在外部轮转或清理 `logs/` 与 `state/sessions/`。
