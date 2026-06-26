# Daemon 生命周期

Scoot 的 daemon 模式是一个用于调度任务的前台长运行进程。它不会自行 fork 到后台；如果需要后台托管，应交给 `systemd`、`launchd`、`tmux` 或 shell job 这类外部 supervisor。

daemon 模式面向配置好的 scheduled jobs，不面向临时单个 prompt。想立即执行一个任务时，
使用 `scoot -e "<goal>"`。想让 Scoot 持续轮询 `[[schedule.jobs]]`，并需要
pid/state、`daemon status`、`daemon stop` 支持时，使用 `scoot daemon run`。
如果触发时间应由外部调度器负责，优先使用 `scoot schedule run --ticks 1`。

## 命令

```sh
scoot daemon status
scoot daemon run
scoot daemon run --ticks 3
scoot daemon stop
```

`daemon run` 要求 `schedule.enabled=true`。它会加载合法的 `schedule.jobs`，在 Scoot 运行目录下写入生命周期状态，安装 SIGTERM/SIGINT 处理器，并运行与 `schedule run` 相同的无人值守调度循环。

`daemon status` 打印最近一次记录的 daemon 状态，报告 Scoot 自己写入的 state 文件和 pid 文件，并在有 pid 可用时探测进程是否仍然存活。

`daemon stop` 读取 `state/daemon.pid`，但只有 `state/daemon.json` 同时显示 daemon 处于 `running` 且 pid 一致时才发送 SIGTERM。state 缺失或 pid 不一致会被视为陈旧 pid 文件，只清理不发信号。运行中的 daemon 会完成当前 tick，写入 stopped 状态，并删除 pid 文件。如果已经有 job 正在执行，信号会被记录，循环会在该 job 返回后退出。

## 运行时文件

```text
~/.scoot/
  logs/audit.jsonl
  state/daemon.json
  state/daemon.pid
  state/sessions/
```

`state/daemon.json` 记录：

- 生命周期格式版本，
- 状态：`running` 或 `stopped`，
- pid，
- 启动、更新、停止时间戳，
- 停止原因，
- schedule job 数量与 poll 间隔，
- scheduled job 仍然走正常 policy gate 的说明。

`state/daemon.pid` 在 `daemon run` 活跃时存在，正常关闭时会删除。如果进程崩溃，下次 `daemon run` 会发现上次状态仍是 `running`，先打印重启恢复警告，再写入新的状态。

## 恢复契约

Scoot 不会在进程死亡后恢复一个执行到一半的模型回合。恢复策略刻意保守：

- 已完成的 session 保留在 `state/sessions/`，
- 已 flush 的 audit 事件保留在 `logs/audit.jsonl`，
- `at_unix` 和 `every_sec` 的运行时内存状态在重启后重置，
- config 仍然是 job 是否存在的唯一事实来源，
- 过期的 `running` daemon 状态会被视为上次未干净停止，并被新的 daemon run 覆盖。

## 安全与资源边界

scheduled job 保持既有无人值守安全规则：`guarded` 会被矫正为有效 `readonly`；`unrestricted` 必须在 job 配置中显式声明。skill 指令和脚本不会绕过 policy gate。

每个 scheduled job 使用可重置 scratch arena，并在 job 边界写入 session/audit 状态。本版本中日志与 session 文件仍是 append-only；长期运行部署应先通过外部 logrotate 或定期清理维护 `logs/` 和 `state/sessions/`，直到内建 retention policy 落地。
