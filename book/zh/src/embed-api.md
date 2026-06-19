# 嵌入 API

Scoot 可以作为 Zig 包被其他可执行文件嵌入，但公共包根刻意只是一个
**生命周期门面**，不是一组内部类型工具箱。

公共 API 只有：

```zig
pub const version: []const u8;
pub const Runtime = opaque {};
pub const Options = struct { ... };
pub fn start(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Runtime;
pub fn run(rt: *Runtime, goal: []const u8) ![]const u8;
pub fn stop(rt: *Runtime) void;
```

`Runtime` 是不透明句柄。嵌入者拿不到 `Agent`、`Session`、`Config`、
`policy`、`llm.Client`、`tools` 或 `Compressor`。这些都留在内部，这样
Scoot 才能自由演进引擎、配置 schema、压缩、工具、MCP/Wasm 集成和 daemon 内部实现，
而不破坏下游代码。

## Options

`Options` 接收的是配置**来源**，不是结构化配置：

| 字段 | 含义 |
| --- | --- |
| `env` | 必填环境变量 map，用于 `HOME`/`SCOOT_HOME`、`SCOOT_*` 覆盖和 API token 环境变量查找。 |
| `scoot_home` | 可选运行目录覆盖，语义类似 CLI 的 `--scoot-home`。 |
| `config_file` | 可选显式配置文件。`.toml` 按 TOML 解析，其它扩展按 JSON 解析。 |

所有具体配置 struct 都保持内部。要改变模型、策略、压缩器、skills 或工具行为，
使用与 CLI 相同的配置文件和环境变量。

## 最小示例

见 [`examples/embed/minimal.zig`](https://github.com/jamiesun/scoot/blob/main/examples/embed/minimal.zig)。
该示例会随 `zig build test` 编译，因此公共 API 漂移会被测试捕获。

```zig
const scoot = @import("scoot");

const rt = try scoot.start(arena, init.io, .{
    .env = init.environ_map,
});
defer scoot.stop(rt);

const reply = try scoot.run(rt, "Return a short greeting.");
```

返回的 reply 由 runtime 持有，在 `stop` 前有效。

## 稳定边界

稳定：

- `version`
- `Options`
- 不透明 `Runtime`
- `start`
- `run`
- `stop`

不稳定：

- `Agent`、`Session`、`Config`、`policy`、`llm.Client`、`tools`、
  `Compressor` 和其它所有内部模块；
- `src/` 下的包内名字；
- build 生成的内部内容；
- 所有隐藏 runtime 状态的精确布局。

仓库为包根加了白名单测试。意外把 `tools`、`regex` 这类内部命名空间导出时，
`zig build test` 会失败。

## Zig 兼容性

Scoot 的公共 API 是 Zig 源码级 API，不是 ABI。Zig 仍未到 1.0，因此 Scoot 的
semver 承诺默认要求使用本仓库支持的 Zig 版本。嵌入 Scoot 时，请锁定与 Scoot
CI/release workflow 相同的 Zig toolchain。

