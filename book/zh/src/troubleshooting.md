# 故障排查与 FAQ

出问题时，先运行 `scoot doctor` —— 它会在不打印任何密钥的前提下检查运行目录、配置来源、密钥来源、技能发现、调度状态和审计路径。

## 诊断命令

```sh
scoot doctor                         # local health checks
scoot config                         # resolved runtime dir + backend (redacted)
scoot --trace -e "your goal"         # full ReACT trace on stderr
scoot policy check <action> <input> --mode <mode>   # why was this allowed/denied?
```

## 常见问题

### 「No home directory」/ 运行目录不对

Scoot 需要 `$HOME`（或 `SCOOT_HOME`）来定位 `~/.scoot`。在 `$HOME` 未设的精简环境里，传 `--scoot-home`：

```sh
scoot --scoot-home /var/lib/scoot doctor
```

`--scoot-home` 总是优先于 `SCOOT_HOME`。运行 `scoot config` 确认实际生效的目录。

### 后端认证失败 / 没有 token

Scoot 按 env → `0600` token 文件 → 凭证命令的顺序解析 token。先看 `doctor` 报告的是哪个来源，然后：

- 确保 `OPENAI_API_KEY`（或你的 `api_key_env`）在同一个 shell 里已导出；
- 若用 token 文件，它**必须是 `0600` 权限**，否则 Scoot 拒绝读取：`chmod 600 ~/.scoot/token`；
- 若用 `api_key_cmd`，确认该命令会打印 token 且非交互。

切勿把 key 放进 `config.toml`。见[配置 → 密钥](configuration.md)。

### HTTPS 后端的 TLS / 证书错误

精简/嵌入式镜像常缺系统根证书。把 `ca_file` 指向一个 PEM bundle：

```toml
[backend]
ca_file = "/etc/ssl/certs/ca-certificates.crt"
```

### 后端「Connection refused」

默认 `base_url` 是本地 Ollama 端点（`http://127.0.0.1:11434/v1`）。若你不跑 Ollama，请把 `base_url`/`model` 设成你真实的后端。确认该端点从 Scoot 所在主机/网络可达。

### 代理说它「不能」执行某命令

这通常是策略门，而非 bug。`readonly` 下按设计禁 `bash`、禁写、禁网络；`guarded` 下灾难性命令被拦。用 `policy check` 确认：

```sh
scoot policy check bash "the command" --mode readonly
```

如合适，把 `[tools] policy` 切到 `guarded`（交互式）或 `unrestricted`（完全信任）—— 见[执行策略与安全](policy.md)。

### `file_edit` 报匹配歧义/未找到

`file_edit` 要求 `old` 在文件中**恰好出现一次**。先 `file_read` 看清文件，再把更长、唯一的上下文片段拷进 `old`。

### 某个技能未被发现

- 看 `scoot skills`，确认解析出的搜索路径与发现结果。
- 确保 `[skills] enabled = true`。
- 校验该目录有合法 `SKILL.md`，且 `name` 与 `description` 非空：`scoot skills check path/to/skill`。
- 记住优先级 —— 同名时靠前者胜（`<cwd>/.agents/skills` > 可选的 `~/.agents/skills` > `~/.scoot/skills` > `extra_paths`）。

### 技能在 `readonly` 下用不了

能用 —— **读取**技能是原生的、与策略无关。技能随后让模型去*执行*的部分仍受策略门。若某技能的*动作*在 `readonly` 下被拦，那是预期行为；加载它的指令则不会。

### 调度任务从不触发

- `[schedule] enabled` 必须为 `true`。
- 每个任务需要**恰好一个**触发器；`schedule list` 会把非法任务标为 `INACTIVE`。
- `cron` 已解析但**暂不支持** —— cron 任务永不触发。
- 设为 `guarded` 的任务以等效 `readonly` 运行；若它似乎无法写或触网，那正是无人值守安全矫正。

### 运行因上下文预算提前中止

你设了 `[agent] context_budget_bytes`，且**压缩历史后**对话记录仍超预算——也就是预算过小，连最小保留集（system 提示 + 原始任务 + 最近若干回合）都放不下。调大预算（保持低于后端上下文窗口），或设为 `0` 关闭该检查（回合数仍受 `max_turns` 约束）。

### 代理循环不收尾

它撞到了 `max_turns`（默认 32）。调大 `[agent] max_turns`，或收窄目标。用 `--trace` 看它在哪打转。

## FAQ

**Scoot 会把我的代码发给第三方吗？**
只发给你配置的模型后端（`base_url`）。没有遥测、没有云同步，密钥绝不入日志。指向本地后端即可完全在端上运行。

**能完全离线用吗？**
能 —— 配一个本地 OpenAI 兼容后端（如 Ollama）。结构化工具不依赖任何外部命令。

**`guarded` 模式是沙盒吗？**
不是。它是拦意外的绊线。`readonly` 才是 fail-closed 安全原语；面对敌对输入请与 OS 级隔离结合。见[坦诚的威胁模型](policy.md)。

**日志和历史在哪？**
`~/.scoot/logs/audit.jsonl` 与 `~/.scoot/state/sessions/<id>.jsonl`。见[会话与审计](sessions.md)。

**什么是「plan 模式」？**
保留中，尚未实现。`default_mode` 目前接受 `goal`；`plan` 暂不改变执行。见[路线图](roadmap.md)。

**怎么更新？**
从源码重建（`git pull && zig build`）或安装更新的发布制品。见[安装](installation.md)。

**还是卡住？**
带 `--trace` 重跑，抓取 `scoot doctor` 输出，到项目仓库开一个 issue。
