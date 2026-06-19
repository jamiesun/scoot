//! 运行时配置：默认从 ~/.scoot/config.json 加载，缺省即用内置默认值。
//! 状态严格本地化；密钥默认不内联，见 secret.zig。
const std = @import("std");
const Environ = std.process.Environ;
const paths = @import("paths.zig");
const secret = @import("secret.zig");
const schedule = @import("schedule.zig");
const policy = @import("policy.zig");
const tomlmod = @import("toml.zig");

/// LLM 后端配置。仅 OpenAI 兼容协议（见 ROADMAP 非目标）。
pub const Backend = struct {
    base_url: []const u8 = "http://127.0.0.1:11434/v1",
    model: []const u8 = "qwen2.5",
    /// 读取 token 的环境变量名（默认来源）。此处不存放明文。
    api_key_env: []const u8 = "OPENAI_API_KEY",
    /// token 文件路径；null 表示用 ~/.scoot/token。
    api_key_file: ?[]const u8 = null,
    /// 凭证命令（如 `pass show openai`）；null 表示不用。
    api_key_cmd: ?[]const u8 = null,
    /// 自定义 CA bundle（PEM）绝对路径；null 表示用系统根证书自动扫描。
    /// 裁剪 / 嵌入式 Linux 上系统证书常缺失，可在此指定随固件部署的 CA。
    ca_file: ?[]const u8 = null,
    /// 动态扩展请求体参数（透传）：原样合并进 chat/completions 顶层 JSON。
    /// 用于后端特有 / 新增字段，无需为每个参数加 Zig 字段——
    /// 如 Azure 的 `service_tier`、推理模型的 `reasoning_effort`、`top_p` 等。
    /// 仅接受 JSON 对象；非对象一律忽略（防弹）。**明文密钥严禁放此处**（见铁律 #7）。
    extra_body: ?std.json.Value = null,
    /// prompt 缓存提示模式（issue #72）：`off`（默认）/ `anthropic`。
    /// `off`：请求体不带任何缓存标记，逐字节同旧行为——OpenAI / vLLM / SGLang 等自动缓存
    /// 稳定前缀的后端无需也不应收到额外字段。`anthropic`：给稳定指令前缀（开头 system 段）
    /// 打 Anthropic 风格 `cache_control` 断点，使固定前缀按缓存价计费。仅在 Anthropic 兼容
    /// 网关上开启；未知值回落 off。见 llm.PromptCache。
    prompt_cache: []const u8 = "off",
};

/// 认知引擎配置。
pub const Agent = struct {
    max_turns: u32 = 32,
    /// 默认认知模式：goal / plan。
    default_mode: []const u8 = "goal",
    /// 上下文压缩策略：drop（旧的有损计数标记，默认）/ extractive（确定式抽取纪要）。
    compactor: []const u8 = "drop",
    /// 上下文预算（字节）：跨回合累计的提示历史超过此值时，先压缩历史（保留 system +
    /// 原始任务 + 最近若干回合，更早的工具原文替换为摘要标记，见 compressor.drop /
    /// issue #71）让 run 继续推进；仅当压缩后仍超限才在下次后端调用前 fail-fast（issue #28）。
    /// 0 = 关闭（仅受 max_turns 约束，保持默认行为）。字节是 token 体量的粗略代理，
    /// 取经验保守值（≈ 上下文上限 token × 每 token 字节数，再留余量）。
    context_budget_bytes: usize = 0,
};

/// 工具沙盒配置。
pub const Tools = struct {
    /// 工具调用硬超时（毫秒）。
    timeout_ms: u64 = 30_000,
    /// 执行护栏模式：guarded（拦截灾难性命令，默认）/ readonly（只读白名单，
    /// fail-closed）/ unrestricted（不设限）。见 policy.zig。无人值守场景应选 readonly。
    policy: []const u8 = "guarded",
    /// opt-in 加固（默认关闭，仅 guarded 生效）：把 file_write/file_edit 收口到项目根内，
    /// 拒绝绝对路径 / `..` 逃逸 / shell 展开（issue #32）。readonly 已 fail-closed 拒写。
    confine_writes: bool = false,
    /// 默认开启（仅 guarded 生效）：拒绝 http_request 访问环回 / 内网 / 链路本地 / 云元数据
    /// 地址，收窄 SSRF / 外带面（issue #32 / #50）。合法 agent HTTP 几乎不触达这些地址，
    /// 摩擦低、收益高，故默认 true；如确需访问内网可显式置 false。readonly 已默认拒网。
    block_internal_http: bool = true,
};

/// Skill 机制配置。
pub const Skills = struct {
    enabled: bool = true,
    /// 是否加载跨 agent 的用户级目录 ~/.agents/skills。默认关闭，避免全局技能污染当前 agent。
    include_agents_skills: bool = false,
    /// 额外 skill 搜索路径（默认已含 ~/.scoot/skills）。
    extra_paths: []const []const u8 = &.{},
};

/// 审计日志配置。
pub const Audit = struct {
    /// 日志级别：debug / info / warn / error。
    level: []const u8 = "info",
    /// 是否把审计日志写入 ~/.scoot/logs。
    to_file: bool = true,
};

/// 单个调度任务的可配置镜像。trigger 用三个互斥的可选字段表达（JSON 友好），
/// 恰好设置其一才合法（见 `Schedule.toJobs` 校验）。
pub const JobConfig = struct {
    id: []const u8,
    goal: []const u8 = "",
    /// 固定间隔（秒）。
    every_sec: ?u64 = null,
    /// 固定时间点（Unix 秒）。
    at_unix: ?i64 = null,
    /// Cron 表达式（暂不支持）。
    cron: ?[]const u8 = null,
    /// 执行策略档：readonly（默认，无人值守安全档）/ unrestricted（自担风险，仍审计）。
    /// guarded 在执行时会被矫正为 readonly（见 schedule.Job.effectiveMode）。
    mode: []const u8 = "readonly",

    /// 把互斥的可选触发字段收口为 schedule.Trigger；**恰好设置其一**才合法，否则 null。
    pub fn trigger(jc: JobConfig) ?schedule.Trigger {
        var n: usize = 0;
        var t: schedule.Trigger = undefined;
        if (jc.every_sec) |s| {
            n += 1;
            t = .{ .every_sec = s };
        }
        if (jc.at_unix) |a| {
            n += 1;
            t = .{ .at_unix = a };
        }
        if (jc.cron) |c| {
            if (!schedule.cronValid(c)) return null;
            n += 1;
            t = .{ .cron = c };
        }
        return if (n == 1) t else null;
    }

    /// 转为可调度的 schedule.Job；触发器非法（缺失/多重）则 null，调用方据此跳过并告警。
    /// mode 经 policy.Mode.fromString 解析（未知值回落 guarded，再被 effectiveMode 矫正为 readonly）。
    pub fn toJob(jc: JobConfig) ?schedule.Job {
        const trig = jc.trigger() orelse return null;
        return .{
            .id = jc.id,
            .trigger = trig,
            .goal = jc.goal,
            .mode = policy.Mode.fromString(jc.mode),
        };
    }
};

/// 调度配置（北极星方向三）。默认关闭：自主无人值守执行必须显式开启。
pub const Schedule = struct {
    enabled: bool = false,
    /// 守护循环轮询间隔（毫秒）。
    poll_ms: u64 = 1000,
    jobs: []const JobConfig = &.{},
};

/// config.json 的可序列化镜像：仅含可落盘的配置节，不含运行目录。
/// 每节都带默认值，缺省的节/字段自动回落默认，从而实现按节合并。
const FileConfig = struct {
    backend: Backend = .{},
    agent: Agent = .{},
    tools: Tools = .{},
    skills: Skills = .{},
    audit: Audit = .{},
    schedule: Schedule = .{},
};

/// 配置文件大小上限：1 MiB（config.json 实际仅几 KiB，留足冗余）。
const config_read_limit: std.Io.Limit = .limited(1 << 20);

/// 配置加载诊断：把不可读的解析错误与「被静默丢弃的拼写键」上报给上层（CLI），
/// 供其向用户给出可定位信息 / 告警（issue #45、#46）。失败时也会在返回错误前填好。
pub const LoadReport = struct {
    /// TOML 解析失败位置（仅 TOML 路径且 InvalidToml 时填充）。
    toml_diag: ?tomlmod.Diagnostic = null,
    /// 未识别的配置键（点分路径）：因 ignore_unknown_fields 被静默丢弃并回落默认，收集以告警。
    unknown_keys: []const []const u8 = &.{},
    /// SCOOT_* 环境变量覆盖中因类型非法被忽略的项（含变量名与原因），供上层告警。
    env_warnings: []const []const u8 = &.{},
};

/// 收集解析后的配置树里未被 FileConfig 模式识别的键（点分路径）。
/// 拼写错误的键（如 `[tools] polcy`）会被 std.json 的 ignore_unknown_fields 静默丢弃并
/// 回落默认值——对安全相关键（policy / api_key_env 等）这是「悄悄变得更不安全」，故收集以告警（issue #45）。
fn collectUnknownKeys(arena: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (value == .object) try checkObjectKeys(FileConfig, arena, value.object, "", &list);
    return list.items;
}

fn checkObjectKeys(
    comptime T: type,
    arena: std.mem.Allocator,
    obj: std.json.ObjectMap,
    prefix: []const u8,
    list: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const fields = @typeInfo(T).@"struct".fields;
    var it = obj.iterator();
    keyloop: while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        inline for (fields) |f| {
            if (std.mem.eql(u8, f.name, key)) {
                try checkFieldKeys(f.type, arena, entry.value_ptr.*, try joinKey(arena, prefix, key), list);
                continue :keyloop;
            }
        }
        try list.append(arena, try joinKey(arena, prefix, key));
    }
}

fn checkFieldKeys(
    comptime FT: type,
    arena: std.mem.Allocator,
    value: std.json.Value,
    path: []const u8,
    list: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    const T = switch (@typeInfo(FT)) {
        .optional => |o| o.child,
        else => FT,
    };
    if (T == std.json.Value) return; // 自由形态字段（如 extra_body）：不深入校验
    switch (@typeInfo(T)) {
        .@"struct" => if (value == .object) try checkObjectKeys(T, arena, value.object, path, list),
        .pointer => |ptr| {
            const child_is_struct = switch (@typeInfo(ptr.child)) {
                .@"struct" => true,
                else => false,
            };
            if (ptr.size == .slice and child_is_struct and value == .array) {
                for (value.array.items) |item| try checkFieldKeys(ptr.child, arena, item, path, list);
            }
        },
        else => {},
    }
}

fn joinKey(arena: std.mem.Allocator, prefix: []const u8, key: []const u8) std.mem.Allocator.Error![]const u8 {
    if (prefix.len == 0) return arena.dupe(u8, key);
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, key });
}

/// 读取 env 变量值；空串视作未设置（避免把空值覆盖成空字符串）。
fn envVal(env: *const Environ.Map, name: []const u8) ?[]const u8 {
    const v = env.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// 宽松布尔解析：true/false（大小写不敏感）或 1/0。
fn parseEnvBool(s: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0")) return false;
    return null;
}

fn warnEnv(
    warnings: *std.ArrayList([]const u8),
    arena: std.mem.Allocator,
    name: []const u8,
    reason: []const u8,
) std.mem.Allocator.Error!void {
    try warnings.append(arena, try std.fmt.allocPrint(arena, "{s}：{s}", .{ name, reason }));
}

fn overrideEnvBool(
    env: *const Environ.Map,
    name: []const u8,
    out: *bool,
    warnings: *std.ArrayList([]const u8),
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const v = envVal(env, name) orelse return;
    if (parseEnvBool(v)) |b| out.* = b else try warnEnv(warnings, arena, name, "需为 true/false（或 1/0），已忽略");
}

fn overrideEnvInt(
    comptime T: type,
    env: *const Environ.Map,
    name: []const u8,
    out: *T,
    warnings: *std.ArrayList([]const u8),
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const v = envVal(env, name) orelse return;
    out.* = std.fmt.parseInt(T, v, 10) catch {
        try warnEnv(warnings, arena, name, "需为非负整数，已忽略");
        return;
    };
}

fn oneOf(s: []const u8, allowed: []const []const u8) bool {
    for (allowed) |item| {
        if (std.mem.eql(u8, s, item)) return true;
    }
    return false;
}

fn overrideEnvEnumString(
    env: *const Environ.Map,
    name: []const u8,
    out: *[]const u8,
    allowed: []const []const u8,
    warnings: *std.ArrayList([]const u8),
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const v = envVal(env, name) orelse return;
    if (oneOf(v, allowed)) {
        out.* = try arena.dupe(u8, v);
        return;
    }
    try warnEnv(warnings, arena, name, "不是支持的取值，已忽略");
}

/// 解析 config.json 文本为 FileConfig。
/// 空白内容回落默认；未知字段忽略（向后兼容）；畸形 JSON → error.InvalidConfig。
/// 字符串/数组分配在 arena 上，生命周期随 arena。
fn parseFileConfig(arena: std.mem.Allocator, bytes: []const u8, report: ?*LoadReport) !FileConfig {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return .{};
    const fc = std.json.parseFromSliceLeaky(FileConfig, arena, trimmed, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
    // 仅为诊断：再解析为 Value 收集未识别键（best-effort，失败则跳过，不影响主解析结果，issue #45）。
    if (report) |r| {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{})) |value| {
            r.unknown_keys = try collectUnknownKeys(arena, value);
        } else |_| {}
    }
    return fc;
}

/// 解析 config.toml 文本为 FileConfig。
/// 先用自研 TOML 子集解析器产出 std.json.Value 树，再交 std.json.parseFromValueLeaky
/// 复用与 JSON 完全相同的类型映射 / 默认值 / 按节合并 / extra_body 透传。
/// 空白内容回落默认；畸形 TOML / 字段类型不符 → error.InvalidConfig（坏配置可见）。
fn parseTomlConfig(arena: std.mem.Allocator, bytes: []const u8, report: ?*LoadReport) !FileConfig {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return .{};
    var diag: tomlmod.Diagnostic = undefined;
    const value = tomlmod.parseDiag(arena, bytes, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidToml => {
            if (report) |r| r.toml_diag = diag; // 上报出错行列（issue #46）
            return error.InvalidConfig;
        },
    };
    if (report) |r| r.unknown_keys = try collectUnknownKeys(arena, value); // 上报拼写键（issue #45）
    return std.json.parseFromValueLeaky(FileConfig, arena, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
}

pub const Config = struct {
    backend: Backend = .{},
    agent: Agent = .{},
    tools: Tools = .{},
    skills: Skills = .{},
    audit: Audit = .{},
    schedule: Schedule = .{},
    /// 解析出的运行目录。
    dirs: paths.Paths,
    /// 实际加载的配置文件路径（config.toml 优先于 config.json）。
    /// 两者皆缺失时为推荐路径（config.toml）。仅用于 `scoot config` 展示。
    active_config_file: []const u8 = "",

    /// 从 ~/.scoot/ 加载配置：优先 config.toml，否则 config.json，皆缺失则用默认值。
    /// `io` 用于读取配置文件，`env` 用于解析运行目录。
    /// 文件缺失 → 静默回落默认；存在但畸形 → error.InvalidConfig（让坏配置可见）。
    pub fn load(arena: std.mem.Allocator, io: std.Io, env: *const Environ.Map) !Config {
        const dirs = try paths.Paths.resolve(arena, env);
        return loadFromDirs(arena, io, dirs, null);
    }

    /// 在运行目录已解析后加载配置。供 CLI 先解析目录、再针对配置文件单独报错。
    /// 加载优先级：config.toml（可读性更好）> config.json（向后兼容）。
    /// `report` 非空时回填解析诊断（出错行列）与未识别键，供上层定位/告警（issue #45、#46）。
    pub fn loadFromDirs(arena: std.mem.Allocator, io: std.Io, dirs: paths.Paths, report: ?*LoadReport) !Config {
        const cwd = std.Io.Dir.cwd();
        // ① 优先 TOML
        if (cwd.readFileAlloc(io, dirs.config_toml_file, arena, config_read_limit)) |bytes| {
            const fc = try parseTomlConfig(arena, bytes, report);
            return fromFile(fc, dirs, dirs.config_toml_file);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        // ② 回落 JSON
        if (cwd.readFileAlloc(io, dirs.config_file, arena, config_read_limit)) |bytes| {
            const fc = try parseFileConfig(arena, bytes, report);
            return fromFile(fc, dirs, dirs.config_file);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        // ③ 皆缺失：默认值；active 指向推荐的 TOML 路径
        return .{ .dirs = dirs, .active_config_file = dirs.config_toml_file };
    }

    fn fromFile(fc: FileConfig, dirs: paths.Paths, active: []const u8) Config {
        return .{
            .backend = fc.backend,
            .agent = fc.agent,
            .tools = fc.tools,
            .skills = fc.skills,
            .audit = fc.audit,
            .schedule = fc.schedule,
            .dirs = dirs,
            .active_config_file = active,
        };
    }

    /// 在已加载的配置上叠加 SCOOT_* 环境变量覆盖。
    /// 优先级：SCOOT_* env > 配置文件 > 内置默认（env 永远胜，无论配置文件是否存在）。
    /// 便于 CI / GitHub Actions 等零配置临时运行：把后端地址、模型、策略等经 env 传入，
    /// 配合 `SCOOT_HOME=$(mktemp -d)` 即可跑完即焚。
    /// **密钥仍只经 backend.api_key_env 指向的变量取值（默认 OPENAI_API_KEY），此处绝不读明文密钥。**
    /// 类型非法的项被忽略并记入 `report.env_warnings`，由上层告警到 stderr（不污染 stdout）。
    pub fn applyEnvOverrides(
        self: *Config,
        arena: std.mem.Allocator,
        env: *const Environ.Map,
        report: ?*LoadReport,
    ) std.mem.Allocator.Error!void {
        var warnings: std.ArrayList([]const u8) = .empty;

        // backend（不含明文密钥）
        if (envVal(env, "SCOOT_BACKEND_BASE_URL")) |v| self.backend.base_url = try arena.dupe(u8, v);
        if (envVal(env, "SCOOT_BACKEND_MODEL")) |v| self.backend.model = try arena.dupe(u8, v);
        if (envVal(env, "SCOOT_BACKEND_API_KEY_ENV")) |v| self.backend.api_key_env = try arena.dupe(u8, v);
        if (envVal(env, "SCOOT_BACKEND_API_KEY_FILE")) |v| self.backend.api_key_file = try arena.dupe(u8, v);
        if (envVal(env, "SCOOT_BACKEND_API_KEY_CMD")) |v| self.backend.api_key_cmd = try arena.dupe(u8, v);
        if (envVal(env, "SCOOT_BACKEND_CA_FILE")) |v| self.backend.ca_file = try arena.dupe(u8, v);
        if (envVal(env, "SCOOT_BACKEND_PROMPT_CACHE")) |v| self.backend.prompt_cache = try arena.dupe(u8, v);
        if (envVal(env, "SCOOT_BACKEND_EXTRA_BODY")) |v| {
            if (std.json.parseFromSliceLeaky(std.json.Value, arena, v, .{})) |parsed| {
                if (parsed == .object)
                    self.backend.extra_body = parsed
                else
                    try warnEnv(&warnings, arena, "SCOOT_BACKEND_EXTRA_BODY", "需为 JSON 对象，已忽略");
            } else |_| {
                try warnEnv(&warnings, arena, "SCOOT_BACKEND_EXTRA_BODY", "JSON 解析失败，已忽略");
            }
        }

        // agent
        try overrideEnvEnumString(env, "SCOOT_AGENT_DEFAULT_MODE", &self.agent.default_mode, &.{ "goal", "plan" }, &warnings, arena);
        try overrideEnvEnumString(env, "SCOOT_AGENT_COMPACTOR", &self.agent.compactor, &.{ "drop", "extractive" }, &warnings, arena);
        try overrideEnvInt(u32, env, "SCOOT_AGENT_MAX_TURNS", &self.agent.max_turns, &warnings, arena);
        try overrideEnvInt(usize, env, "SCOOT_AGENT_CONTEXT_BUDGET_BYTES", &self.agent.context_budget_bytes, &warnings, arena);

        // tools
        try overrideEnvEnumString(env, "SCOOT_TOOLS_POLICY", &self.tools.policy, &.{ "guarded", "readonly", "unrestricted", "yolo" }, &warnings, arena);
        try overrideEnvInt(u64, env, "SCOOT_TOOLS_TIMEOUT_MS", &self.tools.timeout_ms, &warnings, arena);
        try overrideEnvBool(env, "SCOOT_TOOLS_CONFINE_WRITES", &self.tools.confine_writes, &warnings, arena);
        try overrideEnvBool(env, "SCOOT_TOOLS_BLOCK_INTERNAL_HTTP", &self.tools.block_internal_http, &warnings, arena);

        // skills
        try overrideEnvBool(env, "SCOOT_SKILLS_ENABLED", &self.skills.enabled, &warnings, arena);
        try overrideEnvBool(env, "SCOOT_SKILLS_INCLUDE_AGENTS_SKILLS", &self.skills.include_agents_skills, &warnings, arena);

        // audit
        try overrideEnvEnumString(env, "SCOOT_AUDIT_LEVEL", &self.audit.level, &.{ "debug", "info", "warn", "error" }, &warnings, arena);
        try overrideEnvBool(env, "SCOOT_AUDIT_TO_FILE", &self.audit.to_file, &warnings, arena);

        if (report) |r| r.env_warnings = warnings.items;
    }

    /// 按配置来源解析 API token（env > file > cmd）。明文绝不入库。
    pub fn resolveToken(
        self: Config,
        arena: std.mem.Allocator,
        io: std.Io,
        env: *const Environ.Map,
    ) !secret.Secret {
        var srcs: std.ArrayList(secret.Source) = .empty;
        try srcs.append(arena, .{ .env = self.backend.api_key_env });
        try srcs.append(arena, .{ .file = self.backend.api_key_file orelse self.dirs.token_file });
        if (self.backend.api_key_cmd) |cmd| try srcs.append(arena, .{ .command = cmd });
        return secret.resolve(arena, io, env, srcs.items);
    }

    /// 全部 skill 搜索路径，按优先级排列（先者胜：`Registry.discover` 同名去重，
    /// 越靠前越优先）。约定与其它 agent 工具兼容：
    ///   ① `<cwd>/.agents/skills` —— 项目本地、随仓库携带，最高优先（相对路径，按进程 cwd 解析）；
    ///   ② `~/.agents/skills`     —— 可选的跨 agent 用户级目录（include_agents_skills=true）；
    ///   ③ `~/.scoot/skills`      —— Scoot 自有用户级目录；
    ///   ④ config 中显式声明的 `extra_paths`。
    pub fn skillPaths(self: Config, arena: std.mem.Allocator) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        try list.append(arena, ".agents/skills");
        if (self.skills.include_agents_skills) {
            if (self.dirs.agents_skills_dir) |d| try list.append(arena, d);
        }
        try list.append(arena, self.dirs.skills_dir);
        for (self.skills.extra_paths) |p| try list.append(arena, p);
        return list.items;
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "skillPaths：默认不加载 ~/.agents/skills，可显式开启" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dirs = try paths.Paths.fromHome(arena, "/home/u/.scoot");
    dirs.agents_skills_dir = "/home/u/.agents/skills";
    const cfg_default: Config = .{ .dirs = dirs, .skills = .{ .enabled = true, .extra_paths = &.{"/opt/extra/skills"} } };
    const got_default = try cfg_default.skillPaths(arena);
    try std.testing.expectEqual(@as(usize, 3), got_default.len);
    try std.testing.expectEqualStrings(".agents/skills", got_default[0]);
    try std.testing.expectEqualStrings("/home/u/.scoot/skills", got_default[1]);
    try std.testing.expectEqualStrings("/opt/extra/skills", got_default[2]);

    const cfg: Config = .{ .dirs = dirs, .skills = .{ .enabled = true, .include_agents_skills = true, .extra_paths = &.{"/opt/extra/skills"} } };
    const got = try cfg.skillPaths(arena);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings(".agents/skills", got[0]);
    try std.testing.expectEqualStrings("/home/u/.agents/skills", got[1]);
    try std.testing.expectEqualStrings("/home/u/.scoot/skills", got[2]);
    try std.testing.expectEqualStrings("/opt/extra/skills", got[3]);

    // 无法确定 $HOME（agents_skills_dir == null）：即使开启也跳过该级，cwd 仍最优先。
    var cfg2: Config = .{
        .dirs = try paths.Paths.fromHome(arena, "/home/u/.scoot"),
        .skills = .{ .include_agents_skills = true },
    };
    cfg2.dirs.agents_skills_dir = null;
    const got2 = try cfg2.skillPaths(arena);
    try std.testing.expectEqual(@as(usize, 2), got2.len);
    try std.testing.expectEqualStrings(".agents/skills", got2[0]);
    try std.testing.expectEqualStrings("/home/u/.scoot/skills", got2[1]);
}

test "parseTomlConfig: TOML → FileConfig（含 extra_body 透传 + 按节合并）" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\# Scoot 配置（TOML，可读性更好）
        \\[backend]
        \\base_url = "https://x.azure.com/openai/v1"
        \\model = "gpt-5.5"
        \\api_key_env = "WJT_AZURE_OPENAI_API_KEY"
        \\
        \\[backend.extra_body]
        \\service_tier = "priority"
        \\reasoning_effort = "high"
        \\
        \\[tools]
        \\policy = "guarded"
        \\
        \\[skills]
        \\include_agents_skills = true
    ;
    const fc = try parseTomlConfig(arena.allocator(), src, null);
    try std.testing.expectEqualStrings("https://x.azure.com/openai/v1", fc.backend.base_url);
    try std.testing.expectEqualStrings("gpt-5.5", fc.backend.model);
    try std.testing.expectEqualStrings("WJT_AZURE_OPENAI_API_KEY", fc.backend.api_key_env);
    try std.testing.expectEqualStrings("guarded", fc.tools.policy);
    try std.testing.expectEqual(true, fc.skills.include_agents_skills);
    // 未指定的节回落默认
    try std.testing.expectEqual(@as(u32, 32), fc.agent.max_turns);
    // extra_body 透传为 std.json.Value 对象
    try std.testing.expect(fc.backend.extra_body != null);
    const eb = fc.backend.extra_body.?.object;
    try std.testing.expectEqualStrings("priority", eb.get("service_tier").?.string);
    try std.testing.expectEqualStrings("high", eb.get("reasoning_effort").?.string);
}

test "parseTomlConfig: 表数组 schedule.jobs 正确映射" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[schedule]
        \\enabled = true
        \\
        \\[[schedule.jobs]]
        \\id = "disk"
        \\goal = "巡检磁盘"
        \\every_sec = 300
    ;
    const fc = try parseTomlConfig(arena.allocator(), src, null);
    try std.testing.expectEqual(true, fc.schedule.enabled);
    try std.testing.expectEqual(@as(usize, 1), fc.schedule.jobs.len);
    try std.testing.expectEqualStrings("disk", fc.schedule.jobs[0].id);
    try std.testing.expectEqual(@as(?u64, 300), fc.schedule.jobs[0].every_sec);
}

test "parseTomlConfig: 空白回落默认；畸形 → InvalidConfig" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseTomlConfig(arena.allocator(), "\n# 仅注释\n", null);
    try std.testing.expectEqualStrings("qwen2.5", fc.backend.model);
    try std.testing.expectError(error.InvalidConfig, parseTomlConfig(arena.allocator(), "a = 2020-01-01", null));
}

test "parseTomlConfig: 拼写键被收集以告警，并回落默认（issue #45）" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[tools]
        \\polcy = "readonly"
        \\
        \\[backend]
        \\modle = "x"
        \\base_url = "https://h/v1"
    ;
    var report: LoadReport = .{};
    const fc = try parseTomlConfig(arena.allocator(), src, &report);
    // 拼写键被忽略：policy 悄悄回落默认 guarded（正是 issue #45 的危险点）。
    try std.testing.expectEqualStrings("guarded", fc.tools.policy);
    try std.testing.expectEqualStrings("https://h/v1", fc.backend.base_url);
    try std.testing.expectEqual(@as(usize, 2), report.unknown_keys.len);
    var saw_polcy = false;
    var saw_modle = false;
    for (report.unknown_keys) |k| {
        if (std.mem.eql(u8, k, "tools.polcy")) saw_polcy = true;
        if (std.mem.eql(u8, k, "backend.modle")) saw_modle = true;
    }
    try std.testing.expect(saw_polcy and saw_modle);
}

test "parseTomlConfig: 合法键与 extra_body/表数组自由内容不误报（issue #45）" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[backend]
        \\model = "m"
        \\
        \\[backend.extra_body]
        \\service_tier = "priority"
        \\anything_here = 1
        \\
        \\[[schedule.jobs]]
        \\id = "j1"
        \\every_sec = 60
    ;
    var report: LoadReport = .{};
    _ = try parseTomlConfig(arena.allocator(), src, &report);
    try std.testing.expectEqual(@as(usize, 0), report.unknown_keys.len);
}

test "parseFileConfig: 空白内容回落默认" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(), "  \n\t ", null);
    try std.testing.expectEqualStrings("qwen2.5", fc.backend.model);
    try std.testing.expectEqual(@as(u32, 32), fc.agent.max_turns);
    try std.testing.expectEqual(@as(u64, 30_000), fc.tools.timeout_ms);
}

test "parseFileConfig: 空对象回落默认" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(), "{}", null);
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1", fc.backend.base_url);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", fc.backend.api_key_env);
}

test "parseFileConfig: backend.extra_body 透传任意 JSON 对象" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{ "backend": { "extra_body": { "service_tier": "priority", "reasoning_effort": "high" } } }
    ;
    const fc = try parseFileConfig(arena.allocator(), json, null);
    try std.testing.expect(fc.backend.extra_body != null);
    try std.testing.expect(fc.backend.extra_body.? == .object);
    const tier = fc.backend.extra_body.?.object.get("service_tier").?;
    try std.testing.expectEqualStrings("priority", tier.string);
    const effort = fc.backend.extra_body.?.object.get("reasoning_effort").?;
    try std.testing.expectEqualStrings("high", effort.string);
}

test "parseFileConfig: 未指定 extra_body → null（默认无扩展参数）" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(), "{\"backend\":{\"model\":\"m\"}}", null);
    try std.testing.expect(fc.backend.extra_body == null);
}

test "parseFileConfig: 按节按字段合并，未指定字段保留默认" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{
        \\  "backend": { "model": "llama3.1", "base_url": "http://10.0.0.2:1234/v1" },
        \\  "agent": { "max_turns": 8 },
        \\  "tools": { "timeout_ms": 5000 }
        \\}
    ;
    const fc = try parseFileConfig(arena.allocator(), json, null);
    try std.testing.expectEqualStrings("llama3.1", fc.backend.model);
    try std.testing.expectEqualStrings("http://10.0.0.2:1234/v1", fc.backend.base_url);
    // 未指定 → 默认
    try std.testing.expectEqualStrings("OPENAI_API_KEY", fc.backend.api_key_env);
    try std.testing.expectEqual(@as(u32, 8), fc.agent.max_turns);
    try std.testing.expectEqualStrings("goal", fc.agent.default_mode);
    try std.testing.expectEqualStrings("drop", fc.agent.compactor);
    try std.testing.expectEqual(@as(u64, 5000), fc.tools.timeout_ms);
}

test "parseFileConfig: agent compactor 可配置" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(),
        \\{ "agent": { "compactor": "extractive", "context_budget_bytes": 120000 } }
    , null);
    try std.testing.expectEqualStrings("extractive", fc.agent.compactor);
    try std.testing.expectEqual(@as(usize, 120000), fc.agent.context_budget_bytes);
}

test "parseFileConfig: 可选 token 来源与额外 skill 路径" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{
        \\  "backend": { "api_key_cmd": "pass show openai" },
        \\  "skills": { "extra_paths": ["/opt/scoot/skills", "./skills"] }
        \\}
    ;
    const fc = try parseFileConfig(arena.allocator(), json, null);
    try std.testing.expect(fc.backend.api_key_cmd != null);
    try std.testing.expectEqualStrings("pass show openai", fc.backend.api_key_cmd.?);
    try std.testing.expect(fc.backend.api_key_file == null);
    try std.testing.expectEqual(@as(usize, 2), fc.skills.extra_paths.len);
    try std.testing.expectEqualStrings("/opt/scoot/skills", fc.skills.extra_paths[0]);
}

test "parseFileConfig: 未知字段忽略" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(),
        \\{ "backend": { "model": "m" }, "future_key": 123, "nested": { "x": true } }
    , null);
    try std.testing.expectEqualStrings("m", fc.backend.model);
}

test "parseFileConfig: 畸形 JSON → InvalidConfig" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidConfig, parseFileConfig(arena.allocator(), "{ not json", null));
    try std.testing.expectError(error.InvalidConfig, parseFileConfig(arena.allocator(),
        \\{ "agent": { "max_turns": "not-a-number" } }
    , null));
}

test "parseFileConfig: schedule 节默认关闭" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(), "{}", null);
    try std.testing.expect(!fc.schedule.enabled);
    try std.testing.expectEqual(@as(u64, 1000), fc.schedule.poll_ms);
    try std.testing.expectEqual(@as(usize, 0), fc.schedule.jobs.len);
}

test "parseFileConfig: schedule jobs 解析" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{
        \\  "schedule": {
        \\    "enabled": true,
        \\    "poll_ms": 500,
        \\    "jobs": [
        \\      { "id": "heartbeat", "goal": "检查磁盘", "every_sec": 60 },
        \\      { "id": "once", "goal": "一次性", "at_unix": 99999, "mode": "unrestricted" }
        \\    ]
        \\  }
        \\}
    ;
    const fc = try parseFileConfig(arena.allocator(), json, null);
    try std.testing.expect(fc.schedule.enabled);
    try std.testing.expectEqual(@as(u64, 500), fc.schedule.poll_ms);
    try std.testing.expectEqual(@as(usize, 2), fc.schedule.jobs.len);
    try std.testing.expectEqualStrings("heartbeat", fc.schedule.jobs[0].id);
    try std.testing.expectEqualStrings("readonly", fc.schedule.jobs[0].mode); // 默认
    try std.testing.expectEqualStrings("unrestricted", fc.schedule.jobs[1].mode);
}

test "JobConfig.toJob: 触发器校验与策略矫正" {
    // 恰好一个触发器 → 合法
    const ok = JobConfig{ .id = "a", .every_sec = 30 };
    const job = ok.toJob().?;
    try std.testing.expectEqual(policy.Mode.readonly, job.mode); // 默认 readonly

    // guarded 配置经 effectiveMode 矫正为 readonly（铁律 #1）
    const guarded = JobConfig{ .id = "g", .every_sec = 30, .mode = "guarded" };
    try std.testing.expectEqual(policy.Mode.guarded, guarded.toJob().?.mode); // 原始保留
    try std.testing.expectEqual(policy.Mode.readonly, guarded.toJob().?.effectiveMode()); // 执行矫正

    // 零触发器 → 非法
    const none = JobConfig{ .id = "n" };
    try std.testing.expect(none.toJob() == null);

    // 多触发器 → 非法
    const multi = JobConfig{ .id = "m", .every_sec = 30, .at_unix = 100 };
    try std.testing.expect(multi.toJob() == null);

    // cron 语法非法 → 非法任务，避免装载后静默永不触发
    const bad_cron = JobConfig{ .id = "c", .cron = "60 * * * *" };
    try std.testing.expect(bad_cron.toJob() == null);
}

test "applyEnvOverrides: 字符串项覆盖 backend 与 tools" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("SCOOT_BACKEND_BASE_URL", "https://example.test/v1");
    try map.put("SCOOT_BACKEND_MODEL", "gpt-override");
    try map.put("SCOOT_BACKEND_PROMPT_CACHE", "anthropic");
    try map.put("SCOOT_TOOLS_POLICY", "readonly");

    var cfg: Config = .{ .dirs = undefined };
    var report: LoadReport = .{};
    try cfg.applyEnvOverrides(arena.allocator(), &map, &report);

    try std.testing.expectEqualStrings("https://example.test/v1", cfg.backend.base_url);
    try std.testing.expectEqualStrings("gpt-override", cfg.backend.model);
    try std.testing.expectEqualStrings("anthropic", cfg.backend.prompt_cache);
    try std.testing.expectEqualStrings("readonly", cfg.tools.policy);
    try std.testing.expectEqual(@as(usize, 0), report.env_warnings.len);
}

test "applyEnvOverrides: 枚举字符串非法时告警且保留原值" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("SCOOT_AGENT_DEFAULT_MODE", "pla");
    try map.put("SCOOT_AGENT_COMPACTOR", "semantic");
    try map.put("SCOOT_TOOLS_POLICY", "readonyl");
    try map.put("SCOOT_AUDIT_LEVEL", "verbose");

    var cfg: Config = .{ .dirs = undefined };
    var report: LoadReport = .{};
    try cfg.applyEnvOverrides(arena.allocator(), &map, &report);

    try std.testing.expectEqualStrings("goal", cfg.agent.default_mode);
    try std.testing.expectEqualStrings("drop", cfg.agent.compactor);
    try std.testing.expectEqualStrings("guarded", cfg.tools.policy);
    try std.testing.expectEqualStrings("info", cfg.audit.level);
    try std.testing.expectEqual(@as(usize, 4), report.env_warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, report.env_warnings[1], "SCOOT_AGENT_COMPACTOR") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.env_warnings[2], "SCOOT_TOOLS_POLICY") != null);
}

test "applyEnvOverrides: 整数/布尔项解析" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("SCOOT_AGENT_MAX_TURNS", "7");
    try map.put("SCOOT_AGENT_COMPACTOR", "extractive");
    try map.put("SCOOT_TOOLS_TIMEOUT_MS", "1234");
    try map.put("SCOOT_TOOLS_CONFINE_WRITES", "true");
    try map.put("SCOOT_TOOLS_BLOCK_INTERNAL_HTTP", "0");
    try map.put("SCOOT_SKILLS_ENABLED", "FALSE");
    try map.put("SCOOT_SKILLS_INCLUDE_AGENTS_SKILLS", "1");

    var cfg: Config = .{ .dirs = undefined };
    try cfg.applyEnvOverrides(arena.allocator(), &map, null);

    try std.testing.expectEqual(@as(u32, 7), cfg.agent.max_turns);
    try std.testing.expectEqualStrings("extractive", cfg.agent.compactor);
    try std.testing.expectEqual(@as(u64, 1234), cfg.tools.timeout_ms);
    try std.testing.expectEqual(true, cfg.tools.confine_writes);
    try std.testing.expectEqual(false, cfg.tools.block_internal_http);
    try std.testing.expectEqual(false, cfg.skills.enabled);
    try std.testing.expectEqual(true, cfg.skills.include_agents_skills);
}

test "applyEnvOverrides: 非法整数/布尔被忽略并记入告警，原值不变" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("SCOOT_AGENT_MAX_TURNS", "abc");
    try map.put("SCOOT_SKILLS_ENABLED", "maybe");

    var cfg: Config = .{ .dirs = undefined };
    var report: LoadReport = .{};
    try cfg.applyEnvOverrides(arena.allocator(), &map, &report);

    try std.testing.expectEqual(@as(u32, 32), cfg.agent.max_turns); // 默认保留
    try std.testing.expectEqual(true, cfg.skills.enabled); // 默认保留
    try std.testing.expectEqual(@as(usize, 2), report.env_warnings.len);
}

test "applyEnvOverrides: 空串视作未设置，不覆盖默认" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("SCOOT_BACKEND_MODEL", "");

    var cfg: Config = .{ .dirs = undefined };
    try cfg.applyEnvOverrides(arena.allocator(), &map, null);

    try std.testing.expectEqualStrings("qwen2.5", cfg.backend.model); // 默认保留
}

test "applyEnvOverrides: extra_body 接受 JSON 对象、拒绝非对象" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    {
        var map: std.process.Environ.Map = .init(std.testing.allocator);
        defer map.deinit();
        try map.put("SCOOT_BACKEND_EXTRA_BODY", "{\"temperature\":0.2}");
        var cfg: Config = .{ .dirs = undefined };
        var report: LoadReport = .{};
        try cfg.applyEnvOverrides(arena.allocator(), &map, &report);
        try std.testing.expect(cfg.backend.extra_body != null);
        try std.testing.expect(cfg.backend.extra_body.? == .object);
        try std.testing.expectEqual(@as(usize, 0), report.env_warnings.len);
    }
    {
        var map: std.process.Environ.Map = .init(std.testing.allocator);
        defer map.deinit();
        try map.put("SCOOT_BACKEND_EXTRA_BODY", "[1,2,3]");
        var cfg: Config = .{ .dirs = undefined };
        var report: LoadReport = .{};
        try cfg.applyEnvOverrides(arena.allocator(), &map, &report);
        try std.testing.expect(cfg.backend.extra_body == null); // 非对象被拒
        try std.testing.expectEqual(@as(usize, 1), report.env_warnings.len);
    }
}

test "applyEnvOverrides: api_key_env 覆盖间接指向（仍不读明文密钥）" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("SCOOT_BACKEND_API_KEY_ENV", "LLM_KEY");

    var cfg: Config = .{ .dirs = undefined };
    try cfg.applyEnvOverrides(arena.allocator(), &map, null);

    try std.testing.expectEqualStrings("LLM_KEY", cfg.backend.api_key_env);
}
