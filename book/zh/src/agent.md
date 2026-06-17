# Agent 指南

权威英文 Agent 指南：

- [`AGENT.md`](../../../AGENT.md)

权威中文 Agent 指南：

- [`docs/AGENT.zh.md`](../../../docs/AGENT.zh.md)

## 关键规则

- 扩展能力前先读路线图。
- 代码改动保持外科手术式。
- 修改 Zig 后运行 `zig build` 与 `zig build test`。
- 所有项目文档保持中英双语同步。
- 不执行未经校验的模型输出。
- skill 的**执行**不得绕过工具沙盒（读取技能指令是原生只读能力，刻意不受策略门控制）。
- 不把密钥写进配置、日志或审计输出。

