# Wasm 工具包

状态：核心仍只定义边界并做静态校验；独立的 `scoot-wasm` host 现已能执行整数 Wasm 函数（W1），能在最小 WASI preview1 子集上运行 `wasm32-wasi` 命令模块（W2），并会在执行前对当前 host 子集做静态类型验证（W3）。核心 `scoot` 二进制依旧从不加载或执行 Wasm。

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

## 独立 host（`scoot-wasm`）

执行能力放在单独的二进制里，仅在 `-Dwasm-host=true` 时构建，从而让零依赖核心永不内嵌运行时：

```sh
zig build -Dwasm-host=true
scoot-wasm check path/to/module.wasm         # 字节码结构校验（W0）
scoot-wasm run path/to/module.wasm add 2 40  # 执行导出函数（W1）
scoot-wasm wasi path/to/module.wasm [参数..] # 运行 wasm32-wasi 命令模块（W2）
```

`scoot-wasm run <module.wasm> <export> [整数参数...]` 用 W1 栈机调用导出函数，
打印整数返回值，出错时打印结构化的 `TRAP ...` 行。参数按整数解析并强制转换为函数
声明的参数类型。

W1 引擎是一个零依赖的纯 Zig 解释器，覆盖：结构化控制流（`block`/`loop`/`if`/`else`/
`br`/`br_if`/`br_table`/`return`/`call`/`call_indirect`）、i32/i64 算术、比较、
位/移位/循环移位运算与 `wrap`/`extend` 转换、带边界检查的 64 KiB 页线性内存
（`load`/`store` 及 8/16/32 位变体、`memory.size`/`memory.grow`、
`memory.copy`/`memory.fill`）、全局变量、funcref 表，以及 active data/element 段。
任何故障都返回结构化 trap 而非崩溃（unreachable、除零、整数溢出、内存/表越界、
未定义元素、间接调用类型不匹配），并由 fuel、调用深度、操作数栈与内存页上限兜底。

在 `run` 或 `wasi` 执行模块前，W3 验证会检查当前支持的函数体子集：operand/control
stack 形状、block/loop/if 签名、分支 label 的 arity/type、直接与间接调用签名、
local/global 访问、memory/table 是否存在，以及不可变 global 写入。类型/索引错误会在模块
加载阶段失败，而不是进入解释器后才暴露。

### WASI 命令模块（`scoot-wasm wasi`，W2）

`scoot-wasm wasi <module.wasm> [参数...]` 运行一个 `wasm32-wasi` 命令模块：实例化模块，
执行 start section 与 `_start` 导出，把本进程的 stdin 作为 fd 0 读入，转发模块的
stdout/stderr，并以模块的 `proc_exit` 状态退出（`_start` 正常返回则退出码为 0）。这正是
外部压缩插件的子进程 host：核心通过 `scoot-wasm wasi <component>` 调用，并在 stdio 上走
JSON 进 / JSON 出的插件协议。

仅暴露一个刻意收窄的 WASI preview1 表面，使模块按构造无法获得环境权限：

- `args_sizes_get` / `args_get`、`environ_sizes_get` / `environ_get`
- `fd_read`（仅 fd 0）、`fd_write`（仅 fd 1/2）、`fd_close`、`fd_seek`
  （stdio 不可 seek → `ESPIPE`）、`fd_fdstat_get`（stdio 字符设备）
- `clock_time_get`（realtime/monotonic）、`random_get`（带种子、确定性）
- `proc_exit`

host 不暴露自身环境变量（environ 默认为空），也不实现任何文件 / 网络函数：其余 WASI
import 一旦被调用即 trap；越界的 guest 指针返回 `EFAULT` 而非破坏 host 内存；非法文件
描述符返回 `EBADF`。资源使用受与 `run` 相同的 fuel / 调用深度 / 内存页上限约束，核心还会
为该子进程套一层硬性墙钟超时。

仓库内置了可运行的压缩插件包和一个可复制模板：

```sh
zig build wasm-compressor-example wasm-plugin-template wasm-redactor-compressor
./zig-out/bin/scoot wasm-tools check examples/wasm-compressor
./zig-out/bin/scoot wasm-tools check examples/wasm-plugin-template
./zig-out/bin/scoot wasm-tools check examples/wasm-redactor-compressor
printf '%s\n' '{"version":1,"kind":"compressor","keep_recent":2,"elided_count":3,"elided_bytes":1200,"messages":[]}' \
  | ./zig-out/bin/scoot-wasm wasi examples/wasm-compressor/component.wasm
./zig-out/bin/scoot-wasm wasi examples/wasm-redactor-compressor/component.wasm \
  < examples/wasm-redactor-compressor/fixtures/request.json
```

新增插件时优先从 `examples/wasm-plugin-template` 复制。`examples/wasm-redactor-compressor`
是第二个确定性示例：它扫描被省略消息里的类密钥提示，但不会把消息内容写回输出。
`scripts/check-wasm-examples.sh` 会构建 host 和全部示例 component，校验包边界，并运行
template / redactor smoke checks。

尚未实现（后续阶段）：超出当前 host 子集的完整 spec 一致验证、浮点一致性，以及更大的
WASI 表面（文件、套接字、realtime/monotonic 之外的时钟）。

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

第一阶段纯工具应主要使用 `compute`。package capability 仍只是准入元数据：独立 host
当前只暴露 stdio/args/environ/clock/random/proc-exit，不会把 `read`、`write`、
`net_read` 或 `net_write` 映射成文件、环境变量或网络权限。

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
