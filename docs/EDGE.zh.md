# scoot-edge：可选的舰队代理边界

English version: [EDGE.md](EDGE.md)

状态：**仅 E0 设计边界。** 目前还没有任何 `scoot-edge` 代码。按项目的扩展工作流，本文在写任何代码**之前**先钉死协议形态、授权模型与不可让步的红线。它必须在 E1 之前完成评审与签字。

## 一句话讲明白

现在每台装了 Scoot 的机器都是一座孤岛。想知道它在干啥、想给它派个活，只能一台台 SSH 上去。`scoot-edge` 就是给每台 Scoot 配一个**小信使**，让一个中央控制台能够够得着整个机器舰队。

```text
        管理中心（你将来要开发的控制台）
          ↑      ↑      ↑
          │      │      │   小信使主动往上打电话、往上报告
        edge   edge   edge
          │      │      │
        scoot  scoot  scoot      你的机器们
```

整套设计就靠三句大白话撑着：

1. **信使只往外拨号，中心永远拨不进来。** 你的机器不开任何新端口，所以装了 `scoot-edge` 也不会给黑客多出一扇门可敲。
2. **信使只做两件事，而且越不了界。** 它把健康状况和审计日志*往上报*（只上传、绝不回写本地），也能*接一个活*——但中心给的是一句**人话目标**、不是命令。中心把目标当数据交过来，Scoot 仍然像你本地亲手输入一样去审查它。中心没法让你机器直接跑一条原始 shell 命令。
3. **中心的权力有上限，而且上限你说了算。** 默认情况下，中心派来的活只能**只读**——看得了、动不了。想放开更多，必须在你机器上手动 opt-in。中心永远没法给自己提权。

承诺三背后有一句必须说实话的话：**只读**意味着任务改不了你的机器，但它**读到的东西仍然会往上流到中心**——这正是“派活”的意义所在，任务结果（stdout、session、audit）会被回传上去。所以只读任务是一条**读取并上报**的通道，而非密封沙箱。只把 edge 指向一个你愿意让它读到这些内容的中心。

本文档剩下的部分，就是这三句承诺背后的精确契约。

## 定位

`scoot-edge` 是一个**可选、独立、默认不安装**的伴生二进制，让远端管理中心能够观测并（可选地）向某个 Scoot 实例派发任务，**且不链接进核心、不改动 local-first 核心**。

它沿用与独立 `scoot-wasm` host 完全一致的姿态：单独编译的目标，核心从不 import 它，只在进程边界上被调用。只要你不安装 `scoot-edge`，Scoot 就和今天一模一样——完全本地、无出站连接、无监听、无新增可信面。

| 维度 | scoot-wasm（先例） | scoot-edge |
| --- | --- | --- |
| 在核心二进制内 | 否，独立 | 否，独立 |
| 默认安装 | 否 | 否 |
| 与 scoot 的耦合 | 仅 host argv 边界 | 仅公共发射接口 |
| 缺席时对核心的影响 | 无 | 无 |

## 部署假设

`scoot-edge` 面向**轻量级 VPC 内网部署**，不面向公网。管理中心位于私有网络可达。这让协议刻意保持小巧（朴素的 HTTP 动词 + TLS 之上的 NDJSON 形态，不引入重型 RPC 栈），而安全的重量由**授权模型**承担，而非由传输层承担。

VPC 假设**不会**削弱本地授权天花板：即便是完全可信的网络，在权限语义上也按不可信对待（纵深防御）。

## 拓扑

- **Edge 出站拨号连接中心，中心是服务端。** Edge **不开任何 inbound listener**。这是标准的舰队代理模式，也是跨 NAT、非容器舰队的必需形态。它同时意味着安装 `scoot-edge` 不会给主机新增任何入站可信面。
- 中心无需知道每个 edge 的地址，也从不反向连接。

## 传输与认证

- **强制 HTTPS，即便在内网。** 传输由服务端 TLS 加密：edge 校验中心证书。这**不是 mTLS**——客户端身份由 token（见下）携带，而非客户端证书，从而把证书管理压缩到单张服务端证书。
- **逐节点 bearer token。** 每个 edge 节点携带**自己的** token，经 `Authorization: Bearer <token>` 发送。逐节点（而非舰队共享）token 让中心能够单独识别、限流、吊销某个节点，而无需轮换整个舰队。
- **token 来源沿用现有 secret 机制：** 环境变量 → `0600` 权限的 token 文件 → 凭证命令。token **绝不编译进二进制、绝不提交、绝不打印、绝不写入任何审计日志**（约束 7）。
- **帧格式为 NDJSON**（每行一个 JSON 对象），与 `scoot serve` 和 audit JSONL 格式一致。不用 gRPC、不用 protobuf、不用 WebSocket 帧。

## 消息信封

每条 wire 消息共用一个信封：

```json
{"v":1,"type":"status|audit_batch|job|job_event","node_id":"n-7a3","sent_ts":1719600000000,"body":{}}
```

- `v` 锁定协议版本。
- `node_id` 是稳定的节点身份（配置而来，并与 token 关联）。
- `sent_ts` 为 Unix 毫秒，与 audit 的 `ts` 字段对齐。

## 阶段 E1 —— 仅报告态遥测（append-only）

Edge 上报两类记录。两者皆**只追加**（只会往后添，不改也不回放），且**绝不回灌到本地状态**。

### status（心跳）

数据源：`daemon status`、audit 计数、本地 config 策略。

```json
{"v":1,"type":"status","node_id":"n-7a3","sent_ts":1719600000000,"body":{
  "scoot_version":"...","edge_version":"...",
  "daemon":{"state":"running","clean_prev_stop":true,"since":1719500000000},
  "policy_ceiling":"readonly",
  "audit_stats":{"run":12,"tool_call":40,"policy_deny":1,"system_error":0}
}}
```

- `policy_ceiling` 就是本地的 `edge.max_job_policy`——中心派发任务的天花板，而非交互式或单次运行的 mode。未配置 E2 时，它上报默认的 `readonly`。
- `audit_stats` 是导出量：edge 通过扫描 `logs/*.jsonl` 自行累加，因为 `audit.Stats` 是 per-`Logger` 的内存计数，并不持久化。

### audit_batch（append-only 日志搬运）

数据源：只读 `logs/*.jsonl`。

**把 audit 搬出本机是一次数据搬移决策，不是 no-op。** 约束 7 保证的是 Scoot **自己的**后端密钥绝不写入 audit；它**不**保证 audit `msg` 正文不含敏感内容。`observation` 与 `tool_call` 事件会原样携带工具输出：`file_read` 的文件内容、`bash` 的命令输出、`http_request` 的响应体。所以 `audit_batch` 会把一次 run 观测到的一切搬到中心。因此 edge 把 audit 搬运按 fail-closed 处理：

- `edge.ship_audit` 默认**关**。不开它时，遥测只有 `status` 心跳（只有计数，没有正文）。
- 开启后，`edge.audit_ship_kinds` 是一份显式的事件类型白名单，默认只含低内容类型（`run`、`final`、`policy_deny`、`system_error`），并**默认排除 `observation`**。
- 可选的 `edge.audit_redact` 规则集在 edge 侧、发送前应用；脱敏失败则丢弃该记录，而不是原样外发。

```json
{"v":1,"type":"audit_batch","node_id":"n-7a3","sent_ts":1719600000000,"body":{
  "cursor":{"file_gen":3,"byte_from":40960,"byte_to":61440,"seq_to":149},
  "events":[]
}}
```

- **幂等游标**（让同一段数据不会被算两次）。audit `seq` 是 **per-Logger 实例**单调的，且轮转后从 0 重新开始，因此仅靠 `seq` 不是安全的去重键。游标采用 `{file_gen, byte_offset}`（单调的轮转代数 + 字节偏移），`seq` 作二次校验。中心只追加存储，重放同一区间为 no-op。由此实现 at-least-once 投递 + 幂等 apply。
- **`file_gen` 目前在核心里并不存在；它是 E1 的硬前置，而非便利项。** 当前轮转（`src/audit.zig` 里的 `audit.jsonl → audit.jsonl.1`）只保留**一个**备份并删除旧的 `.1`，没有任何代数计数器。照现状，一个在两次 edge 轮询之间轮转两次的节点，会让中间那段在中心视角里**永久丢失**，所以 E1 绝不能在这个基底上一边搬运 audit 一边声称不丢。已接受的修法是**对 shipping 感知的保留**：核心增加一个单调轮转代数，并把已轮转的 audit 段保留到 edge ack 之后（受可配置上限约束）。一旦超过上限，edge 向上发出显式的 `audit_gap` 标记，而不是静默跳过——可见的 gap 比看不见的 gap 安全。
- **在“对 shipping 感知的保留”落地之前，audit 搬运按设计保持关闭**（只有 `status` 心跳）。这让 E1 的投递承诺保持诚实，而不是在一个会丢数据的基底上宣称 at-least-once。
- 在 VPC 部署下，E1 可保持为简单的周期性 `POST /telemetry`。在 E2 引入任务派发之前，edge 无需长轮询。

## 阶段 E2 —— schema 化、幂等的任务派发

中心通过 edge 出站发起的长轮询 lease 下发任务：

```
GET /jobs/lease?node=n-7a3&capacity=2
Authorization: Bearer <token>
→ 200，NDJSON body，0..N 个 job 信封
```

```json
{"v":1,"type":"job","node_id":"n-7a3","sent_ts":1719600000000,"body":{
  "job_id":"j-91","idem_key":"...","kind":"run",
  "goal":"summarize today's audit anomalies",
  "requested_policy":"readonly","deadline_ts":1719600060000,"max_retries":0
}}
```

整个安全模型集中在以下规则：

| 规则 | 机制 | 守住的约束 |
| --- | --- | --- |
| `kind` 是封闭枚举，当前仅 `run` | edge 把 `goal` 当作**不透明数据**交给 `scoot -e`，绝不从 wire 合成 shell 或 `eval`。 | 绝不执行未校验的模型输出 |
| 策略只能降不能升 | `effective = correctUnattended(privilegeMin(requested, 本地 edge.max_job_policy))`。特权序是显式格 `readonly ⊑ guarded ⊑ unrestricted`——**不是** `Mode` 枚举的声明序，所以用数值 `@min` 会反掉。`correctUnattended` 把 `guarded → readonly`，因为 edge 任务是无人值守的。`edge.max_job_policy` 是**纯本地**旋钮，默认 `readonly`；wire 永远无法抬高它。 | 本地 config/策略即天花板 |
| 幂等 apply（同一个活重复派来只跑一次） | edge 在 `~/.scoot/edge/` 下维护有界、持久化的 `idem_key` 集。重投的任务回 ack 旧结果，而非重跑。 | at-least-once、幂等 apply |
| 全程 provenance | 每个派发任务记入 edge 侧 `logs/edge-audit.jsonl`（谁派的、`idem_key`、`effective_policy`、关联 `session_id`），并经 `session_id` 与 Scoot 自身 run audit join。 | 完整 provenance 审计 |
| 受限工作目录 | edge 把子进程的 cwd 钉死到 `edge.job_root`（一个专用、默认为空的目录），绝不用主机根或 `$HOME`。由于 `readonly` 的读取约束是**相对 cwd 的**（`evaluateReadPath`），正是这一点让 `readonly` 意味着*这个目录*而非*整个文件系统*。 | 本地 config/策略即天花板 |

**钳制是一个真实且缺失的原语——E2 没它绝不能上线。** 今天 `scoot -e` 以*本地 config* 策略（`cfg.tools.policy`）运行，且与调度任务不同，它**得不到**无人值守的 `guarded → readonly` 纠正（那条纠正在 `schedule.zig` 的 `effectiveMode` 里，而一次性路径从不调用它）。所以在本地默认是 `guarded` 的主机上，一条天真的 `scoot -e "<goal>"` 会以放行 shell、写、网络的方式运行——而不是 `readonly`。edge 必须通过一个无人值守一次性钳制（见下方核心前置）来启动任务，由它**在子进程内对本地 config 强制天花板**，从而 argv 永远只能*降*策略。一个有 bug 或受中心影响的 edge 在命令行上传入更高策略时，必须被子进程忽略。

任务生命周期经同一条 append-only 遥测通道回报：

```json
{"v":1,"type":"job_event","node_id":"n-7a3","sent_ts":1719600000000,"body":{
  "job_id":"j-91","phase":"accepted|running|done|failed|rejected",
  "session_id":"...","effective_policy":"readonly",
  "reject_reason":"policy_ceiling|bad_schema|at_capacity"
}}
```

## 授权模型（需要签字的决策）

| 阶段 | 中心能做什么 | 风险 | 建议 |
| --- | --- | --- | --- |
| E1 仅报告 | 默认只有 `status` 心跳；audit 日志搬运仅在显式开启时 | 较低，但 audit 搬运会把 observation 数据（文件内容、命令输出）搬出本机 | 先发 `status`；在轮转对 shipping 感知之前，保持 audit 搬运关闭 |
| E2 任务派发 | 派发由 edge 经 Scoot 启动的任务 | confused deputy（edge 可能被人当枪使） | 仅在显式 config + 策略天花板之后 |

**已签字的默认值：**

- **Edge 派发任务默认 `readonly`，由钳制强制——不是自动继承的。** 调度器的 `guarded → readonly` 纠正在 `schedule.zig` 里，并**不**作用于一条裸的 `scoot -e`。在核心里那个子进程内的无人值守钳制落地之前，readonly 默认是无支撑的，E2 保持阻塞。
- **抬高天花板必须本地显式 opt-in，而且唯一有意义的抬高就是那一大跳。** 对*无人值守*任务，`guarded` 会塌缩成 `readonly`，所以 `edge.max_job_policy = guarded` 相对 `readonly` 什么都没多给。真正能给 edge 任务写或网络能力的唯一设置是 `edge.max_job_policy = unrestricted`——一次刻意的、全程审计的、需本地签字的跳变，中间没有安全档。中心永远无法越过本地天花板，也没有任何 wire 字段能抬高策略。

## 可靠性原语

- **硬超时全覆盖**（约束 6）：connect 超时、单请求超时、长轮询挂起上限、每任务 `deadline_ts`。
- **有界在途队列。** edge 在 lease 时声明剩余 `capacity`；满载时施加反压（`at_capacity`），而非超额承接。
- **重连**采用有界指数退避 + jitter + 上限。
- **遥测仅在中心 ack 之后推进游标**，因而既不丢记录也不重复 apply。

## 与 Scoot 核心的接口契约

edge **只经公共发射接口与只读日志**驱动 Scoot。它不得 import `src/internal.zig`，也不获得任何特殊能力。窄口径的公共包根（`src/root.zig`）保持为契约。

| Wire 操作 | 用到的公共面 |
| --- | --- |
| `status` | `daemon status`（以及未来的 `--json` 形态）、config 读 |
| `audit_batch` | 只读 `logs/*.jsonl` |
| `job kind=run` | 子进程 `scoot -e "<goal>"`，**通过无人值守一次性钳制**启动（天花板在子进程内对本地 config 强制），并把 cwd 钉死到 `edge.job_root` |
| job 结果 | 子进程 exit code + stdout + 生成的 session / audit |

### 核心前置与改进

其中三项是**阻塞性前置**，不是可选的打磨：没有它们，edge 无法兑现自己的安全与投递承诺。它们仍作为独立、本身有用的核心改动来实现，但 E1/E2 受其门控。

1. **（E1 前置）** 机读 status：`daemon status --json` / `doctor --json`。`status` 心跳不得依赖解析人读文本。
2. **（E2 前置——拱心石）** 无人值守一次性策略钳制，使 edge 启动的 `scoot -e` 可证明处于或低于 `readonly` 天花板，且在子进程内对本地 config 强制。没有它，整个 readonly 默认授权模型都是无支撑的。**E2 在它之前绝不能上线。**
3. **（E1 前置）** 对 shipping 感知、轮转稳定的 audit：单调轮转代数 + 字节偏移，并把已轮转段保留到 ack 之后（有界，超界时发出显式 `audit_gap` 标记）。当前单备份的破坏性轮转无法承载 at-least-once 承诺。在它落地前，audit 搬运保持关闭。
4. **（契约）** 把 `serve` NDJSON 方法集作为稳定契约固化；`scoot-edge` 复用它的帧格式，而非它的通道。

## 非目标（红线，评审中强制执行）

- **绝不双向状态对账。** 中心绝不下发“你的 config / 状态应当是 X”，edge 也绝不把中心状态回灌到主机。这条线让 `scoot-edge` 不会退化成复杂云端同步。
- **绝不开放入站任意代码通道。** `kind` 是封闭枚举；goal 是数据，仍由 Scoot 经 ReACT、策略门和 JSON schema 校验。
- **中心不能抬高本地策略天花板。** `edge.max_job_policy` 纯本地；默认 `readonly`。
- **绝不做 GUI / web 控制台。** 管理中心 UI 在本仓库范围之外。
- **绝不内部链接、绝不编入或打印密钥。** token 来自 env / `0600` 文件 / 凭证命令，且绝不出现在 audit 中。
- **绝不引入 mesh / 厂商专有传输。** 仅 HTTPS + NDJSON。
- **默认绝不把 audit 正文搬出本机。** 只有 `status` 计数会外发；`observation` / `tool_call` 正文仅在显式 `edge.ship_audit` 加白名单之后才外发，因为它们可能携带文件内容与命令输出。只读从不意味着“什么都不离开本机”。

## 阶段划分

- **E0：** 本边界文档（双语）+ ROADMAP 修订 + 授权模型签字。**不写代码。**
- **E1：** `scoot-edge` 骨架（独立构建目标，默认关闭）+ 经 HTTPS 的 `status` 心跳。需要前置 #1（`daemon status --json`）。audit 日志搬运在 **E1 内部延后**，直到前置 #3（对 shipping 感知的轮转）落地；在此之前 E1 只搬运计数、不搬正文，且 `edge.ship_audit` 默认关闭。
- **E2：** 在显式 config + 策略天花板 + provenance 审计之后，做 schema 化、幂等的任务派发。**硬门控于前置 #2**（子进程内的无人值守策略钳制）与 cwd confinement（`edge.job_root`）。edge 任务默认 `readonly`；唯一的抬高是本地 `edge.max_job_policy = unrestricted`。
- **E3：** 打包（install 脚本 opt-in、Homebrew、apt）与重连 / 反压加固。
