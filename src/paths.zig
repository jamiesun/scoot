//! 运行目录解析：~/.scoot/ 作为 Scoot 的家目录与运行目录。
//! 解析优先级：CLI --scoot-home（由 main 处理）> 环境变量 SCOOT_HOME > $HOME/.scoot。
//! 本模块只做路径字符串解析；实际目录创建/读写走 Io（见 ensure）。
const std = @import("std");
const Environ = std.process.Environ;

pub const Paths = struct {
    /// 运行目录根（默认 ~/.scoot）。
    home: []const u8,
    /// 主配置文件：<home>/config.json
    config_file: []const u8,
    /// TOML 配置文件：<home>/config.toml（优先于 config.json）
    config_toml_file: []const u8,
    /// 默认 token 文件：<home>/token（要求 0600）
    token_file: []const u8,
    /// 用户级 skill 目录：<home>/skills
    skills_dir: []const u8,
    /// 跨 agent 用户级技能目录：$HOME/.agents/skills（独立于 SCOOT_HOME）。
    /// 无法确定 $HOME 时为 null。仅 `resolve` 填充；`fromHome`（显式 home / 测试）置 null。
    agents_skills_dir: ?[]const u8 = null,
    /// 审计 / 运行日志目录：<home>/logs
    logs_dir: []const u8,
    /// 本地状态目录（调度任务、会话等）：<home>/state
    state_dir: []const u8,
    /// 会话落盘目录：<home>/state/sessions
    sessions_dir: []const u8,

    /// 解析运行目录。所有字符串由 `arena` 拥有（进程级生命周期即可）。
    pub fn resolve(arena: std.mem.Allocator, env: *const Environ.Map) !Paths {
        // 真实 $HOME 与 SCOOT_HOME 解耦：跨 agent 的 ~/.agents/skills 始终相对真实家目录，
        // 即便用户用 SCOOT_HOME 把 Scoot 运行目录搬到别处也不受影响。
        const user_home = env.get("HOME");
        const home = env.get("SCOOT_HOME") orelse blk: {
            const h = user_home orelse return error.NoHomeDir;
            break :blk try std.fs.path.join(arena, &.{ h, ".scoot" });
        };
        var p = try fromHome(arena, home);
        if (user_home) |h|
            p.agents_skills_dir = try std.fs.path.join(arena, &.{ h, ".agents", "skills" });
        return p;
    }

    /// 从显式 home 目录派生完整运行目录树。供 CLI override 与测试共用。
    pub fn fromHome(arena: std.mem.Allocator, home: []const u8) !Paths {
        const state_dir = try std.fs.path.join(arena, &.{ home, "state" });
        return .{
            .home = home,
            .config_file = try std.fs.path.join(arena, &.{ home, "config.json" }),
            .config_toml_file = try std.fs.path.join(arena, &.{ home, "config.toml" }),
            .token_file = try std.fs.path.join(arena, &.{ home, "token" }),
            .skills_dir = try std.fs.path.join(arena, &.{ home, "skills" }),
            .logs_dir = try std.fs.path.join(arena, &.{ home, "logs" }),
            .state_dir = state_dir,
            .sessions_dir = try std.fs.path.join(arena, &.{ state_dir, "sessions" }),
        };
    }

    /// 确保运行目录及子目录存在（幂等：已存在不报错），并收紧为属主可读写执行。
    /// session transcript / audit 日志可能含提示词、模型输出和文件内容；目录不应继承
    /// 默认 umask 变成同机用户可读。
    pub fn ensure(self: Paths, io: std.Io) !void {
        try ensurePrivateDir(io, self.home);
        try ensurePrivateDir(io, self.skills_dir);
        try ensurePrivateDir(io, self.logs_dir);
        try ensurePrivateDir(io, self.state_dir);
        try ensurePrivateDir(io, self.sessions_dir);
    }
};

fn ensurePrivateDir(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, path, std.Io.File.Permissions.fromMode(0o700));
    try cwd.setFilePermissions(io, path, std.Io.File.Permissions.fromMode(0o700), .{});
}

/// `child` 是否位于 `parent` 之内（含相等）。两者应为已规范化（realpath）的绝对路径。
/// 纯字符串判定，供各模块的 symlink 逃逸防护复用（issue #41 / #52 / #54）。
/// 用 sep 边界判定避免 `/a/bc` 误判为落在 `/a/b` 内的前缀混淆。
pub fn within(child: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    return child[parent.len] == std.fs.path.sep;
}

/// symlink 逃逸防护（读取面，#41 技能读取 / #54 wasm 校验）：把 `dir` 与**已存在**的 `full`
/// 都经 realpath 规范化，判断 full 是否逃逸出 dir。任一 realpath 失败（目标不存在 / 平台不支持）
/// → 返回 false（无法确证逃逸；调用方后续的打开/读取会自然失败，不存在的目标也无内容可泄露）。
pub fn realPathEscapes(io: std.Io, arena: std.mem.Allocator, dir: []const u8, full: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const real_dir = cwd.realPathFileAlloc(io, dir, arena) catch return false;
    const real_full = cwd.realPathFileAlloc(io, full, arena) catch return false;
    return !within(real_full, real_dir);
}

/// symlink 逃逸防护（写入面，#52，与 #41 读取面对齐）：写入目标 `target`（相对路径，可能尚不
/// 存在）的**父目录**经 realpath 规范化后，须仍落在 `base`（项目根）内。词法检查（禁绝对 / `..`）
/// 只是前置过滤，写入会跟随 symlink；父目录是写入实际落点，对其 realpath 即可挡住 `link -> /etc`
/// 这类预置 symlink 逃逸。父目录不存在 → realpath 失败 → false（写入自会失败，不构成逃逸）。
pub fn writeEscapesBase(io: std.Io, arena: std.mem.Allocator, base: []const u8, target: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const real_base = cwd.realPathFileAlloc(io, base, arena) catch return false;
    const parent_rel = std.fs.path.dirname(target) orelse ".";
    const parent_path = std.fs.path.join(arena, &.{ base, parent_rel }) catch return false;
    const real_parent = cwd.realPathFileAlloc(io, parent_path, arena) catch return false;
    if (!within(real_parent, real_base)) return true;

    const target_path = std.fs.path.join(arena, &.{ base, target }) catch return false;
    const lst = cwd.statFile(io, target_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return false,
    };
    if (lst.kind == .sym_link) return true;

    const real_target = cwd.realPathFileAlloc(io, target_path, arena) catch return false;
    return !within(real_target, real_base);
}

test {
    std.testing.refAllDecls(@This());
}

test "within: sep 边界判定，挡住前缀混淆" {
    try std.testing.expect(within("/a/b", "/a/b"));
    try std.testing.expect(within("/a/b/c", "/a/b"));
    try std.testing.expect(!within("/a/bc", "/a/b"));
    try std.testing.expect(!within("/a", "/a/b"));
}

test "realPathEscapes: 技能/包目录内 symlink 逃逸判定（issue #41/#54）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_realpath_escapes_test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/pkg");
    try cwd.createDirPath(io, root ++ "/outside");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/pkg/in.txt", .data = "IN" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/outside/secret.txt", .data = "OUT" });
    cwd.symLink(io, root ++ "/outside/secret.txt", root ++ "/pkg/leak", .{}) catch |e| {
        if (e == error.AccessDenied or e == error.PermissionDenied) return error.SkipZigTest;
        return e;
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(realPathEscapes(io, arena, root ++ "/pkg", root ++ "/pkg/leak"));
    try std.testing.expect(!realPathEscapes(io, arena, root ++ "/pkg", root ++ "/pkg/in.txt"));
    // 不存在的目标：无法确证逃逸 → false（交由后续读取自然失败）。
    try std.testing.expect(!realPathEscapes(io, arena, root ++ "/pkg", root ++ "/pkg/missing"));
}

test "writeEscapesBase: 预置 symlink 的写入逃逸判定（issue #52）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_write_escapes_test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/proj/sub");
    try cwd.createDirPath(io, root ++ "/outside");
    cwd.symLink(io, root ++ "/outside", root ++ "/proj/link", .{}) catch |e| {
        if (e == error.AccessDenied or e == error.PermissionDenied) return error.SkipZigTest;
        return e;
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = root ++ "/proj";
    // 项目内合法写入：父目录在 base 内 → 不逃逸。
    try std.testing.expect(!writeEscapesBase(io, arena, base, "sub/file.txt"));
    try std.testing.expect(!writeEscapesBase(io, arena, base, "file.txt"));
    // 经预置 symlink 写到项目外：父目录 realpath 落在 outside → 逃逸。
    try std.testing.expect(writeEscapesBase(io, arena, base, "link/escape.txt"));
}

test "writeEscapesBase: final path component symlink is rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_write_final_symlink_test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/proj/sub");
    try cwd.createDirPath(io, root ++ "/outside");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/outside/target.txt", .data = "OUT" });
    cwd.symLink(io, root ++ "/outside/target.txt", root ++ "/proj/sub/out", .{}) catch |e| {
        if (e == error.AccessDenied or e == error.PermissionDenied) return error.SkipZigTest;
        return e;
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(writeEscapesBase(io, arena, root ++ "/proj", "sub/out"));
    try std.testing.expect(!writeEscapesBase(io, arena, root ++ "/proj", "sub/new.txt"));
}

test "fromHome: 从显式 home 派生运行目录树" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try Paths.fromHome(arena_state.allocator(), "/tmp/scoot_explicit_home");

    try std.testing.expectEqualStrings("/tmp/scoot_explicit_home", p.home);
    try std.testing.expectEqualStrings("/tmp/scoot_explicit_home/config.toml", p.config_toml_file);
    try std.testing.expectEqualStrings("/tmp/scoot_explicit_home/logs", p.logs_dir);
    try std.testing.expectEqualStrings("/tmp/scoot_explicit_home/state/sessions", p.sessions_dir);
}

test "ensure: 在临时目录下创建运行目录树且幂等" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const home = "/tmp/scoot_paths_test";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    const p: Paths = .{
        .home = home,
        .config_file = home ++ "/config.json",
        .config_toml_file = home ++ "/config.toml",
        .token_file = home ++ "/token",
        .skills_dir = home ++ "/skills",
        .logs_dir = home ++ "/logs",
        .state_dir = home ++ "/state",
        .sessions_dir = home ++ "/state/sessions",
    };
    try p.ensure(io); // 首次创建
    try p.ensure(io); // 再次调用必须幂等、不报错

    // 子目录应可被再次以目录方式打开（存在性验证）。
    var d = try cwd.openDir(io, p.sessions_dir, .{});
    d.close(io);

    const st = try cwd.statFile(io, p.sessions_dir, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), st.permissions.toMode() & 0o777);
}
