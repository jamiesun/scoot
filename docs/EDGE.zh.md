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

`scoot-edge` 面向**轻量级 VPC 内网部署**，不面向公网。管理中心位于私有网络可达。这让协议刻意保持小巧（明文 HTTP + NDJSON 形态，不引入重型 RPC 栈），而安全的重量由**授权模型**承担，而非由传输层承担。

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

### audit_batch（append-only 日志搬运）

数据源：只读 `logs/*.jsonl`。由于 audit 事件在构造上已脱敏（约束 7），搬运它们无需在 edge 侧做任何额外脱敏即安全。

```json
{"v":1,"type":"audit_batch","node_id":"n-7a3","sent_ts":1719600000000,"body":{
  "cursor":{"file_gen":3,"byte_from":40960,"byte_to":61440,"seq_to":149},
  "events":[]
}}
```

- **幂等游标**（让同一段数据不会被算两次）。audit `seq` 是 **per-Logger 实例**单调的，且日志会轮转，因此仅靠 `seq` 不是安全的去重键。游标采用 `{file_gen, byte_offset}`（轮转代数 + 字节偏移），`seq` 作二次校验。中心只追加存储，重放同一区间为 no-op。由此实现 at-least-once 投递 + 幂等 apply。
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

整个安全模型集中在以下四条规则：

| 规则 | 机制 | 守住的约束 |
| --- | --- | --- |
| `kind` 是封闭枚举，当前仅 `run` | edge 把 `goal` 当作**不透明数据**交给 `scoot -e`，绝不从 wire 合成 shell 或 `eval`。 | 绝不执行未校验的模型输出 |
| 策略只能降不能升 | `effective = min(本地 edge.max_job_policy, requested)`。`edge.max_job_policy` 是**纯本地 config** 旋钮，默认 `readonly`。wire 永远无法抬高它。 | 本地 config/策略即天花板 |
| 幂等 apply（同一个活重复派来只跑一次） | edge 在 `~/.scoot/edge/` 下维护有界、持久化的 `idem_key` 集。重投的任务回 ack 旧结果，而非重跑。 | at-least-once、幂等 apply |
| 全程 provenance | 每个派发任务记入 edge 侧 `logs/edge-audit.jsonl`（谁派的、`idem_key`、`effective_policy`、关联 `session_id`），并经 `session_id` 与 Scoot 自身 run audit join。 | 完整 provenance 审计 |

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
| E1 仅报告 | 只读 status / audit / health | 最低 | 先发 |
| E2 任务派发 | 派发由 edge 经 Scoot 启动的任务 | confused deputy（edge 可能被人当枪使） | 仅在显式 config + 策略天花板之后 |

**已签字的默认值：**

- **Edge 派发的任务默认 `readonly`。** 由于 edge 任务是无人值守的，它们映射到 Scoot 现有的"无人值守执行被纠正为 `readonly`"规则。
- **抬高天花板必须本地显式 opt-in。** 只有本地 `edge.max_job_policy`（如 `guarded`）才能为 edge 派发任务抬高天花板，且中心永远无法越过它。不存在任何能抬高策略的 wire 字段。

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
| `job kind=run` | 子进程 `scoot -e "<goal>"`，带钳制的策略天花板 |
| job 结果 | 子进程 exit code + stdout + 生成的 session / audit |

### 小型、增量的核心改进（单独立 issue 跟踪）

这些对 edge 有帮助但本身独立合理。按 issue 边界，它们**不**折进 edge 工作：

1. 机读 status：`daemon status --json` / `doctor --json`。
2. 无人值守一次性运行的策略钳制，使 edge 启动的 `scoot -e` 可证明处于或低于 `readonly` 天花板。**这是 E2 上线前的前置件。**
3. 轮转稳定的 audit 搬运游标（字节偏移 + 轮转代数）。
4. 把 `serve` NDJSON 方法集作为稳定契约固化。

## 非目标（红线，评审中强制执行）

- **绝不双向状态对账。** 中心绝不下发"你的 config / 状态应当是 X"，edge 也绝不把中心状态回灌到主机。这条线让 `scoot-edge` 不会退化成复杂云端同步。
- **绝不开放入站任意代码通道。** `kind` 是封闭枚举；goal 是数据，仍由 Scoot 经 ReACT、策略门和 JSON schema 校验。
- **中心不能抬高本地策略天花板。** `edge.max_job_policy` 纯本地；默认 `readonly`。
- **绝不做 GUI / web 控制台。** 管理中心 UI 在本仓库范围之外。
- **绝不内部链接、绝不编入或打印密钥。** token 来自 env / `0600` 文件 / 凭证命令，且绝不出现在 audit 中。
- **绝不引入 mesh / 厂商专有传输。** 仅 HTTPS + NDJSON。

## 阶段划分

- **E0：** 本边界文档（双语）+ ROADMAP 修订 + 授权模型签字。**不写代码。**
- **E1：** `scoot-edge` 骨架（独立构建目标，默认关闭）+ 经 HTTPS 的仅报告态遥测（`status` + `logs/*.jsonl`）。
- **E2：** 在显式 config + 策略天花板 + provenance 审计之后，做 schema 化、幂等的任务派发。
- **E3：** 打包（install 脚本 opt-in、Homebrew、apt）与重连 / 反压加固。
