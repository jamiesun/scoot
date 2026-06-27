# Agent 计算单元（Wasm 工具包）

**状态：核心静态校验 + 独立 host。** 核心 `scoot` 二进制依旧**不**加载或执行 Wasm；可选的
`scoot-wasm` 二进制在使用 `-Dwasm-host=true` 构建后，可以执行当前的整数、浮点与 WASI host 子集。
完整参考见 [`docs/WASM_TOOLS.md`](https://github.com/jamiesun/scoot/blob/main/docs/WASM_TOOLS.md)；本页是概览。

目标是为第三方工具提供一个小巧、本地、**可审查**的边界 —— 刻意比 MCP 或 Wassette 更小 —— 使一个包在引入任何运行时*之前*就能被检视、其请求的权限被理解。

## 定位：这是 Agent 计算单元，不是「残缺的 Wasm」

Scoot 刻意只借用 Wasm 的一部分，并**不**以追求完整 Wasm 规范或 Component Model 为目标。这是**选择，不是缺陷**。这里的扩展单位是 **Agent 计算单元**：一个封闭的、纯数据变换沙箱，唯一通道只有 stdin（输入）、stdout/stderr（输出）、argv（配置）和进程退出码。它没有文件、网络、环境变量、时钟或随机数权限 —— 任何此类 import 都会 trap。它的输出是 `(stdin, argv)` 的纯函数；如果某个单元需要时间戳、种子或 nonce，由 host 以输入字节传入，绝不作为环境系统调用提供。

「Wasm」仍是底层机制，并保留现有标识符（`wasm_tool`、`wasm-tools check`、`wasm_host`）。「Agent 计算单元」是用来理解*它为何而存在*的视角：一个小巧、可审查、确定性的计算单位，agent 调用它而无需授予它任何环境权力。

## 信任边界与官方立场

Scoot 对计算单元的安全保证**不是**「我们读你的代码并判断好坏」。人工或 LLM 审查只是建议性的，可被混淆或供应链投毒绕过。真正的保证是沙箱：即便是恶意单元，也只能变换它自己的输入，因为 host 不授予任何环境权限。爆炸半径由 Scoot 愿意运行的范围决定，与包出自谁手、如何落到磁盘无关。

因此，这是设计使然：

- **Scoot 永不获取或执行远程代码。** 没有 `scoot install user/repo`，没有 registry，也没有任何针对 skill 或计算单元的远程代码加载路径。包只通过用户自身的常规可信操作（clone、copy、解压）落到磁盘。
- **任何替你获取并运行代码的第三方工具都不是 Scoot**，也不在 Scoot 的安全保证范围内。一个名为 `scoot-installer` 之类的包装器只代表它自己，不代表本项目。
- **透明是确定性的，而非主观的。** `scoot wasm-tools check` 静态校验包结构、拒绝路径与符号链接逃逸、强制能力子集规则；审计日志则记录 agent 实际运行的每一个单元。

## 包布局

```text
tool/
  component.wasm
  manifest.toml
  policy.toml
  schema/
    input.json
    output.json
```

校验一个包 —— 只读，绝不运行 Wasm：

```sh
scoot wasm-tools check path/to/tool
```

该校验解析元数据与 schema、核验被引用文件存在、拒绝不安全路径（绝对路径、`..`、隐藏段、盘符前缀、空段），
并校验 `component.wasm` 的字节码结构（magic、version、section、LEB128 长度与基础索引/数量一致性）；
不会执行 Wasm。

需要执行时显式构建独立 host：

```sh
zig build -Dwasm-host=true
scoot-wasm check path/to/module.wasm
scoot-wasm run path/to/module.wasm add 2 40
scoot-wasm wasi path/to/module.wasm [args...]
```

在 `run` 或 `wasi` 执行模块前，host 会验证当前支持的函数体子集：operand/control stack
形状、block/loop/if 签名、分支 label、调用签名、local/global 访问、memory/table 是否存在，
以及不可变 global 写入。

仓库内置了一个完整压缩插件示例、一个可复制模板，以及第二个确定性的 redactor compressor：

```sh
zig build wasm-compressor-example wasm-plugin-template wasm-redactor-compressor
scoot wasm-tools check examples/wasm-compressor
scoot wasm-tools check examples/wasm-plugin-template
scoot wasm-tools check examples/wasm-redactor-compressor
printf '%s\n' '{"version":1,"kind":"compressor","keep_recent":2,"elided_count":3,"elided_bytes":1200,"messages":[]}' \
  | scoot-wasm wasi examples/wasm-compressor/component.wasm
scoot-wasm wasi examples/wasm-redactor-compressor/component.wasm \
  < examples/wasm-redactor-compressor/fixtures/request.json
```

新增 compressor 包时优先从 `examples/wasm-plugin-template` 复制。`scripts/check-wasm-examples.sh`
会构建 host 与示例、校验包边界，并运行代表性的 WASI 执行 smoke check。

## Manifest 与 Policy

`manifest.toml` 声明身份、入口、schema 和**请求的**能力：

```toml
kind = "tool"
name = "calculator"
description = "Evaluate simple math expressions"
entry = "call"
component = "component.wasm"
input_schema = "schema/input.json"
output_schema = "schema/output.json"
capabilities = ["compute"]
```

为兼容旧包，`kind` 默认是 `tool`。外部上下文压缩器复用同一个静态包边界，但需要设置
`kind = "compressor"`；Scoot 核心仍不会加载或执行 Wasm。

`policy.toml` 声明实际**授予**的能力，且必须是 manifest 的**子集** —— 包不能悄悄获得它未声明的权限：

```toml
capabilities = ["compute"]
```

能力名：`compute`（纯 CPU，无 I/O）、`read`、`write`、`net_read`、`net_write`。独立 host
当前只暴露最小 WASI preview1 的 stdin/stdout/stderr/argv/proc-exit 子集；环境变量、时钟、
随机数、文件与网络权限均未实现。

## Agent 调用

`wasm_tool` 是 Agent 的原生动作，用于运行 compute-only 本地包。它让 Wasm 执行
脱离 `bash`：模型只提供包路径和 JSON 输入，host argv 则保持为可信运行时配置。

```json
{ "action": "wasm_tool", "action_input": "{\"package\":\"examples/wasm-plugin-template\",\"input\":{\"expr\":\"1+2\"}}" }
```

该动作复用 package 校验，要求 `entry = "_start"`，并且只运行 `policy.toml` 仅授予
`compute` 的包。在 `guarded` 与 `readonly` 下，包路径必须是项目相对路径，不能包含
绝对路径、`..`、`~` 或 `$` 展开。使用默认 host 配置时，Scoot 会先尝试与当前
`scoot` 二进制同目录的 `scoot-wasm`，找不到再回退 PATH。

## 计算单元如何被触发（与被发现）

存在两条不同的触发路径，区别在于**是谁决定**运行一个单元：

**1. `kind = "tool"` —— 模型驱动、按需触发。** 工具包只有在模型于 ReACT 循环中输出一个 `wasm_tool` 步骤时才会运行（见上）。随后 Scoot 才做 guard、校验与执行。触发者是模型。

这带来一个重要后果：**Scoot 不会自动发现或广告具体的包。** system prompt 只描述了通用的 `wasm_tool` 动作，但从不列出任何具体包名或路径。与 skill 不同——skill 的 `name` 与 `description` 会被注入上下文做渐进式披露——Wasm 包没有这一层广告机制。模型只会调用那些它**被告知路径**的包，告知来源只有：

- 用户 prompt 里点明路径（「用 `./wasm/json-query` 这个包」）；
- 一个 **skill**，其 `SKILL.md` 指示 agent 用某个具体包路径调用 `wasm_tool`，并说明何时使用；或
- 上下文 / instructions 中已携带该路径。

实际上这意味着：一个 `tool` 包最好**与一个广告它的 skill 一起发布**——skill 提供名字、描述，以及裸 `wasm_tool` 动作所缺的「何时该用」触发点。一个只装在磁盘、既无 skill 也不被 prompt 提及的包，会永远不被调用，因为没有任何东西告诉模型它存在。

**2. `kind = "compressor"` —— host 驱动、自动触发。** 压缩器包**不是**由模型选择的。当会话超出预算、且配置了 `agent.compactor = "plugin:<name>"` 时，Scoot 的上下文压缩逻辑会**自动**运行它，失败则回退 `extractive`/`drop`。模型压根看不到它；单靠配置就接入了。

| 包类型 | 触发者 | 时机 | 需要广告？ |
| --- | --- | --- | --- |
| `tool`（经 `wasm_tool`） | 模型 | ReACT 某一轮 | **需要** —— 靠 prompt 或 skill，否则从不被调用 |
| `compressor` | Scoot host | 上下文超预算时 | 不需要 —— 只看 `agent.compactor` 配置 |

## Schema

`schema/input.json` 与 `schema/output.json` 是工具 I/O 的 JSON Schema。校验器当前只检查两者存在且为合法 JSON；运行时强制将基于同样的文件构建。

## 推荐的计算单元（值得优先开发哪些）

一个计算单元只有同时具备三项内建工具或 shell 一行命令无法兼得的属性时，才真正值得存在：**确定性**输出（`(stdin, argv)` 的纯函数，便于审计与复现）、**在 `readonly` 与定时任务下可用**（这些场景 `bash` 被拒绝），以及**零外部依赖**（目标机器上无需 `jq`、`python`、`node`）。如果 `bash` 一行就能随手干、又不在乎确定性，那它就不是个好的计算单元。

按这把尺子，最值得先做的高杠杆单元是：

**第一梯队 —— 覆盖面最广、最可复用：**

- **结构化数据查询与转换** —— `jq` 子集，加上 JSON ↔ YAML ↔ TOML ↔ CSV 互转、字段抽取、pretty/minify。Agent 几乎每轮都在处理结构化数据，而 `jq` 在目标机器上常常没装。
- **安全表达式 / 计算器** —— 把算术或逻辑表达式求值为确定结果。它兜住了模型最不可靠、又绝不能算错的事（预算、单位换算、求和），实现却极小且纯粹。
- **哈希与编解码** —— `sha256`/`sha1`、base64、hex、URL 编解码、校验和比对。用于核验下载产物、解码配置；纯计算、零依赖。

**第二梯队 —— 契合 Scoot 的防御性定位：**

- **密钥脱敏器**，做成 `kind = "compressor"` 插件（而非 `tool`），复用已有的 compressor 边界，在文本进入会话历史或审计日志前抹掉 token、密钥与 PII。这是与 Scoot 密钥安全铁律最契合的一类单元。
- **unified diff / patch** —— 对两份输入计算 diff，或把 patch 应用到文本，让 Agent 以确定性方式推理改动，而不是「在脑子里手算」。
- **token 计数 / 上下文预算器** —— 估算 token 数与行/词/字节统计，给 Agent 一把具体尺子，呼应 Scoot 自身的观测裁剪与上下文压缩纪律。

**不建议开发 —— 这些要么与沙箱冲突，要么重复内建工具：**

- **任何需要联网的**（抓取器、API 客户端、webhook）。沙箱没有 socket 权限，会 trap 掉此类 import；内建的 `http_request` 动作已在策略与 SSRF 护栏下接管出站 HTTP。
- **任何遍历或修改文件系统的**（目录遍历、文件移动、批量编辑）。沙箱不授予任何文件系统访问；内建的 `grep`、`glob`、`outline` 与 `file_*` 工具已在路径限定下覆盖了发现与编辑。
- **时钟、时间戳、UUID 或随机数生成器。** 沙箱会 trap 掉 `clock_time_get` 与 `random_get`，所以它们的输出无法是 `(stdin, argv)` 的纯函数。若某个单元确实需要时间戳、种子或 nonce，必须由 host 以输入字节传入 —— 绝不能作为环境系统调用读取。
- **grep 或正则引擎。** Scoot 已在 `grep` 背后内置线性时间、ReDoS 免疫的正则引擎；Wasm 重实现只会更大、更弱，不会更好。
- **有状态或「安装器」类单元**，企图在多次运行间缓存、获取或持久化数据。计算单元是无状态变换；持久化与拉取属于用户自身的常规可信操作，不属于沙箱。

## 非目标（v0）

不做 OCI registry 或远程安装、不依赖 MCP/Wassette、不做授权 UI，默认不给文件/网络/环境访问。先用 JSON 字符串，WIT 绑定靠后。Scoot 自己掌握发现、策略映射与审计身份 —— 为日后采用 Component Model/WIT 留出空间，而不把它变成审查的前置条件。
