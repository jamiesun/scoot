# Wasm 工具包

**状态：核心静态校验 + 独立 host。** 核心 `scoot` 二进制依旧**不**加载或执行 Wasm；可选的
`scoot-wasm` 二进制在使用 `-Dwasm-host=true` 构建后，可以执行当前的整数、浮点与 WASI host 子集。
完整参考见 [`docs/WASM_TOOLS.md`](https://github.com/jamiesun/scoot/blob/main/docs/WASM_TOOLS.md)；本页是概览。

目标是为第三方工具提供一个小巧、本地、**可审查**的边界 —— 刻意比 MCP 或 Wassette 更小 —— 使一个包在引入任何运行时*之前*就能被检视、其请求的权限被理解。

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
当前只暴露最小 WASI preview1 的 stdio/args/environ/clock/random/proc-exit 子集；文件与网络权限
尚未实现。

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

## Schema

`schema/input.json` 与 `schema/output.json` 是工具 I/O 的 JSON Schema。校验器当前只检查两者存在且为合法 JSON；运行时强制将基于同样的文件构建。

## 非目标（v0）

不做 OCI registry 或远程安装、不依赖 MCP/Wassette、不做授权 UI，默认不给文件/网络/环境访问。先用 JSON 字符串，WIT 绑定靠后。Scoot 自己掌握发现、策略映射与审计身份 —— 为日后采用 Component Model/WIT 留出空间，而不把它变成审查的前置条件。
