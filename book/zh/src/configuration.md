# 配置

Scoot 从运行目录加载配置：

1. `config.toml`
2. `config.json`
3. 内置默认值

推荐从这里开始：

- [`config.example.toml`](../../../config.example.toml)

## 主要配置节

- `[backend]`：OpenAI 兼容端点、模型、API key 来源、CA bundle、额外请求字段。
- `[agent]`：回合上限和默认模式。
- `[tools]`：超时和执行策略。
- `[skills]`：skill 发现。
- `[audit]`：审计日志行为。
- `[schedule]`：调度任务。

## 策略模式

- `guarded`：交互式绊线模式。
- `readonly`：fail-closed 只读模式。
- `unrestricted`：不设策略限制，但仍审计。

调度任务会把 `guarded` 矫正为 `readonly`。

## 密钥

不要把明文 API key 放进配置。使用：

1. 环境变量，
2. 私有 token 文件，
3. 凭证命令。

