# Wasm 工具包

**状态：仅设计边界与静态校验。** Scoot 暂**不**执行 Wasm 工具。完整参考见 [`docs/WASM_TOOLS.md`](https://github.com/jamiesun/scoot/blob/main/docs/WASM_TOOLS.md)；本页是概览。

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

校验一个包 —— 只读，绝不加载或运行 Wasm：

```sh
scoot wasm-tools check path/to/tool
```

该校验解析元数据与 schema、核验被引用文件存在、拒绝不安全路径（绝对路径、`..`、隐藏段、盘符前缀、空段），
并校验 `component.wasm` 的字节码结构（magic、version、section、LEB128 长度与基础索引/数量一致性）；
不会执行 Wasm。

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

能力名：`compute`（纯 CPU，无 I/O）、`read`、`write`、`net_read`、`net_write`。首个迭代只预期 `compute`，且**当前没有任何能力授予运行时权限**，因为执行尚未实现。

## Schema

`schema/input.json` 与 `schema/output.json` 是工具 I/O 的 JSON Schema。校验器当前只检查两者存在且为合法 JSON；运行时强制将基于同样的文件构建。计划中的模型调用形态：

```json
{ "action": "wasm_tool", "action_input": "{\"tool\":\"calculator\",\"input\":{\"expr\":\"1+2\"}}" }
```

## 非目标（v0）

不做 OCI registry 或远程安装、不依赖 MCP/Wassette、不做授权 UI，默认不给文件/网络/环境访问。先用 JSON 字符串，WIT 绑定靠后。Scoot 自己掌握发现、策略映射与审计身份 —— 为日后采用 Component Model/WIT 留出空间，而不把它变成审查的前置条件。
