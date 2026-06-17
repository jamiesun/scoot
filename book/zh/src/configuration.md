# 配置

Scoot 从运行目录加载配置：

1. `config.toml`
2. `config.json`
3. 内置默认值

推荐从这里开始：

- [`config.example.toml`](../../../config.example.toml)

## 主要配置节

- `[backend]`：OpenAI 兼容端点、模型、API key 来源、CA bundle、额外请求字段。
- `[agent]`：回合上限、默认模式与上下文预算（`context_budget_bytes`，0 = 关闭）。
- `[tools]`：超时、执行策略，以及 guarded 模式下的 opt-in 加固（`confine_writes`、`block_internal_http`）。
- `[skills]`：skill 发现。
- `[audit]`：审计日志行为。
- `[schedule]`：调度任务。

## 策略模式

- `guarded`：交互式绊线模式。
- `readonly`：fail-closed 只读模式。
- `unrestricted`：不设策略限制，但仍审计。

调度任务会把 `guarded` 矫正为 `readonly`。

## Guarded 模式加固（opt-in）

两项均默认 `false`，且仅在 `guarded` 模式生效（`readonly` 已 fail-closed 拒写、拒网）：

- `confine_writes`：把 `file_write` / `file_edit` 收口到项目根内，拒绝绝对路径、`..` 逃逸以及 `~` / `$VAR` 展开。
- `block_internal_http`：拒绝 `http_request` 访问环回 / 内网 / 链路本地 / 云元数据地址（SSRF 防护）。

`block_internal_http` 是基于字面量 IP 段与已知内部主机名的启发式，**不解析 DNS**，因此 DNS rebinding 仍可绕过。要真正隔离请用 `readonly` 或网络沙箱。

## 密钥

不要把明文 API key 放进配置。使用：

1. 环境变量，
2. 私有 token 文件，
3. 凭证命令。

