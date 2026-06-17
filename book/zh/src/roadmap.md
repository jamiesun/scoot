# 路线图

权威英文路线图：

- [`docs/ROADMAP.md`](https://github.com/jamiesun/scoot/blob/main/docs/ROADMAP.md)

权威中文路线图：

- [`docs/ROADMAP.zh.md`](https://github.com/jamiesun/scoot/blob/main/docs/ROADMAP.zh.md)

## 简版

Scoot 应该保持小型、可审计、本地优先的自动化核心：

- 轻量单体二进制，
- CLI 与配置文件交互，
- 只对接 OpenAI 兼容后端，
- 本地状态与审计日志，
- 执行前防御性校验，
- 不做 GUI，
- 不做云同步，
- 不泄露密钥，
- skill 不越权。

近期最值得补的是错误诊断、每次运行摘要、目录权限硬化、日志生命周期，以及后续的 plan 模式。

