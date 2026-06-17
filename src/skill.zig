//! Skill 机制（用户明示「必须」的可扩展能力）：把"打包好的能力 + 指令集"
//! 以目录形式挂载给 Agent，让 Scoot 无需改代码即可获得专门领域的操作知识。
//!
//! 一个 Skill 就是一个目录：
//!   <skill>/
//!     SKILL.md       必需：YAML front-matter(name, description, optional metadata) + Markdown 正文指令
//!     scripts/       可选：脚本等资源（被调用时同样经统一 bash 沙盒，受策略门 + 硬超时约束）
//!     references/    可选：按需加载的参考资料
//!
//! 渐进式披露（服务「轻量化」铁律，避免上下文爆炸）：
//!   1) 发现：扫描各 skill 路径，**只解析 front-matter**（name+description）建轻量索引；
//!   2) 注入：把可用 skill 的 name+description+路径渲染成清单注入 system 上下文；
//!   3) 激活：模型判断某 skill 相关时，用**原生 `skill` 动作**按名读取其 SKILL.md 正文获取
//!      完整指令（正文绝不预先注入，故上下文恒定轻量）；
//!   4) 执行：skill 自带脚本经统一 bash 工具沙盒执行——**不给技能任何特权执行通道**，
//!      与普通命令一样先过执行护栏、再带硬超时运行（兑现「安全可控」铁律）。
//!
//! 设计取舍：读取技能指令是 agent 的**原生只读能力**（见 agent.zig 的 `skill` 动作），
//!   刻意不受执行策略约束——故 readonly 等 fail-closed 档下仍能正常激活技能；而技能里
//!   **让模型去执行**的脚本/命令仍走全局 policy gate，不获任何特权。读取经 `skill` 动作
//!   即被审计为 tool_call，可追溯性不打折。per-skill `capabilities` / `allowed_tools` /
//!   `scope` 是审查声明，不授予任何额外权限；真正执行仍由全局 policy gate 决定。
const std = @import("std");

/// 读取单个 SKILL.md 的大小上限：1 MiB（指令文件实际仅几 KiB，留足冗余防失控）。
const skill_read_limit: std.Io.Limit = .limited(1 << 20);

/// 单个 skill 的轻量元数据（来自 SKILL.md front-matter）。正文不在此驻留——
/// 渐进式披露下，正文仅在模型激活时经 bash 按需读取。
pub const Skill = struct {
    /// 技能名（front-matter `name`）。
    name: []const u8,
    /// 一句话描述（front-matter `description`），决定模型是否激活它。
    description: []const u8,
    /// 技能目录路径；其下的 SKILL.md 即完整指令。
    dir: []const u8,
    /// 可选审查声明：skill 提供的能力类型（逗号或内联列表形式）。
    capabilities: []const u8 = "",
    /// 可选审查声明：skill 预期会用到的工具动作（不授予权限）。
    allowed_tools: []const u8 = "",
    /// 可选审查声明：文档适用范围。
    scope: []const u8 = "",
};

/// front-matter 解析结果：借用源文本的切片，无分配（纯函数，便于防弹测试）。
pub const Meta = struct {
    name: []const u8,
    description: []const u8,
    capabilities: []const u8 = "",
    allowed_tools: []const u8 = "",
    scope: []const u8 = "",
    compatibility_key: []const u8 = "",
    compatibility: []const u8 = "",
};

pub const Validation = union(enum) {
    valid: Meta,
    invalid: []const u8,
};

/// 解析 SKILL.md 的 YAML front-matter，仅提取 Scoot 关心的轻量元数据。
/// 返回 null 表示「没有合法 front-matter 或缺 name」——该目录不是 skill，调用方应跳过。
/// 返回的切片借用 `src`，调用方需在使用期间保证 `src` 存活。
/// 防弹：任意非法/截断输入只会得到 null，绝不越界或 panic。
pub fn parseFrontMatter(src: []const u8) ?Meta {
    // 跳过开头空白与空行后，必须以独占一行的 "---" 开栅栏。
    const after_open = stripOpenFence(std.mem.trimStart(u8, src, " \t\r\n")) orelse return null;

    var name: []const u8 = "";
    var description: []const u8 = "";
    var capabilities: []const u8 = "";
    var allowed_tools: []const u8 = "";
    var scope: []const u8 = "";
    var compatibility_key: []const u8 = "";
    var compatibility: []const u8 = "";
    var closed = false;

    var lines = std.mem.splitScalar(u8, after_open, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "---")) {
            closed = true;
            break;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = stripQuotes(std.mem.trim(u8, line[colon + 1 ..], " \t"));
        if (std.ascii.eqlIgnoreCase(key, "name")) {
            name = val;
        } else if (std.ascii.eqlIgnoreCase(key, "description")) {
            description = val;
        } else if (std.ascii.eqlIgnoreCase(key, "capabilities")) {
            capabilities = val;
        } else if (std.ascii.eqlIgnoreCase(key, "allowed_tools")) {
            allowed_tools = val;
        } else if (std.ascii.eqlIgnoreCase(key, "scope")) {
            scope = val;
        } else if (std.ascii.eqlIgnoreCase(key, "scoot_version") or
            std.ascii.eqlIgnoreCase(key, "compatibility") or
            std.ascii.eqlIgnoreCase(key, "requires_scoot"))
        {
            compatibility_key = key;
            compatibility = val;
        }
    }

    if (!closed) return null; // 缺闭合栅栏 = 畸形 front-matter，整体作废
    if (name.len == 0) return null; // 无名技能无法被模型选用，跳过
    return .{
        .name = name,
        .description = description,
        .capabilities = capabilities,
        .allowed_tools = allowed_tools,
        .scope = scope,
        .compatibility_key = compatibility_key,
        .compatibility = compatibility,
    };
}

/// 严格校验一个 skill 目录。与 discover 不同，这里面向作者/审查者，必须给出清晰失败。
pub fn validateDir(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !Validation {
    const cwd = std.Io.Dir.cwd();
    const md_path = try std.fs.path.join(arena, &.{ dir, "SKILL.md" });
    const bytes = cwd.readFileAlloc(io, md_path, arena, skill_read_limit) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{ .invalid = "missing SKILL.md" },
        else => return .{ .invalid = try std.fmt.allocPrint(arena, "cannot read SKILL.md: {s}", .{@errorName(err)}) },
    };
    const meta = parseFrontMatter(bytes) orelse return .{
        .invalid = "SKILL.md must start with YAML front matter containing a non-empty name",
    };
    if (!isValidName(meta.name)) return .{
        .invalid = "name must use only ASCII letters, digits, '.', '_' or '-'",
    };
    if (meta.description.len == 0) return .{
        .invalid = "description is required",
    };
    if (validateCapabilities(arena, meta.capabilities)) |msg| return .{ .invalid = msg };
    if (validateAllowedTools(arena, meta.allowed_tools)) |msg| return .{ .invalid = msg };
    if (validateScope(meta.scope)) |msg| return .{ .invalid = msg };
    if (meta.compatibility_key.len != 0) return .{
        .invalid = try std.fmt.allocPrint(
            arena,
            "unsupported compatibility declaration `{s}`; omit it until Scoot defines skill compatibility gates",
            .{meta.compatibility_key},
        ),
    };
    return .{ .valid = meta };
}

pub fn parseInlineList(arena: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return &.{};
    if (s[0] == '[') {
        if (s.len < 2 or s[s.len - 1] != ']') return error.InvalidSkillList;
        s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
    }
    if (s.len == 0) return &.{};

    var items: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, s, ',');
    while (parts.next()) |part| {
        const item = stripQuotes(std.mem.trim(u8, part, " \t\r\n"));
        if (item.len == 0) return error.InvalidSkillList;
        try items.append(arena, item);
    }
    return items.items;
}

fn validateCapabilities(arena: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const items = parseInlineList(arena, raw) catch return "capabilities must be an inline list such as [instructions, scripts]";
    for (items) |item| {
        if (std.mem.eql(u8, item, "instructions") or
            std.mem.eql(u8, item, "scripts") or
            std.mem.eql(u8, item, "references"))
        {
            continue;
        }
        return std.fmt.allocPrint(
            arena,
            "unsupported capability `{s}`; use instructions, scripts, or references",
            .{item},
        ) catch "unsupported capability";
    }
    return null;
}

fn validateAllowedTools(arena: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const items = parseInlineList(arena, raw) catch return "allowed_tools must be an inline list such as [file_read, grep]";
    for (items) |item| {
        if (isKnownToolAction(item)) continue;
        return std.fmt.allocPrint(
            arena,
            "unknown allowed_tools entry `{s}`; use known tool action names",
            .{item},
        ) catch "unknown allowed_tools entry";
    }
    return null;
}

fn validateScope(raw: []const u8) ?[]const u8 {
    const scope = stripQuotes(std.mem.trim(u8, raw, " \t\r\n"));
    if (scope.len == 0) return null;
    if (std.mem.eql(u8, scope, "general") or
        std.mem.eql(u8, scope, "project") or
        std.mem.eql(u8, scope, "repository") or
        std.mem.eql(u8, scope, "domain") or
        std.mem.eql(u8, scope, "workflow"))
    {
        return null;
    }
    return "scope must be one of: general, project, repository, domain, workflow";
}

fn isKnownToolAction(name: []const u8) bool {
    return std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "file_read") or
        std.mem.eql(u8, name, "file_write") or
        std.mem.eql(u8, name, "file_edit") or
        std.mem.eql(u8, name, "grep") or
        std.mem.eql(u8, name, "glob") or
        std.mem.eql(u8, name, "http_request") or
        std.mem.eql(u8, name, "parallel");
}

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-') continue;
        return false;
    }
    return true;
}

/// 若 `s` 以独占一行的 "---" 开头，返回其后的剩余文本；否则 null。
fn stripOpenFence(s: []const u8) ?[]const u8 {
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return null;
    const first = std.mem.trimEnd(u8, s[0..nl], " \t\r");
    if (!std.mem.eql(u8, first, "---")) return null;
    return s[nl + 1 ..];
}

/// 去掉成对的首尾引号（YAML 常见 `name: "foo"`）。
fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        const a = s[0];
        const b = s[s.len - 1];
        if ((a == '"' and b == '"') or (a == '\'' and b == '\'')) return s[1 .. s.len - 1];
    }
    return s;
}

/// Skill 注册表：聚合多个 skill 搜索路径下发现的 skill。
/// 元数据副本由传入的 `gpa` 拥有（同名先到先得去重），`deinit` 须用同一 `gpa`。
pub const Registry = struct {
    skills: std.ArrayList(Skill) = .empty,

    /// 扫描一个 skill 路径：遍历其直接子目录，对含 SKILL.md 且 front-matter 合法者登记。
    /// 路径不存在/非目录 → 静默跳过（技能是增强项，缺路径不是错误）。
    /// 单个子目录缺 SKILL.md 或 front-matter 非法 → 跳过该目录，不影响其余。
    pub fn discover(self: *Registry, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue; // 跳过隐藏目录

            const md_path = try std.fs.path.join(gpa, &.{ path, entry.name, "SKILL.md" });
            defer gpa.free(md_path);

            const bytes = cwd.readFileAlloc(io, md_path, gpa, skill_read_limit) catch |err| switch (err) {
                error.FileNotFound => continue, // 该子目录不是技能
                else => return err,
            };
            defer gpa.free(bytes);

            const meta = parseFrontMatter(bytes) orelse continue;
            if (self.find(meta.name) != null) continue; // 同名去重：先发现者胜

            const name = try gpa.dupe(u8, meta.name);
            errdefer gpa.free(name);
            const desc = try gpa.dupe(u8, meta.description);
            errdefer gpa.free(desc);
            const capabilities = try gpa.dupe(u8, meta.capabilities);
            errdefer gpa.free(capabilities);
            const allowed_tools = try gpa.dupe(u8, meta.allowed_tools);
            errdefer gpa.free(allowed_tools);
            const scope = try gpa.dupe(u8, meta.scope);
            errdefer gpa.free(scope);
            const skill_dir = try std.fs.path.join(gpa, &.{ path, entry.name });
            errdefer gpa.free(skill_dir);
            try self.skills.append(gpa, .{
                .name = name,
                .description = desc,
                .dir = skill_dir,
                .capabilities = capabilities,
                .allowed_tools = allowed_tools,
                .scope = scope,
            });
        }
    }

    /// 依次扫描多个搜索路径。后扫描到的同名技能被忽略（前者优先）。
    pub fn discoverAll(self: *Registry, gpa: std.mem.Allocator, io: std.Io, paths: []const []const u8) !void {
        for (paths) |p| try self.discover(gpa, io, p);
    }

    /// 按名查找已发现的技能。
    pub fn find(self: *Registry, name: []const u8) ?*Skill {
        for (self.skills.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn count(self: *const Registry) usize {
        return self.skills.items.len;
    }

    /// 把已发现技能渲染为可注入 system 上下文的清单（仅 name+description+路径，不含正文）。
    /// 无技能时返回 ""（调用方据此决定是否注入）。文本本身携带激活指令，故无需改动主 system prompt。
    pub fn manifest(self: *const Registry, arena: std.mem.Allocator) ![]const u8 {
        if (self.skills.items.len == 0) return "";
        var aw = std.Io.Writer.Allocating.init(arena);
        const w = &aw.writer;
        try w.writeAll(
            \\## 可用技能（Skills）
            \\你装载了以下预制技能，可用来完成专门任务。每个技能目录下的 SKILL.md 是其完整操作指令。
            \\当且仅当某技能与当前任务相关时，先用 action="skill"（Scoot 原生只读能力，不受执行策略限制，
            \\readonly 下同样可用）读取它的指令再据此行动：action_input={"name":"技能名"}（默认读 SKILL.md；
            \\读其它资源用 {"name":"技能名","path":"references/xxx"}）。无关时不要读取，保持上下文精简。
            \\技能里要你执行的脚本 / 命令仍经普通工具沙盒（先过执行护栏、带硬超时），是否可用取决于当前策略模式。
            \\
            \\
        );
        for (self.skills.items) |s| {
            try w.print("- {s}：{s}\n  读取指令：action=\"skill\", action_input={{\"name\":\"{s}\"}}（目录：{s}）\n", .{ s.name, s.description, s.name, s.dir });
        }
        try w.writeAll("\n未列出的技能不存在，不要臆造。\n");
        return aw.written();
    }

    /// 释放所有技能元数据副本及列表（须用与 discover 相同的 `gpa`）。
    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.skills.items) |s| {
            gpa.free(s.name);
            gpa.free(s.description);
            gpa.free(s.dir);
            gpa.free(s.capabilities);
            gpa.free(s.allowed_tools);
            gpa.free(s.scope);
        }
        self.skills.deinit(gpa);
    }
};

test "parseFrontMatter: 正常解析 name 与 description" {
    const src =
        \\---
        \\name: git-helper
        \\description: 协助处理 git 仓库操作
        \\---
        \\# 正文
        \\随便写点指令。
    ;
    const m = parseFrontMatter(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("git-helper", m.name);
    try std.testing.expectEqualStrings("协助处理 git 仓库操作", m.description);
}

test "parseFrontMatter: 去引号 + 忽略未知键 + 冒号在值中" {
    const src =
        \\---
        \\name: "deploy"
        \\capabilities: [instructions, scripts]
        \\allowed_tools: [bash, file_read]
        \\scope: workflow
        \\description: '比例 a:b 的部署助手'
        \\extra: 忽略我
        \\---
        \\body
    ;
    const m = parseFrontMatter(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("deploy", m.name);
    try std.testing.expectEqualStrings("比例 a:b 的部署助手", m.description);
    try std.testing.expectEqualStrings("[instructions, scripts]", m.capabilities);
    try std.testing.expectEqualStrings("[bash, file_read]", m.allowed_tools);
    try std.testing.expectEqualStrings("workflow", m.scope);
}

test "parseFrontMatter: 识别兼容性声明供校验阶段拒绝" {
    const src =
        \\---
        \\name: future
        \\description: 未来版本技能
        \\scoot_version: ">=1.0.0"
        \\---
        \\body
    ;
    const m = parseFrontMatter(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("future", m.name);
    try std.testing.expectEqualStrings("scoot_version", m.compatibility_key);
    try std.testing.expectEqualStrings(">=1.0.0", m.compatibility);
}

test "parseFrontMatter: CRLF 行尾" {
    const src = "---\r\nname: win\r\ndescription: 处理 windows 行尾\r\n---\r\nbody\r\n";
    const m = parseFrontMatter(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("win", m.name);
    try std.testing.expectEqualStrings("处理 windows 行尾", m.description);
}

test "parseFrontMatter: 前导空行后仍可解析" {
    const src = "\n\n  \n---\nname: lead\ndescription: 前面有空行\n---\nbody";
    const m = parseFrontMatter(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("lead", m.name);
}

test "parseFrontMatter: 非法输入一律返回 null（防弹）" {
    try std.testing.expect(parseFrontMatter("") == null); // 空
    try std.testing.expect(parseFrontMatter("no front matter here") == null); // 无栅栏
    try std.testing.expect(parseFrontMatter("---\nname: x\ndescription: y\n") == null); // 缺闭合
    try std.testing.expect(parseFrontMatter("---\ndescription: 无名\n---\n") == null); // 缺 name
    try std.testing.expect(parseFrontMatter("---") == null); // 只有半截栅栏
    try std.testing.expect(parseFrontMatter("--- not a fence\nname: x\n---\n") == null); // 开栅栏行有杂质
}

test "Registry: discover 扫描目录、解析、去重、渲染清单" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_skill_discover_test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    // 合法技能 alpha
    try cwd.createDirPath(io, root ++ "/alpha");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/alpha/SKILL.md",
        .data = "---\nname: alpha\ndescription: 第一个技能\n---\n# Alpha\n做 A 事。",
    });
    // beta：无 front-matter → 应跳过
    try cwd.createDirPath(io, root ++ "/beta");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/beta/SKILL.md", .data = "我没有 front-matter" });
    // gamma：无 SKILL.md → 应跳过
    try cwd.createDirPath(io, root ++ "/gamma");

    var reg: Registry = .{};
    defer reg.deinit(gpa);
    try reg.discover(gpa, io, root);

    try std.testing.expectEqual(@as(usize, 1), reg.count());
    const s = reg.find("alpha") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("第一个技能", s.description);
    try std.testing.expect(std.mem.endsWith(u8, s.dir, "/alpha"));
    try std.testing.expect(reg.find("beta") == null);

    // 同名去重：再扫一次同一路径，仍只有一个 alpha
    try reg.discover(gpa, io, root);
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try reg.manifest(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, text, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "第一个技能") != null);
    // 新清单引导模型用原生 `skill` 动作（而非 bash cat）按名读取技能指令。
    try std.testing.expect(std.mem.indexOf(u8, text, "action=\"skill\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"name\":\"alpha\"}") != null);
}

test "Registry: 路径不存在则静默跳过，清单为空" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var reg: Registry = .{};
    defer reg.deinit(gpa);
    try reg.discoverAll(gpa, io, &.{"/tmp/scoot_no_such_skill_dir_xyz"});
    try std.testing.expectEqual(@as(usize, 0), reg.count());
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectEqualStrings("", try reg.manifest(arena.allocator()));
}

test "validateDir: 接受最小合法 skill 目录" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_skill_validate_good";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, root);
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/SKILL.md",
        .data = "---\nname: good-skill\ndescription: A valid local skill.\ncapabilities: [instructions, references]\nallowed_tools: [file_read, grep, glob]\nscope: workflow\n---\n# Good\n",
    });

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const res = try validateDir(arena.allocator(), io, root);
    const meta = switch (res) {
        .valid => |m| m,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("good-skill", meta.name);
    try std.testing.expectEqualStrings("[instructions, references]", meta.capabilities);
    try std.testing.expectEqualStrings("[file_read, grep, glob]", meta.allowed_tools);
    try std.testing.expectEqualStrings("workflow", meta.scope);
}

test "validateDir: 拒绝缺失 description、非法 name、非法元数据与兼容性声明" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_skill_validate_bad";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, root ++ "/no_desc");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/no_desc/SKILL.md",
        .data = "---\nname: no-desc\n---\n# Missing description\n",
    });
    try cwd.createDirPath(io, root ++ "/bad_name");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/bad_name/SKILL.md",
        .data = "---\nname: bad/name\ndescription: Invalid name.\n---\n# Bad\n",
    });
    try cwd.createDirPath(io, root ++ "/future");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/future/SKILL.md",
        .data = "---\nname: future\ndescription: Future gate.\nscoot_version: \">=1.0.0\"\n---\n# Future\n",
    });
    try cwd.createDirPath(io, root ++ "/bad_tool");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/bad_tool/SKILL.md",
        .data = "---\nname: bad-tool\ndescription: Bad tool.\nallowed_tools: [telepathy]\n---\n# Bad\n",
    });
    try cwd.createDirPath(io, root ++ "/bad_capability");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/bad_capability/SKILL.md",
        .data = "---\nname: bad-cap\ndescription: Bad capability.\ncapabilities: [network]\n---\n# Bad\n",
    });
    try cwd.createDirPath(io, root ++ "/bad_scope");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/bad_scope/SKILL.md",
        .data = "---\nname: bad-scope\ndescription: Bad scope.\nscope: universal\n---\n# Bad\n",
    });

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const no_desc = try validateDir(arena.allocator(), io, root ++ "/no_desc");
    switch (no_desc) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expectEqualStrings("description is required", msg),
    }

    const bad_name = try validateDir(arena.allocator(), io, root ++ "/bad_name");
    switch (bad_name) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "name must") != null),
    }

    const future = try validateDir(arena.allocator(), io, root ++ "/future");
    switch (future) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "unsupported compatibility") != null),
    }

    const bad_tool = try validateDir(arena.allocator(), io, root ++ "/bad_tool");
    switch (bad_tool) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "unknown allowed_tools") != null),
    }

    const bad_capability = try validateDir(arena.allocator(), io, root ++ "/bad_capability");
    switch (bad_capability) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "unsupported capability") != null),
    }

    const bad_scope = try validateDir(arena.allocator(), io, root ++ "/bad_scope");
    switch (bad_scope) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "scope must") != null),
    }
}

test "validateDir: 缺 SKILL.md 给出明确失败" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const res = try validateDir(arena.allocator(), std.testing.io, "/tmp/scoot_skill_missing_xyz");
    switch (res) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expectEqualStrings("missing SKILL.md", msg),
    }
}

test {
    std.testing.refAllDecls(@This());
}
