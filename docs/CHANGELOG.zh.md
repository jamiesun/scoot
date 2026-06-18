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

[未发布]: https://github.com/jamiesun/scoot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jamiesun/scoot/compare/v0.0.2...v0.1.0
