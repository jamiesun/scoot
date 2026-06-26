# Wasm 工具包

状态：目前只定义边界并做静态校验。Scoot 还不会执行 Wasm 工具。

Scoot 的 Wasm 工具包格式刻意比 Wassette 或 MCP 更小。目标是在引入运行时之前，先给第三方工具建立一个本地、可审查的边界。

## 包结构

```text
tool/
  component.wasm
  manifest.toml
  policy.toml
  schema/
    input.json
    output.json
```

校验工具包：

```sh
scoot wasm-tools check path/to/tool
```

这个检查是只读的。它会解析元数据和 schema、检查引用文件、拒绝不安全路径，并校验
`component.wasm` 的字节码结构（magic、version、section、LEB128 长度与基础索引/数量一致性）；
不会执行 Wasm。

## Manifest

`manifest.toml` 声明工具身份、入口、schema 和请求能力：

```toml
name = "calculator"
description = "Evaluate simple math expressions"
entry = "call"
component = "component.wasm"
input_schema = "schema/input.json"
output_schema = "schema/output.json"
capabilities = ["compute"]
```

规则：

- `name` 使用与 skill 相同的标识符规则：ASCII 字母、数字、`.`、`_`、`-`，最长 64 字节。
- `description` 不能为空。
- `entry` 必须是非空 ASCII 标识符。
- `component`、`input_schema`、`output_schema` 必须是安全相对路径。绝对路径、`..`、隐藏路径段、盘符前缀和空路径段都会被拒绝。
- `component` 必须以 `.wasm` 结尾。

## Policy

`policy.toml` 声明包所有者实际授予的能力：

```toml
capabilities = ["compute"]
```

policy 能力必须是 manifest 能力的子集，避免工具包静默获得自己没有声明过的权限。

支持的能力名：

- `compute`：纯计算，不允许文件、网络或环境变量访问。
- `read`：本地读权限；未来运行时支持后仍要经过 Scoot policy gate。
- `write`：本地写权限；未来运行时支持后仍要经过 Scoot policy gate。
- `net_read`：外向只读网络访问。
- `net_write`：外向写类网络访问。

第一阶段纯工具应主要使用 `compute`。因为执行能力尚未实现，当前任何 capability 都不会授予运行时权限。

## Schemas

`schema/input.json` 和 `schema/output.json` 是工具输入与输出的 JSON Schema。当前校验器只检查两个文件存在且是合法 JSON；后续运行时 schema 校验会基于同一组文件继续扩展。

未来模型调用形态：

```json
{
  "action": "wasm_tool",
  "action_input": "{\"tool\":\"calculator\",\"input\":{\"expr\":\"1+2\"}}"
}
```

## v0 非目标

- 不做 OCI registry 或远程包安装流程，
- 不依赖 MCP，
- 不依赖 Wassette 运行时，
- 不做权限授予 UI，
- 默认不给文件、网络或环境变量访问，
- 先使用 JSON 字符串，暂不要求 WIT 绑定，
- discovery、policy 映射和审计身份由 Scoot 自己掌控。

这个边界保留了未来采用 Component Model/WIT 的空间，但不会把运行时选型变成审查工具包的前置条件。
