# 最佳实践案例

Scoot 最适合作为一个小型、可审计的 Agent 运行时，而不是泛用自动化平台。好的
部署方式要先把三条边界讲清楚：

- 谁负责触发：人、CI、cron/systemd timer，还是 `scoot daemon run`；
- Agent 能碰什么：`readonly`、`guarded`，还是显式 `unrestricted`；
- 密钥和状态放哪里：环境变量 / 文件 / 命令密钥，本地 JSONL 会话与审计日志。

下面 7 个案例是最值得优先支持和推荐的场景。

## 1. GitHub Actions 评审助手

当你需要只读总结、release note 草稿、changelog 检查或文档漂移报告时，CI 是
非常适合 Scoot 的场景：触发器已经由 GitHub 负责，checkout 是临时的，
`readonly` 可以避免意外写入，也能阻断 agent 工具通过网络外带。

这里用 `scoot -e`，不要用 `daemon run`。

```yaml
name: Scoot review

on:
  pull_request:
  workflow_dispatch:

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
    env:
      SCOOT_HOME: ${{ runner.temp }}/scoot
      OPENAI_API_KEY: ${{ secrets.LLM_KEY }}
      SCOOT_BACKEND_API_KEY_ENV: OPENAI_API_KEY
      SCOOT_BACKEND_BASE_URL: https://api.openai.com/v1
      SCOOT_BACKEND_MODEL: gpt-4o-mini
      SCOOT_TOOLS_POLICY: readonly
      SCOOT_AUDIT_TO_FILE: "true"
    steps:
      - uses: actions/checkout@v4
      - name: Install Scoot
        run: |
          tar -xzf scoot-linux-amd64.tar.gz
          install -m755 scoot/scoot /usr/local/bin/scoot
      - name: Generate review brief
        run: |
          scoot -e "Review this checkout. Summarize behavior changes, risky files, and missing docs/tests. Do not modify files." \
            | tee scoot-review.md
      - uses: actions/upload-artifact@v4
        with:
          name: scoot-review
          path: |
            scoot-review.md
            ${{ runner.temp }}/scoot/logs/
            ${{ runner.temp }}/scoot/state/sessions/
```

如果以后要把结果写回 PR 评论，建议作为单独的显式步骤处理。Scoot 负责生成分析
产物，GitHub 权限仍应保持最小化。

## 2. 无人值守运维简报

当你想每天或每小时从日志、配置文件、预生成状态快照中生成本地报告时，用这个
模式。Scoot 负责调度循环，`systemd` 只负责托管这个前台进程。

```toml
[schedule]
enabled = true
poll_ms = 1000

[[schedule.jobs]]
id = "ops-brief"
goal = "Inspect local logs, config files, and pre-generated status snapshots. Summarize anomalies and likely next checks. Do not write files or call the network."
cron = "0 8 * * *"
mode = "readonly"
```

```ini
[Unit]
Description=Scoot operations brief
After=network-online.target

[Service]
ExecStart=/usr/local/bin/scoot daemon run
Restart=on-failure
Environment=SCOOT_HOME=/var/lib/scoot

[Install]
WantedBy=multi-user.target
```

这是无人值守的默认推荐形态：`guarded` job 会被矫正为有效 `readonly`，
而 `readonly` 会拒绝 shell、写入和网络。
如果需要 `df`、`systemctl` 或厂商 CLI 的输出，请让外部固定任务先生成纯文本
状态快照，再让这个 readonly job 读取快照。

## 3. RouterOS 或容器探针

这个场景有价值，但不是默认安全场景。RouterOS 和容器探针通常需要访问网络，
而 scheduled `readonly` job 会按设计拒绝网络。如果要用 Scoot 做这类探针，
应先隔离运行环境，再显式授予网络能力。

推荐形态：

- 把 Scoot 放在只能访问目标管理网络的容器、VM 或 network namespace 中；
- 除 `SCOOT_HOME` 外，文件系统尽量只读挂载；
- RouterOS/API 凭据放在环境变量、token 文件或凭证命令中，不写进 goal；
- 探针命令必须有明确超时；
- 只有确实需要网络的那个 job 设置 `mode = "unrestricted"`。

```toml
[schedule]
enabled = true

[[schedule.jobs]]
id = "routeros-probe"
goal = "Run the existing read-only RouterOS/container probe script, interpret its output, and report anomalies. Do not change device configuration."
every_sec = 300
mode = "unrestricted"
```

关键点是：`unrestricted` 的权限很宽。必须先用操作系统和网络隔离把运行环境收窄，
再授予它。

## 4. Release 与 Changelog 预检

发布前可以用 `scoot -e` 检查当前 checkout，生成给人看的预检报告。通常应使用
`readonly`。

```sh
SCOOT_TOOLS_POLICY=readonly \
scoot -e "Prepare a release preflight: summarize commits since the last tag, check README/changelog consistency, list risky changes, and identify missing release notes."
```

好的输出应该包括：

- 用户可见行为变化；
- 应同步更新的文档；
- 可能缺失的测试；
- 打包或发布目标风险。

实际版本号 bump、打 tag、发布产物等动作应留在这个只读预检之外，除非你明确决定
再运行一个独立的 guarded / unrestricted 发布自动化。

## 5. 配置与安全姿态审计

当你想定期检查 Scoot 自己的运行姿态有没有漂移时，用这个模式。任务应读取配置、
运行 `doctor`、检查权限，并解释弱配置。

```sh
scoot doctor
scoot policy check bash "rm -rf /" --mode guarded
scoot policy check http_request '{"method":"GET","url":"http://169.254.169.254/"}' --mode guarded
```

也可以配置成定时本地简报：

```toml
[[schedule.jobs]]
id = "scoot-posture"
goal = "Inspect Scoot config, doctor output, and runtime files. Report weak permissions, disabled hardening, unknown config keys, and risky scheduled jobs."
cron = "30 7 * * *"
mode = "readonly"
```

这样可以发现配置漂移，同时不给 agent 写入权限。

## 6. Edge / NAS 健康看护

Scoot 的小型原生部署形态适合低资源主机：NAS、边缘 Linux 设备、实验室机器、
小型常开服务器。能用本地模型后端时优先使用本地后端，job 保持只读。由于
`readonly` 会拒绝 shell，应把日志和状态快照文件喂给 Scoot，而不是让它直接跑
系统探针命令。

```toml
[backend]
base_url = "http://127.0.0.1:11434/v1"
model = "qwen2.5"

[agent]
compactor = "extractive"
context_budget_bytes = 80000

[schedule]
enabled = true

[[schedule.jobs]]
id = "edge-health"
goal = "Inspect local logs, service files, and status snapshots. Summarize health risks for this edge host. Do not write files or call the network."
every_sec = 1800
mode = "readonly"
```

如果设备缺少系统根证书，又必须访问 HTTPS 后端，请设置 `ca_file`。

## 7. 项目本地 Runbook Skills

把项目内可复用的操作流程做成本地 skills：事故排查、发布检查清单解释、数据保留
审查、厂商专用诊断等。把说明放进仓库，让 runbook 和代码一起评审。

```text
.agents/skills/
  incident-triage/
    SKILL.md
    references/
      service-map.md
      escalation.md
```

```sh
scoot skills check .agents/skills/incident-triage
SCOOT_SKILLS_INCLUDE_PROJECT_SKILLS=1 \
scoot -e "Use the incident-triage skill to inspect this checkout and prepare a triage brief."
```

最佳实践：

- skill 指令要具体、可审查；
- 不要把密钥写进 skill 文件；
- 只在可信仓库中开启项目本地 skills；
- 生产工作优先使用项目本地 skills，而不是宽泛的用户全局 skills；
- 读取 skill 文件即使在 `readonly` 下也可用，但 skill 要求 Scoot 执行的任何动作
  仍然会经过正常 policy gate。

## 选择指南

| 需求 | 推荐模式 |
| --- | --- |
| 立即做一次分析 | `scoot -e` |
| CI 总结、PR / release 预检 | `SCOOT_TOOLS_POLICY=readonly` + `scoot -e` |
| 外部调度器负责触发时间 | `scoot schedule run --ticks 1` |
| Scoot 自己负责周期性本地任务 | systemd/launchd 托管 `scoot daemon run` |
| 网络探针 | 显式 `unrestricted` + OS / 网络隔离 |
| 不可信或无人值守本地检查 | `readonly` |
