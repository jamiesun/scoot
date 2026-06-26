//! Session: one bounded interaction context, such as a REPL conversation, one
//! `-e` call, or a scheduled job run. It owns that interaction's message stream
//! across system/user/assistant/tool roles.
//!
//! Why it exists: each cognitive turn in agent.zig derives a per-turn arena and
//! releases it at turn end. Conversation history that survives across turns must
//! live in a longer-lived allocator, not the reset turn arena. Session is that
//! history carrier: appended content is copied into Session-owned allocation and
//! is independent of source arena lifetime.
//!
//! Two contexts, deliberately separated (issue #110):
//!   - Local execution context (this module): the durable record of what
//!     happened locally — tool observations, policy denials, and the full
//!     transcript persisted as JSONL for recall and audit replay. It is owned by
//!     scoot and never depends on any model-side storage mechanic.
//!   - Model context (llm.ModelContext): the transport-side view sent to the
//!     model plus opt-in response-storage/chaining state (`store`,
//!     `previous_response_id`). Scoot stays stateless by default and rebuilds the
//!     model's `input` from this local log every turn, so compaction stays local
//!     and token use stays bounded.
//!
//! Responsibility boundary:
//!   - Session handles short-term, single-session message records and optional
//!     persistence.
//!   - Cross-session long-term memory or semantic recall is intentionally not
//!     implemented here. Use skills for knowledge injection or plaintext
//!     summaries under state/ plus file tools, avoiding heavyweight vector DBs.
const std = @import("std");
const llm = @import("llm.zig");
const jsonio = @import("jsonio.zig");
const audit = @import("audit.zig");

pub const max_session_jsonl_bytes: usize = 10 * 1024 * 1024;
const jsonl_line_buffer_bytes: usize = (1 << 20) + 4096;

pub const Summary = struct {
    id: []const u8,
    mtime_ms: i64,
    message_count: usize,
    first_user_summary: []const u8,
};

pub const Loaded = struct {
    id: []const u8,
    messages: []llm.Message,
};

/// One session. `messages` is the active context sent to the model; `archive` is
/// the complete execution log for recall and persistence. Compaction only changes
/// `messages` and must not lose `archive`. Model-side response storage and
/// chaining state live separately in `llm.ModelContext`, never here.
pub const Session = struct {
    /// Session id, preferably timestamp or UUID, used in persistence filenames
    /// and logs. Memory is caller-owned and must outlive Session.
    id: []const u8,
    /// Active message stream; content is owned by `archive` or `active_only`.
    messages: std.ArrayList(llm.Message) = .empty,
    /// Complete message archive; append/appendMessage write and own originals.
    archive: std.ArrayList(llm.Message) = .empty,
    /// Synthetic messages present only in active context, such as compaction markers.
    active_only: std.ArrayList([]const u8) = .empty,

    pub fn init(id: []const u8) Session {
        return .{ .id = id };
    }

    /// Appends one message, copying `content` into `gpa` so source arena release
    /// cannot affect it.
    pub fn append(
        self: *Session,
        gpa: std.mem.Allocator,
        role: llm.Role,
        content: []const u8,
    ) !void {
        const owned = try gpa.dupe(u8, content);
        errdefer gpa.free(owned);
        const m: llm.Message = .{ .role = role, .content = owned };
        try self.messages.append(gpa, m);
        errdefer _ = self.messages.pop();
        try self.archive.append(gpa, m);
    }

    /// Convenience: appends an existing llm.Message, also copying content.
    pub fn appendMessage(self: *Session, gpa: std.mem.Allocator, m: llm.Message) !void {
        return self.append(gpa, m.role, m.content);
    }

    /// Read-only message view, ready for `llm.Client.chat`.
    pub fn items(self: *const Session) []const llm.Message {
        return self.messages.items;
    }

    /// Complete transcript view, still including messages folded out of active context.
    pub fn archiveItems(self: *const Session) []const llm.Message {
        return if (self.archive.items.len != 0) self.archive.items else self.messages.items;
    }

    pub fn count(self: *const Session) usize {
        return self.messages.items.len;
    }

    pub fn last(self: *const Session) ?llm.Message {
        const n = self.messages.items.len;
        return if (n == 0) null else self.messages.items[n - 1];
    }

    /// Records synthetic content that only belongs to active context.
    pub fn adoptActiveOnly(self: *Session, gpa: std.mem.Allocator, content: []const u8) !void {
        try self.active_only.append(gpa, content);
    }

    /// Frees message streams and content copies, using the same gpa as append.
    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        for (self.archive.items) |m| gpa.free(m.content);
        for (self.active_only.items) |content| gpa.free(content);
        self.messages.deinit(gpa);
        self.archive.deinit(gpa);
        self.active_only.deinit(gpa);
    }

    /// Writes the full session as JSONL, one message per line. Plaintext,
    /// appendable, and replayable.
    pub fn writeJsonl(self: *const Session, w: *std.Io.Writer) !void {
        try writeMessagesJsonl(w, self.archiveItems());
    }

    /// Appends the session to `<sessions_dir>/<id>.jsonl`, creating the file if
    /// needed. Serialization is handled by `writeJsonl`; this opens with Io,
    /// seeks to EOF, and writes. Append semantics let multiple snapshots of the
    /// same session accumulate over time for audit replay.
    pub fn persist(self: *const Session, io: std.Io, sessions_dir: []const u8) !void {
        var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&pathbuf, "{s}/{s}.jsonl", .{ sessions_dir, self.id });
        var rotate_buf: [std.fs.max_path_bytes + 2]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&rotate_buf);
        _ = audit.rotateFileIfTooLarge(io, fba.allocator(), path, audit.default_max_jsonl_bytes) catch false;

        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
        defer file.close(io);
        try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o600));

        const st = try file.stat(io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.seekTo(st.size); // Seek to EOF to append without overwriting.
        try self.writeJsonl(&fw.interface);
        try fw.interface.flush();
    }
};

pub fn list(arena: std.mem.Allocator, io: std.Io, sessions_dir: []const u8) ![]Summary {
    var summaries: std.ArrayList(Summary) = .empty;
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return summaries.items,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const is_file = switch (entry.kind) {
            .file => true,
            .unknown => blk: {
                const st = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch break :blk false;
                break :blk st.kind == .file;
            },
            else => false,
        };
        if (!is_file) continue;

        const id_part = entry.name[0 .. entry.name.len - ".jsonl".len];
        if (!isSafeSessionId(id_part)) continue;
        const full = try std.fs.path.join(arena, &.{ sessions_dir, entry.name });
        const st = cwd.statFile(io, full, .{}) catch continue;
        const summary = summarizeFile(arena, io, full, id_part, st.mtime.toMilliseconds()) catch continue;
        try summaries.append(arena, summary);
    }

    std.mem.sort(Summary, summaries.items, {}, summaryRecentFirst);
    return summaries.items;
}

pub fn loadById(arena: std.mem.Allocator, io: std.Io, sessions_dir: []const u8, id: []const u8) !Loaded {
    if (!isSafeSessionId(id)) return error.InvalidSessionId;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.jsonl", .{ sessions_dir, id });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_session_jsonl_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.SessionNotFound,
        else => return err,
    };

    var messages: std.ArrayList(llm.Message) = .empty;
    var it = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        try messages.append(arena, try parseMessageLine(arena, line));
    }

    return .{
        .id = try arena.dupe(u8, id),
        .messages = messages.items,
    };
}

pub fn writeMessagesJsonl(w: *std.Io.Writer, messages: []const llm.Message) !void {
    for (messages) |m| {
        try writeMessageJson(w, m);
        try w.writeByte('\n');
    }
}

/// Writes one message as a single-line JSON object.
fn writeMessageJson(w: *std.Io.Writer, m: llm.Message) !void {
    try w.writeAll("{\"role\":\"");
    try w.writeAll(@tagName(m.role));
    try w.writeAll("\",\"content\":");
    try jsonio.writeString(w, m.content);
    try w.writeByte('}');
}

fn summarizeFile(arena: std.mem.Allocator, io: std.Io, path: []const u8, id: []const u8, mtime_ms: i64) !Summary {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const buf = try arena.alloc(u8, jsonl_line_buffer_bytes);
    var fr = file.reader(io, buf);

    var count: usize = 0;
    var first_user_summary: []const u8 = "";
    while (try readJsonLine(&fr.interface)) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        const msg = try parseMessageLineView(arena, line);
        count += 1;
        if (first_user_summary.len == 0 and msg.role == .user) {
            first_user_summary = try summarizeContent(arena, msg.content);
        }
    }
    return .{
        .id = try arena.dupe(u8, id),
        .mtime_ms = mtime_ms,
        .message_count = count,
        .first_user_summary = first_user_summary,
    };
}

fn parseMessageLine(arena: std.mem.Allocator, line: []const u8) !llm.Message {
    const msg = try parseMessageLineView(arena, line);
    return .{
        .role = msg.role,
        .content = try arena.dupe(u8, msg.content),
    };
}

fn parseMessageLineView(arena: std.mem.Allocator, line: []const u8) !llm.Message {
    const Raw = struct {
        role: []const u8,
        content: []const u8,
    };
    const parsed = std.json.parseFromSlice(Raw, arena, line, .{ .ignore_unknown_fields = true }) catch return error.InvalidSessionLog;
    const role = std.meta.stringToEnum(llm.Role, parsed.value.role) orelse return error.InvalidSessionLog;
    return .{
        .role = role,
        .content = parsed.value.content,
    };
}

fn summarizeContent(arena: std.mem.Allocator, content: []const u8) ![]const u8 {
    const max_bytes = 120;
    var out: std.ArrayList(u8) = .empty;
    var last_space = false;
    for (content) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\r' or c == '\n';
        if (is_space) {
            if (out.items.len == 0 or last_space) continue;
            try out.append(arena, ' ');
            last_space = true;
        } else {
            try out.append(arena, c);
            last_space = false;
        }
        if (out.items.len >= max_bytes) {
            try out.appendSlice(arena, "...");
            break;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
    return out.items;
}

fn isSafeSessionId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    return std.mem.indexOfAny(u8, id, "/\\") == null;
}

fn readJsonLine(in: *std.Io.Reader) !?[]const u8 {
    const line = in.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => {
            const rest = in.take(in.bufferedLen()) catch return null;
            if (rest.len == 0) return null;
            return rest;
        },
        else => return err,
    };
    return std.mem.trimEnd(u8, line, "\r\n");
}

fn summaryRecentFirst(_: void, a: Summary, b: Summary) bool {
    if (a.mtime_ms == b.mtime_ms) return std.mem.lessThan(u8, a.id, b.id);
    return a.mtime_ms > b.mtime_ms;
}

test "append copies content independent of source buffer" {
    const gpa = std.testing.allocator;
    var s = Session.init("t1");
    defer s.deinit(gpa);

    var tmp = [_]u8{ 'h', 'i' };
    try s.append(gpa, .user, &tmp);
    tmp[0] = 'X'; // Mutating source buffer must not affect the stored copy.

    try std.testing.expectEqual(@as(usize, 1), s.count());
    try std.testing.expectEqualStrings("hi", s.items()[0].content);
    try std.testing.expectEqualStrings("hi", s.archiveItems()[0].content);
    try std.testing.expectEqual(llm.Role.user, s.last().?.role);
}

test "writeJsonl output parses with std.json and escaping" {
    const gpa = std.testing.allocator;
    var s = Session.init("t2");
    defer s.deinit(gpa);

    try s.append(gpa, .system, "you are \"scoot\"");
    try s.append(gpa, .user, "line1\nline2\t\x01");

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try s.writeJsonl(&w);

    const Line = struct { role: []const u8, content: []const u8 };
    const expect_roles = [_][]const u8{ "system", "user" };
    const expect_content = [_][]const u8{ "you are \"scoot\"", "line1\nline2\t\x01" };

    var it = std.mem.tokenizeScalar(u8, w.buffered(), '\n');
    var idx: usize = 0;
    while (it.next()) |line| : (idx += 1) {
        const parsed = try std.json.parseFromSlice(Line, gpa, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(expect_roles[idx], parsed.value.role);
        try std.testing.expectEqualStrings(expect_content[idx], parsed.value.content);
    }
    try std.testing.expectEqual(@as(usize, 2), idx);
}

test "persist appends JSONL to <dir>/<id>.jsonl and can read back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_session_persist_test";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    var s = Session.init("conv1");
    defer s.deinit(gpa);
    try s.append(gpa, .user, "hello\"world\"");
    try s.append(gpa, .assistant, "there");

    try s.persist(io, dir);
    try s.persist(io, dir); // Persist again; this must append rather than overwrite.

    const bytes = try cwd.readFileAlloc(io, dir ++ "/conv1.jsonl", gpa, .limited(1 << 16));
    defer gpa.free(bytes);

    var lines: usize = 0;
    var it = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (it.next()) |line| : (lines += 1) {
        const v = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        v.deinit(); // Every line should be valid JSON.
    }
    try std.testing.expectEqual(@as(usize, 4), lines); // 2 messages x 2 persists.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "hello") != null);

    const st = try cwd.statFile(io, dir ++ "/conv1.jsonl", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}

test "list and loadById read local session JSONL without server state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_session_read_model_test";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    try cwd.writeFile(io, .{
        .sub_path = dir ++ "/alpha.jsonl",
        .data =
        \\{"role":"system","content":"sys","ignored":true}
        \\{"role":"user","content":"hello\nworld"}
        \\{"role":"assistant","content":"done"}
        \\
        ,
    });
    try cwd.writeFile(io, .{
        .sub_path = dir ++ "/broken.jsonl",
        .data = "{not json}\n",
    });
    try cwd.writeFile(io, .{
        .sub_path = dir ++ "/not-a-session.txt",
        .data = "ignore\n",
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summaries = try list(arena, io, dir);
    try std.testing.expectEqual(@as(usize, 1), summaries.len);
    try std.testing.expectEqualStrings("alpha", summaries[0].id);
    try std.testing.expectEqual(@as(usize, 3), summaries[0].message_count);
    try std.testing.expectEqualStrings("hello world", summaries[0].first_user_summary);

    const loaded = try loadById(arena, io, dir, "alpha");
    try std.testing.expectEqualStrings("alpha", loaded.id);
    try std.testing.expectEqual(@as(usize, 3), loaded.messages.len);
    try std.testing.expectEqual(llm.Role.user, loaded.messages[1].role);
    try std.testing.expectEqualStrings("hello\nworld", loaded.messages[1].content);
    try std.testing.expectError(error.InvalidSessionId, loadById(arena, io, dir, "../alpha"));
    try std.testing.expectError(error.SessionNotFound, loadById(arena, io, dir, "missing"));
    try std.testing.expectError(error.InvalidSessionLog, loadById(arena, io, dir, "broken"));

    const empty = try list(arena, io, dir ++ "/missing");
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "context separation: execution log survives model-context compaction; transport state lives in llm.ModelContext" {
    const gpa = std.testing.allocator;
    var s = Session.init("sep1");
    defer s.deinit(gpa);

    try s.append(gpa, .system, "you are scoot");
    try s.append(gpa, .user, "goal: list files");
    try s.append(gpa, .assistant, "{\"tool\":\"shell\"}"); // a model step
    try s.append(gpa, .user, "observation: a.txt b.txt"); // an execution-context observation
    try std.testing.expectEqual(@as(usize, 4), s.count());

    // Emulate compaction: the active *model context* drops earlier turns, but the
    // *execution log* (archive) must retain the full transcript untouched.
    s.messages.shrinkRetainingCapacity(1); // keep only the leading system message
    const marker = try gpa.dupe(u8, "[compacted 3 messages]");
    try s.adoptActiveOnly(gpa, marker); // adopts a gpa-owned slice, freed in deinit

    try std.testing.expectEqual(@as(usize, 1), s.items().len); // model context shrank
    try std.testing.expectEqual(@as(usize, 4), s.archiveItems().len); // execution log intact
    // The tool observation is still in the execution log after compaction.
    try std.testing.expectEqualStrings("observation: a.txt b.txt", s.archiveItems()[3].content);

    // Model-side transport state (response storage / chaining) lives in
    // llm.ModelContext, never in Session: the two contexts are separate types and
    // scoot is stateless by default.
    const mc: llm.ModelContext = .{};
    try std.testing.expectEqual(false, mc.store);
    try std.testing.expectEqual(@as(?[]const u8, null), mc.previous_response_id);
    try std.testing.expectEqual(@as(usize, 0), mc.lastResponseId().len);
}

test {
    std.testing.refAllDecls(@This());
}
