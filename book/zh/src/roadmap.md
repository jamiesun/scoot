# 路线图

权威英文路线图：

- [`docs/ROADMAP.md`](https://github.com/jamiesun/scoot/blob/main/docs/ROADMAP.md)

权威中文路线图：

- [`docs/ROADMAP.zh.md`](https://github.com/jamiesun/scoot/blob/main/docs/ROADMAP.zh.md)

## 简版

Scoot 应该保持小型、可审计、本地优先的自动化核心：

- 轻量单体二进制，
- CLI、REPL、daemon 与本地 stdio `serve` 交互，
- 只对接 OpenAI 兼容 Responses API 后端，
- 本地状态与审计日志，
- 执行前防御性校验，
- 不做 GUI 或 Web UI，
- 不做云同步，
- 不泄露密钥，
- skill 不越权，
- MCP / Wasm / 其他扩展缝必须配置门控、硬超时、可审计，
- 无人值守 `unrestricted` 执行是高风险操作者例外，不是默认工作流，
- 公开包根保持窄口径稳定 embedding API。

近期最值得做的是扩展边界审计、可行动诊断、文档同步、运行时治理；之后再推进 plan 模式。
