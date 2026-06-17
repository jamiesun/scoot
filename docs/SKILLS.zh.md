# Skills

Scoot skill 是本地目录，用来添加特定任务的操作指令，但不会新增特权执行通道。

## 目录结构

```text
my-skill/
  SKILL.md
  scripts/
  references/
```

只有 `SKILL.md` 是必需的。`scripts/` 和 `references/` 是可选目录；使用时仍然必须经过正常工具 policy gate。

## Front Matter

`SKILL.md` 以 YAML 风格 front matter 开头：

```yaml
---
name: metadata
description: Demonstrates review metadata for a local Scoot skill.
capabilities: [instructions, references]
allowed_tools: [file_read, grep, glob]
scope: workflow
---
```

必需字段：

- `name`：ASCII 字母、数字、`.`、`_`、`-`，最长 64 字节。
- `description`：非空短描述，用于 skill 发现。

可选审查元数据：

- `capabilities`：内联列表，可使用 `instructions`、`scripts`、`references`。
- `allowed_tools`：预期使用的内建工具动作列表，可使用 `bash`、`file_read`、`file_write`、`file_edit`、`grep`、`glob`、`http_request`、`parallel`。
- `scope`：`general`、`project`、`repository`、`domain`、`workflow` 之一。

`scoot_version`、`compatibility`、`requires_scoot` 等兼容性字段会被明确拒绝，直到 Scoot 定义版本门槛。

## 命令

校验单个 skill：

```sh
scoot skills check path/to/my-skill
```

校验已配置的 skill 搜索路径：

```sh
scoot skills check
```

打包 skill 以便审查：

```sh
scoot skills pack path/to/my-skill my-skill.scoot-skill.tar
```

包内会包含 `.scoot-skill.json` manifest，记录元数据、文件列表、大小信息，以及“skill 指令和脚本不会绕过 Scoot policy gate”的说明。

## Policy 边界

skill 元数据只是声明。`allowed_tools` 用于给审查者说明预期工具使用范围，不授予权限。运行时执行仍然经过与普通模型工具调用相同的全局 policy 检查。
