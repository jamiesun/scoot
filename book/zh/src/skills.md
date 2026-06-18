# 技能

**技能（skill）**是一个本地目录，装着特定任务的指令，扩展代理「会做什么」 —— 但**不**引入任何特权执行通道。规范参考（front matter 字段、打包、校验规则）见 [`docs/SKILLS.md`](https://github.com/jamiesun/scoot/blob/main/docs/SKILLS.md)；本页是实操概览。

## 技能长什么样

```text
my-skill/
  SKILL.md          # required: front matter + instructions
  scripts/          # optional helper scripts
  references/       # optional reference material
```

只有 `SKILL.md` 是必需的。`scripts/` 与 `references/` 可选，且*被使用*时和其它动作一样照常经过工具策略门。

`SKILL.md` 以 YAML 风格的 front matter 开头：

```yaml
---
name: metadata
description: Demonstrates review metadata for a local Scoot skill.
capabilities: [instructions, references]
allowed_tools: [file_read, grep, glob]
scope: workflow
---

# Instructions

...the full operating instructions the model loads on demand...
```

- **`name`**（必填）：ASCII 字母、数字、`.`、`_`、`-`，至多 64 字节。
- **`description`**（必填）：发现阶段使用的简短、非空摘要。
- **`capabilities` / `allowed_tools` / `scope`**（可选）：声明式的*审查*元数据。`allowed_tools` 是给审查者看的预期工具用途 —— 它**不**授予任何权限。

`scoot_version` / `requires_scoot` 等兼容性字段被刻意拒绝，直到 Scoot 定义版本门为止。

## 搜索路径

技能按**优先级顺序**发现（同名时靠前者胜）：

1. `<cwd>/.agents/skills` —— 项目本地，随仓库携带。
2. `~/.agents/skills` —— 跨 agent 的用户级技能，仅在 `[skills] include_agents_skills = true` 时加载。
3. `~/.scoot/skills` —— Scoot 自有的用户级目录。
4. 配置 `[skills]` 中的任意 `extra_paths`。

`scoot skills` 会打印解析后的路径和所有已发现技能。额外位置通过 [`[skills]`](configuration.md) 配置。

## 渐进式披露

为保持上下文精简，发现阶段只注入每个技能的 `name` + `description`，**绝不**预载 `SKILL.md` 正文。当某技能相关时，模型用原生 **`skill` 动作**按需加载：

```json
{ "name": "my-skill" }                                  // reads SKILL.md
{ "name": "my-skill", "path": "references/guide.md" }   // reads another file
```

## 读取是原生的；执行受策略门

这是核心安全属性：

- **读取技能是免费的。** `skill` 动作是原生只读能力，**按设计绕过执行策略**，故技能即便在 `readonly`（此时禁 `bash`）下也能用。读取收口在技能自身目录内（拒绝绝对路径、`..`，以及解析后逃逸该目录的 symlink），未知技能名返回可纠错的观察，且每次读取都被审计。
- **对技能采取行动则受策略门。** 技能随后让模型去*做*的一切 —— 跑 `bash`、写文件、发网络请求、执行 `scripts/` —— 都和任意普通工具调用走**同一套**策略校验。技能不获任何特权。

策略门见[执行策略与安全](policy.md)，铁律见 [Agent 指南](agent.md)。

## 命令

```sh
scoot skills                          # list discovered skills + search paths
scoot skills check path/to/my-skill   # validate one skill (no scripts run)
scoot skills check                    # validate all configured search paths
scoot skills pack path/to/my-skill my-skill.scoot-skill.tar
```

`skills check` 只校验结构，不执行任何东西。`skills pack` 导出一个带 `.scoot-skill.json` 审查清单的 tar（元数据、文件条目、大小，以及一条策略说明：技能脚本不绕过策略门，而读取指令是一次原生的、受收口的读取）。

起步模板：[`docs/examples/skills/minimal`](https://github.com/jamiesun/scoot/blob/main/docs/examples/skills/minimal/SKILL.md) 与 [`docs/examples/skills/metadata`](https://github.com/jamiesun/scoot/blob/main/docs/examples/skills/metadata/SKILL.md)。
