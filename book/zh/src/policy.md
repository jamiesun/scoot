# 执行策略与安全

Scoot 绝不让未经校验的模型输出直接落到你的系统上。每个工具动作在执行前都要经过**策略门（policy gate）**。本页讲清三种模式、判定模型、默认 guarded 加固，并**坦诚**说明该策略能保护什么、不能保护什么。

## 三种模式

按限制力从弱到强排列：`unrestricted` < `guarded` < `readonly`。

| 模式 | Shell（`bash`） | 本地写 | 网络 | 本地读 | 适用场景 |
| --- | --- | --- | --- | --- | --- |
| `unrestricted` | 允许 | 允许 | 允许 | 允许 | 完全信任目标；仍会审计。 |
| `guarded` *(默认)* | 除灾难性外允许 | 允许，默认收口在项目根内 | 允许，默认带内部地址防护 | 允许 | 有人值守的交互式使用。 |
| `readonly` | **拒绝** | **拒绝** | **拒绝** | 允许（受限） | 无人值守/不可信；fail-closed 安全。 |

在配置里设定模式（`[tools] policy = "..."`），或用 `scoot policy check` 测试任意动作。未知值回落到 `guarded`（坏配置绝不能*放松*策略门）。`yolo` 是 `unrestricted` 的别名。

## 各模式的行为

### `guarded` —— 交互式绊线

`guarded` 是交互式 CLI/REPL 的默认模式。它**不是沙盒**，而是一条绊线：一份灾难性 shell 命令的拒绝清单。日常工作照常放行，让你在有人值守时真正把活干完。

`bash` 命令会先归一化（折叠空白、转小写——挫败 `rm  -RF   /` 之类的花招），再与一份刻意从紧的灾难性清单比对并拦截，包括：

- 递归删除根/家目录/`*`（`rm -rf /`、`rm -rf ~`、`rm -rf *`、`--no-preserve-root`）；
- 磁盘/文件系统摧毁（`mkfs`、`dd ... of=/dev/...`、`> /dev/sd...`）；
- 管道接 shell 的远程执行（`| sh`、`| bash`）；
- 电源状态变更（`shutdown`、`reboot`、`poweroff`、`halt`、`init 0/6`）；
- fork 炸弹，以及鲁莽的 `chmod 777 /` / 递归 `chown`。

内建工具（`file_*`、`grep`、`glob`、`http_request`）在 `guarded` 下放行，且受自身的路径/大小/超时上限约束。默认情况下，`guarded` 还会把 `file_write`/`file_edit` 收口在项目根内，并阻止 `http_request` 访问环回、内网、链路本地和云元数据地址。

### `readonly` —— fail-closed 安全原语

`readonly` 才是**真正的**安全边界，也是无人值守任务的结构性前提。它 fail-closed（失败即关闭）：

- **`bash` 一律拒绝** —— shell 组合语义太宽，无法靠白名单精确防住；改用 `file_read`/`grep`/`glob`。
- **所有写一律拒绝**（`file_write`、`file_edit`）。
- **所有网络一律拒绝** —— 即便是只读的 `GET`/`HEAD`，以防本地数据经请求 URL 外带。
- **本地读放行但受路径收口**（见下）。
- 在全面禁 `bash` 之上，灾难性 shell 模式仍会被拦截。

`readonly` 下，本地读路径还会被额外校验：禁绝对路径、禁 `~`/`$VAR` 展开、禁 `..` 逃逸，并拒绝常见**敏感片段**（`.env`、`.ssh`、`id_rsa`、`id_ed25519`、`.netrc`、`credentials`、`secret`、`token` 等）。这把读取收口在项目工作目录内，远离明显的密钥文件。

### `unrestricted` —— 不设限，但仍审计

完全不设策略限制（别名 `yolo`）。每个动作仍会写入审计日志，但不拦截任何东西。仅在你完全信任目标时使用。

## `skill` 动作是原生的

通过 [`skill` 动作](skills.md) 读取技能的指令/资源是一种**原生只读能力，刻意绕过策略门** —— 故技能即便在 `readonly` 下也可用。安全由执行环节把关（目录收口、读取被审计），而非由策略把关。技能随后让模型去*执行*的一切（shell、写、网络）仍走正常策略门。

正因为它绕过策略门，`skill` 动作会**放宽 `readonly` 的读取面**。在上文 `evaluateReadPath` 把关的读取（项目工作目录内、非敏感、禁 `..`/绝对路径）之外，它还能读取**任意已注册技能目录下的文件**：

1. `[skills] include_project_skills = true` 时的 `<cwd>/.agents/skills`
2. `[skills] include_agents_skills = true` 时的 `~/.agents/skills`
3. `~/.scoot/skills`
4. `[skills]` 中声明的 `extra_paths`

每次读取仍被收口在命中的那个技能自身目录内（拒绝绝对路径、`..`，以及解析后逃逸该目录的 symlink），并被审计。对无人值守 / `readonly` 运行的现实含义：**只安装你信任的技能。** 被污染或恶意的技能包即便在 `readonly` 下也能把它自身目录的内容暴露给模型 —— 这是读取边界的既定组成部分，而非绕过，因此不要把 `readonly` 当成对抗不可信技能的沙盒。

## `recall` 动作是原生的

`recall` 只读取当前会话的 transcript 归档，没有文件、网络或进程副作用，因此
同样是原生能力，并在 `readonly` 下放行。它不像 `skill` 那样扩大文件系统读取面；
它只能返回本会话 transcript 中已经存在的内容。

## 默认 guarded 加固

两个开关用于收紧 `guarded` 模式。二者默认 `true`，且**仅在 `guarded`** 生效（`readonly` 已对写与网络 fail-closed）。只有在明确接受更宽的写入或网络面时才应关闭。

### `confine_writes`

把 `file_write`/`file_edit` 收口在项目根内：禁绝对路径、`..` 逃逸、shell 风格的 `~`/`$VAR` 展开。这能挡住不可信模型写入诸如 `$HOME/.ssh/authorized_keys`。它**不**拒绝敏感*文件名* —— 项目内的风险是位置逃逸，而非命名。

```toml
[tools]
policy = "guarded"
confine_writes = true
```

### `block_internal_http`

一道 SSRF 防护：拒绝 `http_request` 访问环回、内网、链路本地与云元数据地址。这是基于字面 IP 段与已知内网名的**启发式**判断 —— 它**不**解析 DNS，故 DNS 重绑定仍可绕过。要真正的网络隔离，请用 `readonly` 或外部网络沙盒。

```toml
[tools]
policy = "guarded"
block_internal_http = true
```

## 判定模型

两条互补的校验共享同一套 `Mode` 语义：

- **Shell 命令**（`bash`）按字符串分析：归一化、与灾难性拒绝清单比对，然后放行（`guarded`）或拒绝（`readonly`）。
- **内建工具**按*能力*分类 —— `read`、`write`、`net_read`、`net_write` —— 因为它们的语义无需解析命令字符串即静态已知。这正是策略门不随工具增多而变复杂的原因：新增的读工具复用同一条 `read` 判定。它也保证内建工具**无法绕过 `readonly`**。

## 策略钩子（可选，纵深防御）

默认情况下策略门完全内建。若需要组织级拒绝清单、密钥扫描或对接中央策略引擎，可以挂载一个**可选的外部策略钩子**（issue #136），无需重新编译。它**不配置即不启用**：

```toml
[tools.policy_hook]
package = "/opt/scoot/policy/org-guard"   # 本地 Wasm 工具包，manifest kind = "policy"
host = ["scoot-wasm", "wasi", "{component}"]  # 默认取解析后的 wasm_host
timeout_ms = 5000                          # 默认取 tools.timeout_ms
```

该钩子复用与 `wasm_tool`、压缩器插件相同的纯数据变换插件边界 —— `manifest.toml` + argv 宿主模板 + 经 realpath 校验的包 —— 而非裸 `/bin/sh` 调用，从而保持确定性与小攻击面。它从 stdin 接收待决判定的 JSON（`{"version":1,"kind":"policy","action","input","mode","cwd"}`），并打印 `{"decision":"allow"}` 或 `{"decision":"deny","reason":"..."}`。

它的姿态刻意是单向且 fail-closed 的：

- **仅在内建判定为 `allow` 后才被咨询。** 钩子只能把 `allow` 收紧为 `deny`，**永远不能放松内建的 `deny`**。内建拒绝会在钩子运行前短路返回。
- **失败即拒绝。** 包缺失/非法、manifest kind 不符、任何非 `compute` 能力、进程启动失败、超时、非零退出、输出过大或格式错误 —— 一律按 `deny` 处理，并像其他拒绝一样写入审计。

## 坦诚的威胁模型

在敌对环境中依赖 Scoot 前请先读这段：

- **`guarded` 不是安全边界。** 拒绝清单总能被有决心或敌对的提示绕过。别据此产生虚假信心 —— 它是为了在有人值守时拦住*意外*与明显灾难。
- **`readonly` 才是 fail-closed 原语。** 它在构造上禁 shell、禁写、禁网络，是让无人值守执行站得住脚的依据。任何不可信目标、调度任务或守护进程都应优先选它。
- **真正的隔离仍要靠操作系统。** 要强保证，请把 `readonly` 与 OS 级沙盒（容器、seccomp、网络命名空间、只读挂载）结合。Scoot 的策略是纵深防御，不是牢笼。

## 调度任务会被矫正

无人值守任务在结构上强制安全：配置为 `guarded` 的任务在执行时会被**矫正为等效 `readonly`**。若你接受风险，必须在任务配置里显式写 `unrestricted`。见[调度与守护进程](scheduling.md)。

## 检视判定

用 `policy check` 对任意动作在任意模式下做演练 —— 不会真正执行：

```sh
scoot policy check bash "rm -rf /"                  --mode guarded   # deny
scoot policy check bash "ls -la"                    --mode readonly  # deny
scoot policy check file_write '{"path":"/etc/x"}'   --mode readonly  # deny
scoot policy check file_read  '{"path":"README.md"}' --mode readonly # allow
scoot policy check http_request '{"method":"GET","url":"http://169.254.169.254/"}' --mode guarded
```
