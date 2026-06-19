# 更新日志

本文件记录项目的所有重要变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
并遵循[语义化版本](https://semver.org/lang/zh-CN/spec/v2.0.0.html)。

版本号的唯一事实源是
[`build.zig.zon`](../build.zig.zon)；发布流程会把某个 tag 对应的小节转换为
GitHub release 的发布说明（参见
[`.github/workflows/release.yml`](../.github/workflows/release.yml)）。请在文件顶部保留
`Unreleased` 小节，发布时将其内容移动到新的 `## [X.Y.Z]` 标题下。

English version: [CHANGELOG.md](../CHANGELOG.md)。

## [未发布]

### 新增

- Release workflow 现在会为每个支持目标发布带 `-small` 后缀的
  `ReleaseSmall` 产物。
- 安装脚本支持 `SCOOT_INSTALL_FLAVOR=small`，可选择 small release 产物，
  而不是默认的 `ReleaseSafe` 产物。

## [0.2.0] - 2026-06-19

### 新增

- `SCOOT_*` 环境变量覆盖，用于零配置与 CI 运行（#67）
- `file_read` 支持 offset/limit 行窗口读取（#78）
- 到达上下文预算时压缩历史，而不是直接中止运行（#81）
- grep 支持匹配点前后的可选上下文行（#82）
- 面向稳定模型 prompt 的配置化 prompt-cache breakpoint（#84）
- 零依赖 `outline` 动作，用低 token 成本查看文件骨架（#85）
- POSIX release 安装脚本，可下载、校验并安装匹配当前主机的二进制（#90）
- CLI/REPL 运行结束后在 stderr 输出紧凑运行摘要，包含事件数、工具调用、策略拒绝、后端状态与 transcript 路径（#59）
- `schedule.jobs` 支持分钟级 5 字段 UTC cron 调度（#65）

### 变更

- `~/.agents/skills` 发现改为显式 opt-in，项目本地与 Scoot 本地 skills 仍默认启用（#87）
- 同一次运行中的重复只读观察会被去重（#83）
- Agent 观察结果会做 token 优化，包括去除 ANSI、head/tail 窗口与 token 上限（#80）
- 每轮 thought 不再持久化到运行历史（#79）
- 运行目录与 JSONL 审计/会话文件改为属主可读写，并对 JSONL 文件做有界 `.1` 轮转（#60、#61）
- GitHub workflow 改用 Node 24 兼容 actions，并用 shell 安装 Zig，避免 Node 20 action 告警（#63）
- `build_options` 同时导入可执行文件 root module 与库模块（#64）
- `parseStep` 现在容忍兼容后端用 Markdown 代码块包裹步骤 JSON、或一次连续输出多个 JSON 对象，只执行第一个步骤，保持单步 ReACT 语义

### 修复

- 语言切换入口移入 mdBook 导航图标区域（#86）
- 非法的枚举型 `SCOOT_*` 覆盖现在会告警并保留原值，不再静默改变 policy/mode/level（#68）
- `confine_writes` 现在会拒绝最终写入文件名本身为预置 symlink 的逃逸路径（#69）

### 文档

- 新增维护型 changelog，并让 release notes 从 changelog 派生（#66）
- 改进 README 与用户指南结构，包括安装器文档、设计理念、最佳实践案例和 daemon/运行模式说明（#90）
- 增加 Scoot logo、favicon 资产，以及带动效的文档站点入口页标识（#91）
- 将 logo 合入 README/mdBook 信息图，并移除重复的独立 logo 块（#92）

## [0.1.0] - 2026-06-18

自 `v0.0.2`（仅包含发布工作流的基础设施）以来的首个功能版本。

### 新增

- 交互式 REPL 中的 CLI 跟踪输出与 `--trace`（#7、#48）
- 实时的「thinking」/「running」跟踪标记，让 `--trace` 不再像卡住（#56）
- `doctor` 与策略 `check` 命令（#10）
- `scoot` home 覆盖标志（#11）
- 技能校验、技能包导出与技能审查元数据（#15、#17、#21）
- 原生技能读取及扩展的技能搜索路径（#35）
- 有界并行读取工具（#16）
- wasm 工具包边界（#20）
- 守护进程生命周期命令（#33）

### 修复

- 只读策略默认加固与受限读取路径（#13、#14）
- 重试瞬时的 eval 后端失败（#18）
- 解决所有开放问题 #22–#54（#34、#49、#55）
- 版本号现从 `build.zig.zon` 派生而非硬编码；发布构建嵌入 tag（#57）

### 文档

- 完善首页/许可证元数据、信息图与双语用户指南（#6、#19、#36）

[未发布]: https://github.com/jamiesun/scoot/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/jamiesun/scoot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jamiesun/scoot/compare/v0.0.2...v0.1.0
