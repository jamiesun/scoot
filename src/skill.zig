//! Skill 机制（用户明示「必须」的可扩展能力）：把"打包好的能力 + 指令集"
//! 以目录形式挂载给 Agent，让 Scoot 无需改代码即可获得专门领域的操作知识。
//!
//! 一个 Skill 就是一个目录：
//!   <skill>/
//!     SKILL.md       必需：YAML front-matter(name, description) + Markdown 正文指令
//!     scripts/       可选：脚本等资源（被调用时同样经统一 bash 沙盒，受策略门 + 硬超时约束）
//!     references/    可选：按需加载的参考资料
//!
//! 渐进式披露（服务「轻量化」铁律，避免上下文爆炸）：
//!   1) 发现：扫描各 skill 路径，**只解析 front-matter**（name+description）建轻量索引；
//!   2) 注入：把可用 skill 的 name+description+路径渲染成清单注入 system 上下文；
//!   3) 激活：模型判断某 skill 相关时，用既有 `bash` 工具读取其 SKILL.md 正文获取完整指令
//!      （正文绝不预先注入，故上下文恒定轻量）；
//!   4) 执行：skill 自带脚本经统一 bash 工具沙盒执行——**不给技能任何特权执行通道**，
//!      与普通命令一样先过执行护栏、再带硬超时运行（兑现「安全可控」铁律）。
//!
//! 设计取舍（反过载）：激活走「模型用 bash cat SKILL.md」而非新增专用 action，
//!   省掉了运行时动态 schema 与新分支，保持单体简洁；读取本身即被审计为 tool_call，
//!   可追溯性不打折。per-skill `allowed_tools` 工具白名单是预留格式字段——当前仅 bash
//!   一个工具，做白名单即过载设计；待 file/http/search 工具落地后再按需启用，届时由
//!   `allowsTool` 收口，现在不引入死字段。
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
};

/// front-matter 解析结果：借用源文本的切片，无分配（纯函数，便于防弹测试）。
pub const Meta = struct {
    name: []const u8,
    description: []const u8,
};

/// 解析 SKILL.md 的 YAML front-matter，仅提取 name / description。
/// 返回 null 表示「没有合法 front-matter 或缺 name」——该目录不是 skill，调用方应跳过。
/// 返回的切片借用 `src`，调用方需在使用期间保证 `src` 存活。
/// 防弹：任意非法/截断输入只会得到 null，绝不越界或 panic。
pub fn parseFrontMatter(src: []const u8) ?Meta {
    // 跳过开头空白与空行后，必须以独占一行的 "---" 开栅栏。
    const after_open = stripOpenFence(std.mem.trimStart(u8, src, " \t\r\n")) orelse return null;

    var name: []const u8 = "";
    var description: []const u8 = "";
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
        }
    }

    if (!closed) return null; // 缺闭合栅栏 = 畸形 front-matter，整体作废
    if (name.len == 0) return null; // 无名技能无法被模型选用，跳过
    return .{ .name = name, .description = description };
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
            const skill_dir = try std.fs.path.join(gpa, &.{ path, entry.name });
            errdefer gpa.free(skill_dir);
            try self.skills.append(gpa, .{ .name = name, .description = desc, .dir = skill_dir });
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
            \\当且仅当某技能与当前任务相关时，先用 action="bash" 读取它的 SKILL.md（如 `cat <路径>`）获取指令，再据此行动；
            \\技能脚本一律经普通命令沙盒执行（先过执行护栏、带硬超时）。无关时不要读取，保持上下文精简。
            \\
            \\
        );
        for (self.skills.items) |s| {
            try w.print("- {s}：{s}\n  指令文件：{s}/SKILL.md\n", .{ s.name, s.description, s.dir });
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
        \\allowed_tools: [bash, file]
        \\description: '比例 a:b 的部署助手'
        \\extra: 忽略我
        \\---
        \\body
    ;
    const m = parseFrontMatter(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("deploy", m.name);
    try std.testing.expectEqualStrings("比例 a:b 的部署助手", m.description);
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
    try std.testing.expect(std.mem.indexOf(u8, text, "/alpha/SKILL.md") != null);
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

test {
    std.testing.refAllDecls(@This());
}
