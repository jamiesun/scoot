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

## 搜索路径

技能按以下位置发现，并按优先级排列（同名时先者胜）：

1. `<cwd>/.agents/skills` —— 项目本地，随仓库携带；
2. `~/.agents/skills` —— 跨 agent 的用户级技能（独立于 `SCOOT_HOME`）；
3. `~/.scoot/skills` —— Scoot 自有用户级技能目录；
4. config 中 `[skills]` 声明的 `extra_paths`。

`scoot skills` 会打印解析出的搜索路径和全部已发现技能。

## 激活

发现阶段只注入每个技能的 `name` + `description`（渐进式披露，保持上下文精简）。当某技能相关时，模型用原生 **`skill` 动作**读取它的 `SKILL.md`——`{"name":"<技能名>"}`（读技能目录内其它资源用 `{"name":"<技能名>","path":"references/x.md"}`）。

读取技能是 agent 的**原生只读能力**，**不**受执行策略约束：即便在 `readonly` 档（该档会禁用 `bash`）下也能正常激活。读取被收口在该技能自身目录内（拒绝绝对路径、`..` 逃逸，以及解析后落在技能目录之外的 symlink），并照常被审计为 tool call。

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

skill 元数据只是声明。`allowed_tools` 用于给审查者说明预期工具使用范围，不授予权限。

读取技能的指令与资源是原生只读能力，按设计绕过 policy gate（这样技能在 `readonly` 档下仍可用）。而技能随后让模型去**执行**的一切——`bash`、写文件、网络请求、运行 `scripts/`——仍经过与普通模型工具调用相同的全局 policy 检查。读取技能免门，执行技能受门。

### 这对 `readonly` 读取面意味着什么

`readonly` 通常通过 `policy.evaluateReadPath` 把读取收口在项目工作目录内（禁绝对路径、禁 `..`、禁常见敏感路径片段）。`skill` 动作是唯一的有意例外：因为它豁免于 policy，它可以读取**任意已注册技能目录下的文件**，这是在 `evaluateReadPath` 把关的项目内读取之外额外放开的一块。已注册的技能目录即上文的四个搜索根：

1. `<cwd>/.agents/skills`
2. `~/.agents/skills`
3. `~/.scoot/skills`
4. config 中 `[skills]` 声明的 `extra_paths`

通过 `skill` 动作的读取仍被收口在命中的那个技能自身目录内（拒绝绝对路径、`..`，以及解析后逃逸该目录的 symlink）。对无人值守 / `readonly` 运行的现实含义：**只安装你信任的技能。** 被污染或恶意的技能包即便在 `readonly` 下也能把它自身目录的内容暴露给模型——这是读取边界的既定组成部分，而非绕过，因此不要把 `readonly` 当成对抗不可信技能的沙箱。
