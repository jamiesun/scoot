# 调度与守护进程

Scoot 可通过前台守护循环运行**无人值守**的调度任务。自主执行**默认关闭** —— 必须显式启用。完整的生命周期/恢复参考见 [`docs/DAEMON.md`](https://github.com/jamiesun/scoot/blob/main/docs/DAEMON.md)。

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
scoot daemon stop               # SIGTERM a running daemon
```

`daemon run` 加载有效任务、写入生命周期状态、安装 SIGTERM/SIGINT 处理器，并运行与 `schedule run` 相同的循环。`stop` 时，守护进程跑完当前一轮、写入 stopped 状态、删除其 pid 文件。

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
