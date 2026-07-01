//! Standalone scoot-edge companion binary.
//!
//! E1 posture: optional report-only messenger. This file intentionally does not
//! import `src/internal.zig` and does not link into the core `scoot` executable.
//! It drives Scoot only through public process interfaces such as
//! `scoot daemon status --json`.
//!
//! E1 capabilities: one-shot `status` / `post-once`, plus a continuous `run`
//! heartbeat loop (periodic dial-out POST with bounded jittered backoff) and an
//! opt-in, advisory `node` capability descriptor for capability-aware routing.
//! The loop never opens a listener, only ever reports up, and shuts down cleanly
//! (exit 0) on SIGINT/SIGTERM so it is a well-behaved systemd/launchd service.
//!
//! E2 capabilities (issue #186): one-shot `dispatch`, plus `run --enable-jobs`,
//! poll `GET <lease-url>?node=<id>&capacity=<N>` for 0..N NDJSON `job`
//! envelopes and execute `kind=run` jobs by launching
//! `scoot --unattended -e "<goal>"` with cwd pinned to `--job-root` (never the
//! host root or `$HOME`). `goal` is always opaque data handed to `scoot -e`;
//! this file never synthesizes shell or `eval` from it. Policy can only ever be
//! *lowered* by the in-child unattended clamp (`edge.max_job_policy`, enforced
//! by core against local config) — the edge never raises it and does not
//! itself decide the ceiling. Each job's outcome is recorded in a bounded,
//! persistent idempotency store (so a redelivered `idem_key` re-acks instead of
//! re-running) and in an append-only `logs/edge-audit.jsonl` provenance trail,
//! then reported back as a `job_event` over the same telemetry channel as the
//! `status` heartbeat.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const proc = @import("tools/proc.zig");
const paths = @import("paths.zig");

const usage =
    \\scoot-edge - optional Scoot fleet messenger (E1 status, E2 job dispatch)
    \\
    \\Usage:
    \\  scoot-edge status [options]      print one status heartbeat envelope as NDJSON
    \\  scoot-edge post-once [options]   POST one status heartbeat to an HTTPS endpoint
    \\  scoot-edge run [options]         POST a status heartbeat on a fixed interval until stopped
    \\  scoot-edge dispatch [options]    poll the job lease once, execute 0..N jobs, report job_events
    \\
    \\Options:
    \\  --node-id <id>          stable node id (default: hostname when available, else "local")
    \\  --scoot-bin <path>      scoot executable to launch (default: scoot)
    \\  --scoot-home <dir>      pass --scoot-home to the child scoot process; also where scoot-edge
    \\                          keeps its own edge/ idempotency store and logs/edge-audit.jsonl
    \\  --center-url <https>    exact HTTPS telemetry endpoint for post-once/run/dispatch job_events
    \\  --token-env <name>      env var containing the per-node bearer token (default: SCOOT_EDGE_TOKEN)
    \\  --timeout-ms <N>        hard timeout for each child/network operation (default: 30000)
    \\  --interval-ms <N>       run: delay between heartbeats (default: 60000)
    \\  --max-posts <N>         run: stop after N successful heartbeats (default: 0 = unlimited)
    \\  --report-capabilities   attach an advisory node capability descriptor to the heartbeat (default: off)
    \\  --label <k:v>           operator routing label for the node descriptor (repeatable; also SCOOT_EDGE_LABELS)
    \\  --skill <name>          advertised skill name for the node descriptor (repeatable; also SCOOT_EDGE_SKILLS)
    \\  --allow-insecure-http   allow http:// loopback center URLs for local/dev testing only
    \\  --job-root <dir>        REQUIRED for dispatch: cwd confinement directory for launched jobs (never $HOME or /)
    \\  --lease-url <https>     REQUIRED for dispatch: exact HTTPS GET endpoint for job leasing (e.g. https://center/jobs/lease)
    \\  --lease-capacity <N>    max jobs to accept per lease poll (default: 1)
    \\  --idem-cap <N>          bounded idempotency store size before oldest entries are evicted (default: 500)
    \\  --enable-jobs           run: also poll --lease-url and execute jobs each iteration (requires --job-root/--lease-url)
    \\  -h, --help             show this help
    \\  -v, --version          show version
    \\
    \\No outbound network happens in `status`; `post-once`, `run`, and `dispatch` require HTTPS and a
    \\non-empty token unless --allow-insecure-http is explicitly set for local/dev loopback testing.
    \\`run` dials out only — it never opens a listener — and reports up only. It shuts down
    \\cleanly (exit 0) on SIGINT/SIGTERM, finishing the in-flight heartbeat first, so a supervisor
    \\(systemd/launchd) stop is graceful rather than a hard kill.
    \\
    \\`dispatch` treats each job's `goal` as opaque data handed to `scoot --unattended -e`; it never
    \\synthesizes shell or eval from it. Policy can only ever be lowered by the in-child unattended
    \\clamp against local `edge.max_job_policy` — dispatch does not itself decide or raise policy.
    \\A redelivered `idem_key` re-acks the stored outcome instead of re-running the job.
    \\
    \\Exit codes:
    \\  0  success (or a clean SIGINT/SIGTERM shutdown of `run`)
    \\  1  dial-out POST failed in post-once (network error, timeout, or non-2xx)
    \\  2  configuration/usage error (bad flag, or missing/invalid --center-url or token)
    \\  3  could not collect local status (the `scoot daemon status --json` child failed)
    \\
;

const Command = enum { status, post_once, run, dispatch };

const default_timeout_ms: u64 = 30_000;
const default_interval_ms: u64 = 60_000;
/// Upper bound for transient-failure backoff so a long outage cannot push the
/// retry delay arbitrarily high.
const max_backoff_ms: u64 = 900_000;
/// Lower bound for transient-failure backoff. The steady-state interval is the
/// backoff base, so a tiny (or `0`-normalized) interval must not collapse the
/// retry delay to a busy-spin that hammers the center while it is down.
const min_backoff_ms: u64 = 1_000;
/// The center-dispatched job ceiling reported by the heartbeat. E2 job dispatch
/// (and any local `edge.max_job_policy` knob) does not exist yet, so this is the
/// documented default; advertising it never grants authority.
const default_max_job_policy = "readonly";
/// Default cap on jobs accepted from a single lease response (`--lease-capacity`).
const default_lease_capacity: u32 = 1;
/// Default bound on the persistent idempotency store before oldest entries are
/// evicted (`--idem-cap`). Bounded so an unattended fleet node cannot grow this
/// file without limit; unlike audit retention (#187) an evicted idempotency
/// record has no safety promise attached — worst case a very old redelivery
/// re-runs once more instead of re-acking, which is an at-least-once-safe
/// outcome, not a silent loss.
const default_idem_cap: u32 = 500;

/// Stable process exit codes, documented in `usage` and EDGE.md so supervisors
/// and scripts can branch on them. `0` is success (including a clean `run`
/// shutdown on SIGINT/SIGTERM).
const exit_post_failed: u8 = 1;
const exit_config_error: u8 = 2;
const exit_collect_failed: u8 = 3;

/// Advisory, readonly-aligned built-in actions a node declares it is "for". This
/// is routing metadata only; the local policy ceiling still gates every job.
const advisory_readonly_tools = [_][]const u8{ "file_read", "grep", "glob", "outline", "http_request" };

const Options = struct {
    command: Command = .status,
    node_id: ?[]const u8 = null,
    scoot_bin: []const u8 = "scoot",
    scoot_home: ?[]const u8 = null,
    center_url: ?[]const u8 = null,
    token_env: []const u8 = "SCOOT_EDGE_TOKEN",
    timeout_ms: u64 = default_timeout_ms,
    interval_ms: u64 = default_interval_ms,
    max_posts: u64 = 0,
    report_capabilities: bool = false,
    labels: []const []const u8 = &.{},
    skills: []const []const u8 = &.{},
    allow_insecure_http: bool = false,
    job_root: ?[]const u8 = null,
    lease_url: ?[]const u8 = null,
    lease_capacity: u32 = default_lease_capacity,
    idem_cap: u32 = default_idem_cap,
    enable_jobs: bool = false,
};

const DaemonSummary = struct {
    state: []const u8,
    clean_prev_stop: bool,
    since: ?i64,
};

const AuditStats = struct {
    run: usize = 0,
    tool_call: usize = 0,
    policy_deny: usize = 0,
    system_error: usize = 0,
};

const NodeCapabilities = struct {
    max_job_policy: []const u8,
    tools: []const []const u8,
    skills: []const []const u8,
};

/// Opt-in, advisory node identity/capability descriptor (`--report-capabilities`).
/// Declarative routing metadata only — advertising a capability never widens what
/// the edge will execute; the local policy ceiling still gates every job.
const NodeDescriptor = struct {
    labels: []const []const u8,
    os: []const u8,
    arch: []const u8,
    capabilities: NodeCapabilities,
};

const StatusBody = struct {
    scoot_version: []const u8,
    edge_version: []const u8,
    daemon: DaemonSummary,
    policy_ceiling: []const u8 = "readonly",
    audit_stats: AuditStats = .{},
    node: ?NodeDescriptor = null,
};

const StatusEnvelope = struct {
    v: u32 = 1,
    type: []const u8 = "status",
    node_id: []const u8,
    sent_ts: i64,
    body: StatusBody,
};

const StatePartial = struct {
    status: []const u8 = "unknown",
    started_at_unix: i64 = 0,
    updated_at_unix: i64 = 0,
    stopped_at_unix: ?i64 = null,
};

const DaemonStatusPartial = struct {
    state: ?StatePartial = null,
    liveness: []const u8 = "unknown",
};

const ChildOutput = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    timed_out: bool = false,
};

const FetchResult = struct {
    status: u16 = 0,
    body: []const u8 = "",
    timed_out: bool = false,
    err: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// E2 job dispatch (issue #186): wire schema, validation, execution, and the
// bounded/persistent idempotency + provenance stores.
// ---------------------------------------------------------------------------

/// Wire body of a `job` envelope from `GET <lease-url>`. `kind` is a closed
/// enum (currently only `"run"` is accepted); `goal` is always opaque data
/// handed verbatim to `scoot --unattended -e`, never interpreted or expanded
/// here. Required string fields have no default so a missing field is a JSON
/// parse failure, which `leaseJobs` maps to a `bad_schema` reject.
const JobBody = struct {
    job_id: []const u8,
    idem_key: []const u8,
    kind: []const u8,
    goal: []const u8,
    requested_policy: ?[]const u8 = null,
    deadline_ts: ?i64 = null,
    max_retries: u32 = 0,
};

const JobEnvelope = struct {
    v: u32 = 1,
    type: []const u8 = "job",
    node_id: []const u8 = "",
    sent_ts: i64 = 0,
    body: JobBody,
};

/// Lifecycle phase reported in a `job_event` (docs/EDGE.md E2 section).
const JobPhase = enum {
    accepted,
    running,
    done,
    failed,
    rejected,

    fn asString(self: JobPhase) []const u8 {
        return switch (self) {
            .accepted => "accepted",
            .running => "running",
            .done => "done",
            .failed => "failed",
            .rejected => "rejected",
        };
    }
};

/// Reasons `scoot-edge` itself can reject a job at intake. The documented wire
/// contract also lists `policy_ceiling` and `no_matching_capability`, but
/// neither is ever produced from this codebase: policy is always silently
/// *lowered* by the in-child unattended clamp rather than hard-rejected (so a
/// bad/unrecognized `requested_policy` string is a schema violation, folded
/// into `bad_schema`, not a `policy_ceiling` reject), and capability matching
/// is a center-side decision made before a job is ever sent (docs/EDGE.md: "the
/// edge does not negotiate capabilities on the wire") — a job reaching this
/// node is assumed pre-matched.
const RejectReason = enum {
    bad_schema,
    at_capacity,

    fn asString(self: RejectReason) []const u8 {
        return switch (self) {
            .bad_schema => "bad_schema",
            .at_capacity => "at_capacity",
        };
    }
};

const JobEventBody = struct {
    job_id: []const u8,
    phase: []const u8,
    session_id: ?[]const u8 = null,
    effective_policy: ?[]const u8 = null,
    reject_reason: ?[]const u8 = null,
};

const JobEventEnvelope = struct {
    v: u32 = 1,
    type: []const u8 = "job_event",
    node_id: []const u8,
    sent_ts: i64,
    body: JobEventBody,
};

/// One durable outcome record, keyed by `idem_key`, in the bounded idempotency
/// store (`<scoot-home>/edge/idem.jsonl`). Only *final* outcomes (`done`,
/// `failed`, `rejected`) are ever recorded; `accepted`/`running` are transient
/// and never redelivery-cacheable.
const IdemRecord = struct {
    idem_key: []const u8,
    job_id: []const u8,
    phase: []const u8,
    session_id: ?[]const u8 = null,
    effective_policy: ?[]const u8 = null,
    reject_reason: ?[]const u8 = null,
    ts: i64 = 0,
};

/// One append-only provenance line in `<scoot-home>/logs/edge-audit.jsonl`
/// (docs/EDGE.md "Full provenance" rule). Joinable to Scoot core's own
/// `logs/audit.jsonl` via `session_id`. A superset of `JobEventBody` (adds
/// `ts`, `node_id`, and `idem_key`) so the local record stands alone even if
/// the matching wire `job_event` POST never reached the center.
const ProvenanceRecord = struct {
    ts: i64,
    node_id: []const u8,
    job_id: []const u8,
    idem_key: []const u8,
    phase: []const u8,
    session_id: ?[]const u8 = null,
    effective_policy: ?[]const u8 = null,
    reject_reason: ?[]const u8 = null,
};

/// Tally returned by one dispatch cycle, used only for the human-readable
/// summary line printed by `dispatch` / `run --enable-jobs`; never sent over
/// the wire.
const DispatchSummary = struct {
    accepted: u32 = 0,
    done: u32 = 0,
    failed: u32 = 0,
    rejected: u32 = 0,
    replayed: u32 = 0,
};

/// Mirrors `isSafeSessionId` in `src/main.zig` (issue #186): both guard the
/// same file-path/log-injection surface (session ids, and here also the
/// `job_id`/`idem_key` that flow into the edge-audit and idempotency JSONL
/// records and into the child's `--session-id`). Intentionally duplicated
/// rather than shared, since this file must not import core
/// `src/internal.zig` or link into the main `scoot` executable.
fn isSafeIdentifier(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return std.mem.indexOf(u8, id, "..") == null;
}

/// Whether `s` is one of the three real policy mode names. `scoot-edge` never
/// computes the clamp itself (that happens in-child against local config), so
/// this exists only to reject a malformed/unrecognized `requested_policy`
/// string at intake as `bad_schema`, rather than silently forwarding garbage
/// to the child (core's own `Mode.fromString` is total and would just
/// downgrade an unrecognized string to `guarded`, but a job whose request
/// cannot even be parsed here should never look like a normal accepted job).
fn isKnownPolicyModeName(s: []const u8) bool {
    return std.mem.eql(u8, s, "guarded") or std.mem.eql(u8, s, "readonly") or std.mem.eql(u8, s, "unrestricted");
}

/// Validates a parsed job envelope against the closed wire contract. Returns
/// `null` when the job is acceptable, or the specific reason it must be
/// rejected without ever reaching execution.
fn validateJobEnvelope(env: JobEnvelope) ?RejectReason {
    if (env.v != 1 or !std.mem.eql(u8, env.type, "job")) return .bad_schema;
    if (!std.mem.eql(u8, env.body.kind, "run")) return .bad_schema;
    if (!isSafeIdentifier(env.body.job_id)) return .bad_schema;
    if (!isSafeIdentifier(env.body.idem_key)) return .bad_schema;
    if (env.body.goal.len == 0) return .bad_schema;
    if (env.body.requested_policy) |p| {
        if (!isKnownPolicyModeName(p)) return .bad_schema;
    }
    return null;
}

/// Parses a `GET <lease-url>` NDJSON response body into 0..N job envelopes.
/// Each line is parsed independently; a line that fails to parse becomes a
/// synthetic envelope carrying an empty `job_id` (so it safely fails
/// `validateJobEnvelope`'s identifier check and is reported as `bad_schema`)
/// rather than aborting the whole batch.
fn parseLeaseBody(arena: std.mem.Allocator, body: []const u8) ![]JobEnvelope {
    var list: std.ArrayList(JobEnvelope) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(JobEnvelope, arena, line, .{
            .ignore_unknown_fields = true,
        }) catch JobEnvelope{ .body = .{ .job_id = "", .idem_key = "", .kind = "", .goal = "" } };
        try list.append(arena, parsed);
    }
    return list.items;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err_out = &stderr_writer.interface;
    defer err_out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(arena, out, args) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };

    switch (opts.command) {
        .status => {
            const envelope = try collectOrDie(arena, io, env, opts, err_out);
            try out.writeAll(try stringifyEnvelope(arena, envelope));
        },
        .post_once => {
            const ca = try requireCenterAndToken(err_out, env, opts);
            const envelope = try collectOrDie(arena, io, env, opts, err_out);
            const payload = try stringifyEnvelope(arena, envelope);
            const res = try postJson(arena, io, ca.url, ca.token, payload, opts.timeout_ms);
            if (res.timed_out) {
                try err_out.writeAll("error: telemetry POST timed out\n");
                die(err_out, exit_post_failed);
            }
            if (res.err) |e| {
                try err_out.print("error: telemetry POST failed: {s}\n", .{e});
                die(err_out, exit_post_failed);
            }
            if (res.status < 200 or res.status >= 300) {
                try err_out.print("error: telemetry POST returned HTTP {d}\n", .{res.status});
                die(err_out, exit_post_failed);
            }
            try out.print("posted status node_id={s} status={d}\n", .{ envelope.node_id, res.status });
        },
        .run => try runLoop(io, env, opts, out, err_out),
        .dispatch => try dispatchOnce(arena, io, env, opts, out, err_out),
    }
}

/// Required HTTPS endpoint plus bearer token for any dial-out command. Exits with
/// code 2 (a configuration error) when either is missing or insecure.
const CenterAuth = struct { url: []const u8, token: []const u8 };

fn requireCenterAndToken(
    err_out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    opts: Options,
) !CenterAuth {
    const center_url = opts.center_url orelse {
        try err_out.writeAll("error: this command requires --center-url <https://...>\n");
        die(err_out, exit_config_error);
    };
    if (!centerUrlAllowed(center_url, opts.allow_insecure_http)) {
        try err_out.writeAll("error: --center-url must use https://; http:// is allowed only with --allow-insecure-http for local/dev loopback testing\n");
        die(err_out, exit_config_error);
    }
    const token = env.get(opts.token_env) orelse {
        try err_out.print("error: token env var {s} is not set or empty\n", .{opts.token_env});
        die(err_out, exit_config_error);
    };
    if (token.len == 0) {
        try err_out.print("error: token env var {s} is not set or empty\n", .{opts.token_env});
        die(err_out, exit_config_error);
    }
    return .{ .url = center_url, .token = token };
}

/// Required job-dispatch configuration: a confinement `--job-root` and a
/// `--lease-url` (validated the same as `--center-url`: HTTPS, or insecure
/// loopback only with `--allow-insecure-http`). Exits with code 2 when either
/// is missing or the lease URL is insecure. `--job-root` is fail-closed by
/// design (docs/EDGE.md: "never the host root or $HOME") — there is no
/// default, since guessing one could silently confine jobs somewhere the
/// operator never chose.
const JobDispatchConfig = struct { job_root: []const u8, lease_url: []const u8 };

fn requireJobDispatchConfig(err_out: *std.Io.Writer, opts: Options) !JobDispatchConfig {
    const job_root = opts.job_root orelse {
        try err_out.writeAll("error: job dispatch requires --job-root <dir> (cwd confinement; never $HOME or /)\n");
        die(err_out, exit_config_error);
    };
    if (job_root.len == 0) {
        try err_out.writeAll("error: --job-root must not be empty\n");
        die(err_out, exit_config_error);
    }
    const lease_url = opts.lease_url orelse {
        try err_out.writeAll("error: job dispatch requires --lease-url <https://...>\n");
        die(err_out, exit_config_error);
    };
    if (!centerUrlAllowed(lease_url, opts.allow_insecure_http)) {
        try err_out.writeAll("error: --lease-url must use https://; http:// is allowed only with --allow-insecure-http for local/dev loopback testing\n");
        die(err_out, exit_config_error);
    }
    if (opts.lease_capacity == 0) {
        try err_out.writeAll("error: --lease-capacity must be at least 1\n");
        die(err_out, exit_config_error);
    }
    return .{ .job_root = job_root, .lease_url = lease_url };
}

/// Resolves the scoot-edge bookkeeping home directory: `--scoot-home` if given
/// (mirroring what is passed to the child `scoot` process so both sides agree
/// on the runtime tree), else the same `SCOOT_HOME` / `$HOME/.scoot` fallback
/// core `scoot` itself uses (`src/paths.zig`), so a bare invocation without
/// `--scoot-home` still lands in the same place the child would resolve on its
/// own.
fn resolveEdgeHome(arena: std.mem.Allocator, env: *const std.process.Environ.Map, opts: Options) ![]const u8 {
    if (opts.scoot_home) |home| return home;
    const p = try paths.Paths.resolve(arena, env);
    return p.home;
}

// ---------------------------------------------------------------------------
// E2 bookkeeping storage: the bounded idempotency store and the append-only
// provenance log. Both are small, dependency-free JSONL helpers written
// locally rather than imported from `src/audit.zig`, preserving this file's
// decoupling from core (see the top-of-file doc comment and the
// `isSafeIdentifier` precedent above).
// ---------------------------------------------------------------------------

/// Creates `path` if needed and tightens it to owner-only permissions,
/// mirroring `src/paths.zig`'s private `ensurePrivateDir` (duplicated rather
/// than imported for the same decoupling reason as `isSafeIdentifier`). The
/// idempotency store and provenance log can carry job goals, session ids, and
/// effective policy, so they get the same 0700 treatment as core's own
/// sessions/logs directories.
fn ensurePrivateDir(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, path, std.Io.File.Permissions.fromMode(0o700));
    try cwd.setFilePermissions(io, path, std.Io.File.Permissions.fromMode(0o700), .{});
}

/// Reads one JSONL line, tolerating a final line with no trailing newline.
/// Mirrors `src/audit.zig`'s private `readJsonLine` exactly (same rationale:
/// no cross-file import).
fn readOneJsonLine(in: *std.Io.Reader) !?[]const u8 {
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

/// Reads every parseable JSONL record of type `T` from `path`, in file order.
/// A missing file returns an empty slice (the common startup case, no store
/// written yet); a line that fails to parse (partial write torn by a crash
/// mid-append, hand-edited file) is skipped rather than aborting the whole
/// load, consistent with `src/audit.zig`'s JSONL tolerance.
fn readJsonLines(comptime T: type, arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]T {
    const cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer file.close(io);
    const buf = try arena.alloc(u8, 64 * 1024);
    var fr = file.reader(io, buf);

    var list: std.ArrayList(T) = .empty;
    while (try readOneJsonLine(&fr.interface)) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(T, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        try list.append(arena, v);
    }
    return list.items;
}

/// Appends one already-serialized JSON line (no trailing `\n` expected) to
/// `path`, creating the file if needed. Mirrors `src/audit.zig`'s
/// `appendGapRecord` open/seek-to-end/write/flush sequence.
fn appendJsonLine(io: std.Io, path: []const u8, json_line: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const f = try cwd.createFile(io, path, .{ .truncate = false });
    defer f.close(io);
    const st = try f.stat(io);
    var buf: [256]u8 = undefined;
    var fw = f.writer(io, &buf);
    try fw.seekTo(st.size);
    try fw.interface.writeAll(json_line);
    try fw.interface.writeAll("\n");
    try fw.interface.flush();
}

fn idemStorePath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "edge", "idem.jsonl" });
}

fn edgeAuditLogPath(arena: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "logs", "edge-audit.jsonl" });
}

fn loadIdemStore(arena: std.mem.Allocator, io: std.Io, home: []const u8) ![]IdemRecord {
    return readJsonLines(IdemRecord, arena, io, try idemStorePath(arena, home));
}

/// Finds the most recently recorded outcome for `idem_key`, if any. Scans
/// newest-first; the store is bounded to `--idem-cap` records (default 500),
/// so a linear scan is cheap.
fn findIdemRecord(records: []const IdemRecord, idem_key: []const u8) ?IdemRecord {
    var i = records.len;
    while (i != 0) {
        i -= 1;
        if (std.mem.eql(u8, records[i].idem_key, idem_key)) return records[i];
    }
    return null;
}

/// Appends one final-outcome record and enforces `cap` by rewriting the file
/// to keep only the newest `cap` records once exceeded. Simple FIFO eviction
/// with no gap-tracking sidecar (unlike audit retention, #187): losing an old
/// idempotency record only risks one harmless redundant re-execution on a very
/// late redelivery — an at-least-once-safe outcome, not silent data loss — so
/// the extra durability machinery #187 needed is not justified here.
fn appendIdemRecord(arena: std.mem.Allocator, io: std.Io, home: []const u8, record: IdemRecord, cap: u32) !void {
    const dir = try std.fs.path.join(arena, &.{ home, "edge" });
    try ensurePrivateDir(io, dir);
    const path = try idemStorePath(arena, home);

    var line: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(record, .{ .emit_null_optional_fields = false }, &line.writer);
    try appendJsonLine(io, path, line.writer.buffered());

    const existing = try loadIdemStore(arena, io, home);
    if (existing.len <= cap) return;
    const keep = existing[existing.len - cap ..];
    var out: std.Io.Writer.Allocating = .init(arena);
    for (keep) |r| {
        try std.json.Stringify.value(r, .{ .emit_null_optional_fields = false }, &out.writer);
        try out.writer.writeByte('\n');
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.writer.buffered() });
}

/// Appends one provenance line to `<home>/logs/edge-audit.jsonl`. Best-effort
/// from the caller's perspective (callers in `runDispatchCycle` catch and warn
/// rather than abort), but this function itself surfaces the real error so
/// tests can assert on it directly.
fn appendProvenanceRecord(arena: std.mem.Allocator, io: std.Io, home: []const u8, record: ProvenanceRecord) !void {
    const dir = try std.fs.path.join(arena, &.{ home, "logs" });
    try ensurePrivateDir(io, dir);
    const path = try edgeAuditLogPath(arena, home);
    var line: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(record, .{ .emit_null_optional_fields = false }, &line.writer);
    try appendJsonLine(io, path, line.writer.buffered());
}

/// Caps a possibly-oversized or malformed identifier (a `bad_schema` job's
/// `job_id`/`idem_key` may never have passed `isSafeIdentifier`, so it could
/// be arbitrarily long or contain control characters) to a bounded prefix
/// before it is echoed into a `job_event` or provenance record. `std.json`
/// string-escapes the result regardless, so this is a size bound, not a
/// correctness requirement.
fn boundedForReport(s: []const u8) []const u8 {
    const cap = 256;
    return if (s.len > cap) s[0..cap] else s;
}

/// Collects the local status envelope for a one-shot command, translating a
/// failed/timed-out `scoot daemon status --json` child into a clean message and
/// the stable `exit_collect_failed` code instead of a raw error stack trace.
fn collectOrDie(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: Options,
    err_out: *std.Io.Writer,
) !StatusEnvelope {
    return collectStatusEnvelope(arena, io, env, opts) catch |e| switch (e) {
        error.ChildTimeout => {
            try err_out.print(
                "error: timed out collecting local status (the '{s} daemon status --json' child exceeded {d}ms)\n",
                .{ opts.scoot_bin, proc.effectiveTimeoutMs(opts.timeout_ms, default_timeout_ms) },
            );
            die(err_out, exit_collect_failed);
        },
        error.ChildFailed => {
            try err_out.print(
                "error: could not collect local status; the '{s} daemon status --json' child failed (is scoot installed and on PATH?)\n",
                .{opts.scoot_bin},
            );
            die(err_out, exit_collect_failed);
        },
        error.ChildSpawnFailed => {
            try err_out.print(
                "error: could not run '{s}' (is scoot installed and on PATH?)\n",
                .{opts.scoot_bin},
            );
            die(err_out, exit_collect_failed);
        },
        else => return e,
    };
}

/// Set by the SIGINT/SIGTERM handler so an unbounded `run` loop finishes the
/// in-flight heartbeat and exits cleanly (status 0) instead of being hard-killed.
/// POSIX only; elsewhere the loop still relies on the supervisor's stop signal.
var stop_requested: std.atomic.Value(bool) = .init(false);

const stop_signals_supported = builtin.os.tag != .windows;

fn stopRequested() bool {
    return stop_requested.load(.monotonic);
}

fn installStopHandlers() void {
    if (comptime !stop_signals_supported) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleStop },
        .mask = std.posix.sigemptyset(),
        // SA_RESTART so an in-flight POST is not aborted with EINTR; the flag is
        // observed at the next loop / backoff-slice boundary instead.
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

fn handleStop(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .monotonic);
}

fn stringifyEnvelope(arena: std.mem.Allocator, envelope: StatusEnvelope) ![]const u8 {
    var payload: std.Io.Writer.Allocating = .init(arena);
    // Omit null optionals so a bare heartbeat (no `node` descriptor) stays byte-identical.
    try std.json.Stringify.value(envelope, .{ .emit_null_optional_fields = false }, &payload.writer);
    try payload.writer.writeByte('\n');
    return payload.writer.buffered();
}

/// Continuous report-only heartbeat loop. Each iteration uses a per-turn arena
/// that is reset between posts, so an unbounded run holds bounded memory. A
/// transient failure (collection, encode, network, non-2xx) never aborts the
/// loop: it is logged, the failure streak drives a bounded jittered backoff, and
/// the loop continues. SIGINT/SIGTERM requests a clean shutdown: the in-flight
/// heartbeat finishes, the loop breaks, and the process exits 0.
fn runLoop(
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: Options,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !void {
    const ca = try requireCenterAndToken(err_out, env, opts);
    // Validated once at startup so a misconfigured `--enable-jobs` fails
    // closed immediately instead of silently never dispatching for the life
    // of a long-running process.
    const jc: ?JobDispatchConfig = if (opts.enable_jobs) try requireJobDispatchConfig(err_out, opts) else null;
    installStopHandlers();

    var iter_arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer iter_arena_state.deinit();

    var prng = std.Random.DefaultPrng.init(@bitCast(std.Io.Timestamp.now(io, .real).toMilliseconds()));
    const rand = prng.random();

    var successes: u64 = 0;
    var fail_streak: u32 = 0;
    while (!stopRequested()) {
        _ = iter_arena_state.reset(.retain_capacity);
        const iter = iter_arena_state.allocator();

        const failed = postOneHeartbeat(iter, io, env, opts, ca, out, err_out) catch |e| blk: {
            try err_out.print("warn: heartbeat failed: {s}; will retry\n", .{@errorName(e)});
            break :blk true;
        };
        if (jc) |cfg| {
            // Job dispatch failures are always contained here (never
            // propagated) so they can never affect the heartbeat's own
            // success/failure streak or backoff.
            postOneDispatchCycle(iter, io, env, opts, ca, cfg, out, err_out);
        }
        out.flush() catch {};
        err_out.flush() catch {};

        if (failed) {
            fail_streak +|= 1;
        } else {
            fail_streak = 0;
            successes += 1;
            if (opts.max_posts != 0 and successes >= opts.max_posts) break;
        }

        const wait_ms = if (fail_streak == 0)
            opts.interval_ms
        else
            jitteredBackoffMs(rand, fail_streak, opts.interval_ms);
        interruptibleSleep(io, wait_ms);
    }
    if (stopRequested()) {
        err_out.writeAll("scoot-edge: stop signal received; exiting cleanly\n") catch {};
        err_out.flush() catch {};
    }
}

/// Collects and posts one heartbeat. Returns `true` on a transient (retryable)
/// failure and `false` on success. Only genuinely unexpected errors propagate.
fn postOneHeartbeat(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: Options,
    ca: CenterAuth,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !bool {
    const envelope = collectStatusEnvelope(arena, io, env, opts) catch |e| {
        try err_out.print("warn: heartbeat collection failed: {s}; will retry\n", .{@errorName(e)});
        return true;
    };
    const payload = try stringifyEnvelope(arena, envelope);
    const res = postJson(arena, io, ca.url, ca.token, payload, opts.timeout_ms) catch |e| {
        try err_out.print("warn: heartbeat POST failed: {s}; will retry\n", .{@errorName(e)});
        return true;
    };
    if (res.timed_out) {
        try err_out.writeAll("warn: heartbeat POST timed out; will retry\n");
        return true;
    }
    if (res.err) |e| {
        try err_out.print("warn: heartbeat POST failed: {s}; will retry\n", .{e});
        return true;
    }
    if (res.status < 200 or res.status >= 300) {
        try err_out.print("warn: heartbeat POST returned HTTP {d}; will retry\n", .{res.status});
        return true;
    }
    try out.print("posted status node_id={s} status={d}\n", .{ envelope.node_id, res.status });
    return false;
}

/// POSTs one `job_event` lifecycle envelope over the same telemetry channel
/// as `status`/`audit_batch` (docs/EDGE.md: "reported back over the same
/// append-only telemetry channel"). Errors propagate to the caller, which by
/// convention treats a failed job_event POST as best-effort/non-fatal: the
/// local provenance log and idempotency store, not the center's copy, are
/// this node's durable record of what happened.
fn postJobEvent(arena: std.mem.Allocator, io: std.Io, ca: CenterAuth, node_id: []const u8, body: JobEventBody) !void {
    const envelope: JobEventEnvelope = .{
        .node_id = node_id,
        .sent_ts = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .body = body,
    };
    var payload: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(envelope, .{ .emit_null_optional_fields = false }, &payload.writer);
    try payload.writer.writeByte('\n');
    _ = try postJson(arena, io, ca.url, ca.token, payload.writer.buffered(), default_timeout_ms);
}

/// Reports a job that never reached execution: a `job_event(phase=rejected)`
/// (best-effort) plus a durable provenance line. Never propagates an error —
/// a reject is already the "something went wrong" path, so a secondary
/// telemetry/logging failure here must not abort the rest of the dispatch
/// cycle.
fn reportRejected(
    arena: std.mem.Allocator,
    io: std.Io,
    err_out: *std.Io.Writer,
    ca: CenterAuth,
    node_id: []const u8,
    home: []const u8,
    job: JobEnvelope,
    reason: RejectReason,
) void {
    const job_id = boundedForReport(job.body.job_id);
    const idem_key = boundedForReport(job.body.idem_key);
    postJobEvent(arena, io, ca, node_id, .{
        .job_id = job_id,
        .phase = JobPhase.rejected.asString(),
        .reject_reason = reason.asString(),
    }) catch |e| err_out.print("warn: job_event(rejected) POST failed: {s}\n", .{@errorName(e)}) catch {};
    appendProvenanceRecord(arena, io, home, .{
        .ts = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .node_id = node_id,
        .job_id = job_id,
        .idem_key = idem_key,
        .phase = JobPhase.rejected.asString(),
        .reject_reason = reason.asString(),
    }) catch |e| err_out.print("warn: failed to persist rejected provenance record: {s}\n", .{@errorName(e)}) catch {};
}

/// One lease-poll-and-execute cycle: GETs the lease, then for each returned
/// job validates/dedupes/executes it and reports lifecycle telemetry plus
/// local provenance. A lease-fetch-level failure (network, timeout, non-2xx)
/// propagates to the caller as a whole-cycle error; everything past a
/// successful fetch is per-job contained (schema failures, execution errors,
/// and telemetry/logging failures are all caught and reported, never
/// propagated), so one bad job can never poison the rest of the batch.
fn runDispatchCycle(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: Options,
    ca: CenterAuth,
    jc: JobDispatchConfig,
    err_out: *std.Io.Writer,
) !DispatchSummary {
    const node_id = if (opts.node_id) |id| id else try defaultNodeId(arena, env);
    const home = try resolveEdgeHome(arena, env, opts);

    const url = try buildLeaseUrl(arena, jc.lease_url, node_id, opts.lease_capacity);
    const res = try getJson(arena, io, url, ca.token, opts.timeout_ms);
    if (res.timed_out) return error.LeasePollTimedOut;
    if (res.err != null) return error.LeasePollFailed;
    if (res.status < 200 or res.status >= 300) return error.LeasePollHttpError;

    var jobs = try parseLeaseBody(arena, res.body);
    var summary: DispatchSummary = .{};

    if (jobs.len > opts.lease_capacity) {
        // The center sent more jobs than the requested lease capacity: accept
        // only the first `lease_capacity` (in response order) and reject the
        // rest as `at_capacity` rather than silently dropping or
        // unboundedly executing them (docs/EDGE.md "Bounded in-flight queue").
        var idx: usize = opts.lease_capacity;
        while (idx < jobs.len) : (idx += 1) {
            reportRejected(arena, io, err_out, ca, node_id, home, jobs[idx], .at_capacity);
            summary.rejected += 1;
        }
        jobs = jobs[0..opts.lease_capacity];
    }

    const idem_records = try loadIdemStore(arena, io, home);
    for (jobs) |job| {
        if (validateJobEnvelope(job)) |reason| {
            reportRejected(arena, io, err_out, ca, node_id, home, job, reason);
            summary.rejected += 1;
            continue;
        }

        if (findIdemRecord(idem_records, job.body.idem_key)) |prior| {
            // Redelivery of an already-finalized job: ack the cached outcome
            // instead of re-running (docs/EDGE.md "Idempotent apply"). The
            // original provenance line from the first attempt already exists,
            // so no new one is written here for a pure replay.
            postJobEvent(arena, io, ca, node_id, .{
                .job_id = job.body.job_id,
                .phase = prior.phase,
                .session_id = prior.session_id,
                .effective_policy = prior.effective_policy,
                .reject_reason = prior.reject_reason,
            }) catch |e| err_out.print("warn: job_event(replay) POST failed: {s}\n", .{@errorName(e)}) catch {};
            summary.replayed += 1;
            continue;
        }

        summary.accepted += 1;
        postJobEvent(arena, io, ca, node_id, .{ .job_id = job.body.job_id, .phase = JobPhase.accepted.asString() }) catch |e|
            err_out.print("warn: job_event(accepted) POST failed: {s}\n", .{@errorName(e)}) catch {};
        appendProvenanceRecord(arena, io, home, .{
            .ts = std.Io.Timestamp.now(io, .real).toMilliseconds(),
            .node_id = node_id,
            .job_id = job.body.job_id,
            .idem_key = job.body.idem_key,
            .phase = JobPhase.accepted.asString(),
        }) catch |e| err_out.print("warn: failed to persist accepted provenance record: {s}\n", .{@errorName(e)}) catch {};

        const result = executeJob(arena, io, opts, jc.job_root, job) catch |err| {
            err_out.print("warn: job {s} execution error: {s}\n", .{ job.body.job_id, @errorName(err) }) catch {};
            postJobEvent(arena, io, ca, node_id, .{ .job_id = job.body.job_id, .phase = JobPhase.failed.asString() }) catch |e|
                err_out.print("warn: job_event(failed) POST failed: {s}\n", .{@errorName(e)}) catch {};
            appendProvenanceRecord(arena, io, home, .{
                .ts = std.Io.Timestamp.now(io, .real).toMilliseconds(),
                .node_id = node_id,
                .job_id = job.body.job_id,
                .idem_key = job.body.idem_key,
                .phase = JobPhase.failed.asString(),
            }) catch |e| err_out.print("warn: failed to persist failed provenance record: {s}\n", .{@errorName(e)}) catch {};
            appendIdemRecord(arena, io, home, .{
                .idem_key = job.body.idem_key,
                .job_id = job.body.job_id,
                .phase = JobPhase.failed.asString(),
                .ts = std.Io.Timestamp.now(io, .real).toMilliseconds(),
            }, opts.idem_cap) catch |e| err_out.print("warn: failed to persist idem record: {s}\n", .{@errorName(e)}) catch {};
            summary.failed += 1;
            continue;
        };

        const outcome: JobPhase = if (!result.timed_out and result.exit_code == 0) .done else .failed;
        const phase = outcome.asString();
        postJobEvent(arena, io, ca, node_id, .{
            .job_id = job.body.job_id,
            .phase = phase,
            .session_id = result.session_id,
            .effective_policy = result.effective_policy,
        }) catch |e| err_out.print("warn: job_event({s}) POST failed: {s}\n", .{ phase, @errorName(e) }) catch {};
        appendProvenanceRecord(arena, io, home, .{
            .ts = std.Io.Timestamp.now(io, .real).toMilliseconds(),
            .node_id = node_id,
            .job_id = job.body.job_id,
            .idem_key = job.body.idem_key,
            .phase = phase,
            .session_id = result.session_id,
            .effective_policy = result.effective_policy,
        }) catch |e| err_out.print("warn: failed to persist {s} provenance record: {s}\n", .{ phase, @errorName(e) }) catch {};
        appendIdemRecord(arena, io, home, .{
            .idem_key = job.body.idem_key,
            .job_id = job.body.job_id,
            .phase = phase,
            .session_id = result.session_id,
            .effective_policy = result.effective_policy,
            .ts = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        }, opts.idem_cap) catch |e| err_out.print("warn: failed to persist idem record: {s}\n", .{@errorName(e)}) catch {};

        if (outcome == .done) summary.done += 1 else summary.failed += 1;
    }

    return summary;
}

/// Runs one dispatch cycle from within `run --enable-jobs`'s heartbeat loop.
/// Mirrors `postOneHeartbeat`'s resilience contract but goes one step
/// further: even a whole-cycle error (e.g. the lease endpoint is down) is
/// caught and logged here rather than returned, since job dispatch must never
/// be able to affect the heartbeat loop's own failure streak or backoff.
fn postOneDispatchCycle(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: Options,
    ca: CenterAuth,
    jc: JobDispatchConfig,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) void {
    const summary = runDispatchCycle(arena, io, env, opts, ca, jc, err_out) catch |e| {
        err_out.print("warn: job dispatch cycle failed: {s}; will retry\n", .{@errorName(e)}) catch {};
        return;
    };
    if (summary.accepted != 0 or summary.rejected != 0 or summary.replayed != 0) {
        out.print(
            "dispatch cycle: accepted={d} done={d} failed={d} rejected={d} replayed={d}\n",
            .{ summary.accepted, summary.done, summary.failed, summary.rejected, summary.replayed },
        ) catch {};
    }
}

/// One-shot `scoot-edge dispatch`: validates required config (exits with
/// `exit_config_error` if missing) and runs exactly one lease-poll-and-execute
/// cycle, printing a summary line. Useful for cron-style invocation or a
/// single manual test poll, as opposed to `run --enable-jobs`'s continuous
/// loop.
fn dispatchOnce(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: Options,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !void {
    const ca = try requireCenterAndToken(err_out, env, opts);
    const jc = try requireJobDispatchConfig(err_out, opts);
    const summary = runDispatchCycle(arena, io, env, opts, ca, jc, err_out) catch |e| {
        try err_out.print("error: job dispatch cycle failed: {s}\n", .{@errorName(e)});
        die(err_out, exit_post_failed);
    };
    try out.print(
        "dispatch cycle complete: accepted={d} done={d} failed={d} rejected={d} replayed={d}\n",
        .{ summary.accepted, summary.done, summary.failed, summary.rejected, summary.replayed },
    );
}

/// Monotonic, overflow-safe exponential backoff ceiling for a 1-based attempt:
/// attempt 1 -> base, attempt 2 -> 2*base, ... clamped to `cap_ms`.
fn backoffCeilingMs(attempt: u32, base_ms: u64, cap_ms: u64) u64 {
    var v = @min(base_ms, cap_ms);
    var i: u32 = 1;
    while (i < attempt) : (i += 1) {
        if (v >= cap_ms) return cap_ms;
        v = if (v > cap_ms / 2) cap_ms else v * 2;
    }
    return v;
}

/// Full-jitter delay in `[min(base, ceiling), ceiling]` to avoid synchronized
/// fleet-wide retry storms against the center. The base is floored at
/// `min_backoff_ms` so a tiny steady-state interval still backs off on failure.
fn jitteredBackoffMs(rand: std.Random, attempt: u32, base_ms: u64) u64 {
    const effective_base = @max(base_ms, min_backoff_ms);
    const ceiling = backoffCeilingMs(attempt, effective_base, max_backoff_ms);
    const floor = @min(effective_base, ceiling);
    if (ceiling <= floor) return ceiling;
    return floor + rand.uintLessThan(u64, ceiling - floor + 1);
}

fn parseArgs(arena: std.mem.Allocator, out: *std.Io.Writer, args: []const []const u8) !Options {
    var opts: Options = .{};
    var labels: std.ArrayList([]const u8) = .empty;
    var skills: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
        if (std.mem.eql(u8, args[i], "status")) {
            opts.command = .status;
        } else if (std.mem.eql(u8, args[i], "post-once")) {
            opts.command = .post_once;
        } else if (std.mem.eql(u8, args[i], "run")) {
            opts.command = .run;
        } else if (std.mem.eql(u8, args[i], "dispatch")) {
            opts.command = .dispatch;
        } else {
            try out.print("error: unknown command '{s}'\n\n", .{args[i]});
            try out.writeAll(usage);
            die(out, exit_config_error);
        }
        i += 1;
    }
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            return error.HelpShown;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try out.print("scoot-edge {s}\n", .{build_options.version});
            return error.HelpShown;
        } else if (std.mem.eql(u8, arg, "--node-id")) {
            opts.node_id = try nextArg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--scoot-bin")) {
            opts.scoot_bin = try nextArg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--scoot-home")) {
            opts.scoot_home = try nextArg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--center-url")) {
            opts.center_url = try nextArg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--token-env")) {
            opts.token_env = try nextArg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            opts.timeout_ms = try parseU64Arg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--interval-ms")) {
            const parsed = try parseU64Arg(out, args, &i, arg);
            // 0 means "use the default" (consistent with --timeout-ms); it also
            // keeps the success-path loop from degenerating into a POST storm.
            opts.interval_ms = if (parsed == 0) default_interval_ms else parsed;
        } else if (std.mem.eql(u8, arg, "--max-posts")) {
            opts.max_posts = try parseU64Arg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--report-capabilities")) {
            opts.report_capabilities = true;
        } else if (std.mem.eql(u8, arg, "--label")) {
            try labels.append(arena, try nextArg(out, args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--skill")) {
            try skills.append(arena, try nextArg(out, args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--allow-insecure-http")) {
            opts.allow_insecure_http = true;
        } else if (std.mem.eql(u8, arg, "--job-root")) {
            opts.job_root = try nextArg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--lease-url")) {
            opts.lease_url = try nextArg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--lease-capacity")) {
            const parsed = try parseU32Arg(out, args, &i, arg);
            if (parsed == 0) {
                try out.writeAll("error: --lease-capacity must be at least 1\n");
                die(out, exit_config_error);
            }
            opts.lease_capacity = parsed;
        } else if (std.mem.eql(u8, arg, "--idem-cap")) {
            opts.idem_cap = try parseU32Arg(out, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--enable-jobs")) {
            opts.enable_jobs = true;
        } else {
            try out.print("error: unknown argument '{s}'\n\n", .{arg});
            try out.writeAll(usage);
            die(out, exit_config_error);
        }
    }
    opts.labels = labels.items;
    opts.skills = skills.items;
    return opts;
}

fn parseU64Arg(out: *std.Io.Writer, args: []const []const u8, i: *usize, name: []const u8) !u64 {
    const raw = try nextArg(out, args, i, name);
    return std.fmt.parseInt(u64, raw, 10) catch {
        try out.print("error: {s} must be a non-negative integer: '{s}'\n", .{ name, raw });
        die(out, exit_config_error);
    };
}

fn parseU32Arg(out: *std.Io.Writer, args: []const []const u8, i: *usize, name: []const u8) !u32 {
    const v = try parseU64Arg(out, args, i, name);
    if (v > std.math.maxInt(u32)) {
        try out.print("error: {s} must fit in a 32-bit unsigned integer: '{d}'\n", .{ name, v });
        die(out, exit_config_error);
    }
    return @intCast(v);
}

fn nextArg(out: *std.Io.Writer, args: []const []const u8, i: *usize, name: []const u8) ![]const u8 {
    i.* += 1;
    if (i.* >= args.len or args[i.*].len == 0) {
        try out.print("error: {s} requires a value\n", .{name});
        die(out, exit_config_error);
    }
    return args[i.*];
}

fn collectStatusEnvelope(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: Options,
) !StatusEnvelope {
    const daemon_json = try runScootDaemonStatus(arena, io, opts);
    const scoot_version = try runScootVersion(arena, io, opts);
    const node_id = if (opts.node_id) |id| id else try defaultNodeId(arena, env);
    return .{
        .node_id = node_id,
        .sent_ts = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .body = .{
            .scoot_version = scoot_version,
            .edge_version = build_options.version,
            .daemon = try summarizeDaemonStatus(arena, daemon_json),
            .node = if (opts.report_capabilities)
                try buildNodeDescriptor(arena, env, opts)
            else
                null,
        },
    };
}

fn buildNodeDescriptor(
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    opts: Options,
) !NodeDescriptor {
    const labels = try mergeCsv(arena, opts.labels, env.get("SCOOT_EDGE_LABELS"));
    const skills = try mergeCsv(arena, opts.skills, env.get("SCOOT_EDGE_SKILLS"));
    return nodeDescriptorFrom(labels, skills);
}

fn nodeDescriptorFrom(labels: []const []const u8, skills: []const []const u8) NodeDescriptor {
    return .{
        .labels = labels,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .capabilities = .{
            .max_job_policy = default_max_job_policy,
            .tools = &advisory_readonly_tools,
            .skills = skills,
        },
    };
}

/// Merges flag-provided values with an optional comma-separated env override,
/// trimming and dropping empties. The result is advisory routing metadata.
fn mergeCsv(arena: std.mem.Allocator, base: []const []const u8, csv: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (base) |b| {
        const t = std.mem.trim(u8, b, " \t");
        if (t.len != 0) try list.append(arena, t);
    }
    if (csv) |raw| {
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            const t = std.mem.trim(u8, part, " \t");
            if (t.len != 0) try list.append(arena, t);
        }
    }
    return list.items;
}

fn runScootDaemonStatus(arena: std.mem.Allocator, io: std.Io, opts: Options) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, opts.scoot_bin);
    if (opts.scoot_home) |home| {
        try argv.append(arena, "--scoot-home");
        try argv.append(arena, home);
    }
    try argv.append(arena, "daemon");
    try argv.append(arena, "status");
    try argv.append(arena, "--json");
    const child = try runChild(arena, io, argv.items, .inherit, opts.timeout_ms);
    if (child.timed_out) return error.ChildTimeout;
    if (child.exit_code != 0) return error.ChildFailed;
    return child.stdout;
}

fn runScootVersion(arena: std.mem.Allocator, io: std.Io, opts: Options) ![]const u8 {
    const argv = [_][]const u8{ opts.scoot_bin, "--version" };
    const child = try runChild(arena, io, &argv, .inherit, opts.timeout_ms);
    if (child.timed_out or child.exit_code != 0) return "unknown";
    const trimmed = std.mem.trim(u8, child.stdout, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "scoot ")) return trimmed["scoot ".len..];
    return trimmed;
}

fn runChild(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd, timeout_ms: u64) !ChildOutput {
    const effective_timeout_ms = proc.effectiveTimeoutMs(timeout_ms, default_timeout_ms);
    const base: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(@intCast(effective_timeout_ms)),
    } };
    const timeout = base.toDeadline(io);
    const res = std.process.run(arena, io, .{
        .argv = argv,
        .cwd = cwd,
        .timeout = timeout,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.Timeout => return .{ .stdout = "", .stderr = "", .exit_code = -1, .timed_out = true },
        error.OutOfMemory => return error.OutOfMemory,
        // The child could not be spawned at all (most often the scoot binary is
        // not installed or not on PATH). Surface it as a clean collection error.
        else => return error.ChildSpawnFailed,
    };
    return .{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .exit_code = termToCode(res.term),
    };
}

const ExecuteJobResult = struct {
    session_id: []const u8,
    effective_policy: []const u8,
    exit_code: i32,
    timed_out: bool,
};

/// Runs one already-validated `kind=run` job as
/// `scoot --unattended -e "<goal>" --session-id job-<job_id>`, cwd-confined to
/// `job_root` (docs/EDGE.md "Confined working directory" rule — this is what
/// makes `readonly`'s cwd-relative read confinement mean *this directory*
/// instead of the whole filesystem). `goal` is passed through as a single
/// opaque argv value, never interpreted, expanded, or run through a shell
/// (docs/EDGE.md "Never execute unvalidated model output"). The child's own
/// in-process unattended clamp is the sole authority on policy: this only
/// ever *asks* via `--policy`, matching `job.body.requested_policy` when
/// present, and can only ever lower the effective policy, never raise it.
fn executeJob(arena: std.mem.Allocator, io: std.Io, opts: Options, job_root: []const u8, job: JobEnvelope) !ExecuteJobResult {
    const session_id = try std.fmt.allocPrint(arena, "job-{s}", .{job.body.job_id});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, opts.scoot_bin);
    if (opts.scoot_home) |home| {
        try argv.append(arena, "--scoot-home");
        try argv.append(arena, home);
    }
    try argv.append(arena, "--unattended");
    try argv.append(arena, "-e");
    try argv.append(arena, job.body.goal);
    if (job.body.requested_policy) |p| {
        try argv.append(arena, "--policy");
        try argv.append(arena, p);
    }
    try argv.append(arena, "--session-id");
    try argv.append(arena, session_id);

    const timeout_ms = jobTimeoutMs(io, opts.timeout_ms, job.body.deadline_ts);
    const child = try runChild(arena, io, argv.items, .{ .path = job_root }, timeout_ms);
    return .{
        .session_id = session_id,
        .effective_policy = parseEffectivePolicyFromStderr(child.stderr),
        .exit_code = child.exit_code,
        .timed_out = child.timed_out,
    };
}

/// Shortens the child timeout to whatever remains before `deadline_ts` (wire
/// milliseconds since epoch) when that is sooner than the configured
/// `--timeout-ms`, so an already-expired or nearly-expired deadline naturally
/// routes through the existing timeout -> `failed` path. docs/EDGE.md's closed
/// reject-reason set deliberately has no "expired" case: a deadline miss is a
/// failed *execution*, not a rejected *intake*. Clamped to a 1ms floor so a
/// past deadline still gets a real, if doomed, attempt rather than a
/// zero-duration timeout that could be misread as "no timeout".
fn jobTimeoutMs(io: std.Io, configured_timeout_ms: u64, deadline_ts: ?i64) u64 {
    const deadline = deadline_ts orelse return configured_timeout_ms;
    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const remaining = deadline - now_ms;
    if (remaining <= 0) return 1;
    return @min(configured_timeout_ms, @as(u64, @intCast(remaining)));
}

/// Extracts the mode name from core's existing unattended-clamp stderr line
/// (`src/main.zig`: `"[scoot] unattended one-shot: effective policy = {s}
/// (edge.max_job_policy ceiling = {s})\n"`) instead of adding a new
/// machine-readable output mode to core just for this. Falls back to
/// `"unknown"` when the marker is absent (old scoot binary, suppressed
/// stderr, or a child that never reached the unattended branch), which is
/// resilient rather than fatal since it only affects one telemetry field,
/// never execution or the clamp itself.
fn parseEffectivePolicyFromStderr(stderr: []const u8) []const u8 {
    const marker = "effective policy = ";
    const start = std.mem.indexOf(u8, stderr, marker) orelse return "unknown";
    const rest = stderr[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const mode = std.mem.trim(u8, rest[0..end], " \t\r\n");
    return if (mode.len == 0) "unknown" else mode;
}

fn summarizeDaemonStatus(arena: std.mem.Allocator, bytes: []const u8) !DaemonSummary {
    const parsed = std.json.parseFromSliceLeaky(DaemonStatusPartial, arena, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return .{ .state = "unknown", .clean_prev_stop = false, .since = null };
    const state = parsed.state orelse return .{ .state = "unknown", .clean_prev_stop = true, .since = null };
    const stale_running = std.mem.eql(u8, state.status, "running") and std.mem.eql(u8, parsed.liveness, "dead");
    const since = if (state.stopped_at_unix) |t| t else if (state.started_at_unix != 0) state.started_at_unix else state.updated_at_unix;
    return .{
        .state = state.status,
        .clean_prev_stop = !stale_running,
        .since = since,
    };
}

fn defaultNodeId(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("SCOOT_EDGE_NODE_ID")) |id| if (id.len != 0) return id;
    if (env.get("HOSTNAME")) |h| if (h.len != 0) return h;
    return arena.dupe(u8, "local");
}

fn postJson(arena: std.mem.Allocator, io: std.Io, url: []const u8, token: []const u8, payload: []const u8, timeout_ms: u64) !FetchResult {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
    var resp: std.Io.Writer.Allocating = .init(arena);
    return fetchWithTimeout(io, &client, url, auth, payload, &resp, timeout_ms);
}

/// GET analog of `postJson`, used to poll the lease endpoint. No request body
/// is sent; `resp` accumulates the NDJSON response body (0..N job envelopes).
fn getJson(arena: std.mem.Allocator, io: std.Io, url: []const u8, token: []const u8, timeout_ms: u64) !FetchResult {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
    var resp: std.Io.Writer.Allocating = .init(arena);
    return fetchGetWithTimeout(io, &client, url, auth, &resp, timeout_ms);
}

/// Only RFC 3986 "unreserved" characters pass through unescaped; everything
/// else (including `/`, `&`, `=`, and any attacker-controlled separator) is
/// percent-encoded. Deliberately stricter than URI's own `isQueryChar` so a
/// `node_id` containing a stray `&` or `#` can never be mistaken for a query
/// delimiter or reopen the URL's fragment/path.
fn isSafeQueryValueChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Builds `<lease_url>?node=<percent-encoded node_id>&capacity=<N>`. `lease_url`
/// is operator-provided config (trusted); only `node_id` is percent-encoded,
/// since it may be derived from the untrusted-ish local hostname
/// (`defaultNodeId`) or an operator `--node-id` override.
fn buildLeaseUrl(arena: std.mem.Allocator, lease_url: []const u8, node_id: []const u8, capacity: u32) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(arena);
    try buf.writer.writeAll(lease_url);
    try buf.writer.writeAll(if (std.mem.indexOfScalar(u8, lease_url, '?') == null) "?" else "&");
    try buf.writer.writeAll("node=");
    try std.Uri.Component.percentEncode(&buf.writer, node_id, isSafeQueryValueChar);
    try buf.writer.print("&capacity={d}", .{capacity});
    return buf.writer.buffered();
}

fn centerUrlAllowed(url: []const u8, allow_insecure_http: bool) bool {
    if (std.mem.startsWith(u8, url, "https://")) return true;
    if (!allow_insecure_http or !std.mem.startsWith(u8, url, "http://")) return false;
    const host = urlHost(url) orelse return false;
    return isLoopbackHost(host);
}

fn urlHost(url: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[sep + 3 ..];
    if (rest.len == 0) return null;
    var auth_end: usize = rest.len;
    for (rest, 0..) |c, i| {
        if (c == '/' or c == '?' or c == '#') {
            auth_end = i;
            break;
        }
    }
    var authority = rest[0..auth_end];
    if (authority.len == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (authority.len == 0) return null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        return authority[1..close];
    }
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| return authority[0..colon];
    return authority;
}

fn isLoopbackHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.ascii.eqlIgnoreCase(host, "localhost.")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    var parts = std.mem.splitScalar(u8, host, '.');
    const first = parts.next() orelse return false;
    if (!std.mem.eql(u8, first, "127")) return false;
    var n: usize = 1;
    while (parts.next()) |part| {
        n += 1;
        if (part.len == 0 or part.len > 3) return false;
        var value: u16 = 0;
        for (part) |c| {
            if (c < '0' or c > '9') return false;
            value = value * 10 + (c - '0');
        }
        if (value > 255) return false;
    }
    return n == 4;
}

fn fetchWithTimeout(
    io: std.Io,
    client: *std.http.Client,
    url: []const u8,
    auth: []const u8,
    payload: []const u8,
    resp: *std.Io.Writer.Allocating,
    timeout_ms: u64,
) FetchResult {
    const effective_timeout_ms = proc.effectiveTimeoutMs(timeout_ms, default_timeout_ms);

    const Outcome = union(enum) { done: FetchResult, timed_out: void };
    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);
    sel.concurrent(.done, doPost, .{ client, url, auth, payload, resp }) catch |err| return .{ .err = @errorName(err) };
    sel.concurrent(.timed_out, sleepDeadline, .{ io, effective_timeout_ms }) catch |err| {
        sel.cancelDiscard();
        return .{ .err = @errorName(err) };
    };
    const winner = sel.await() catch |err| {
        sel.cancelDiscard();
        return .{ .err = @errorName(err) };
    };
    sel.cancelDiscard();
    return switch (winner) {
        .done => |r| r,
        .timed_out => .{ .timed_out = true },
    };
}

fn doPost(client: *std.http.Client, url: []const u8, auth: []const u8, payload: []const u8, resp: *std.Io.Writer.Allocating) FetchResult {
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{
            .content_type = .{ .override = "application/x-ndjson" },
            .authorization = .{ .override = auth },
        },
        .response_writer = &resp.writer,
    }) catch |e| return .{ .err = @errorName(e) };
    return .{ .status = @intFromEnum(result.status), .body = resp.writer.buffered() };
}

/// GET analog of `fetchWithTimeout`, racing `doGet` against the timeout via the
/// same `std.Io.Select` pattern so a hung lease poll cannot block a heartbeat
/// cycle any longer than `timeout_ms`.
fn fetchGetWithTimeout(
    io: std.Io,
    client: *std.http.Client,
    url: []const u8,
    auth: []const u8,
    resp: *std.Io.Writer.Allocating,
    timeout_ms: u64,
) FetchResult {
    const effective_timeout_ms = proc.effectiveTimeoutMs(timeout_ms, default_timeout_ms);

    const Outcome = union(enum) { done: FetchResult, timed_out: void };
    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);
    sel.concurrent(.done, doGet, .{ client, url, auth, resp }) catch |err| return .{ .err = @errorName(err) };
    sel.concurrent(.timed_out, sleepDeadline, .{ io, effective_timeout_ms }) catch |err| {
        sel.cancelDiscard();
        return .{ .err = @errorName(err) };
    };
    const winner = sel.await() catch |err| {
        sel.cancelDiscard();
        return .{ .err = @errorName(err) };
    };
    sel.cancelDiscard();
    return switch (winner) {
        .done => |r| r,
        .timed_out => .{ .timed_out = true },
    };
}

fn doGet(client: *std.http.Client, url: []const u8, auth: []const u8, resp: *std.Io.Writer.Allocating) FetchResult {
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{
            .authorization = .{ .override = auth },
        },
        .response_writer = &resp.writer,
    }) catch |e| return .{ .err = @errorName(e) };
    return .{ .status = @intFromEnum(result.status), .body = resp.writer.buffered() };
}

fn sleepDeadline(io: std.Io, timeout_ms: u64) void {
    const d: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    };
    d.sleep(io) catch {};
}

/// Sleeps up to `total_ms`, waking promptly when a stop signal arrives so a
/// supervised `run` shuts down within a slice instead of a whole interval.
fn interruptibleSleep(io: std.Io, total_ms: u64) void {
    if (comptime !stop_signals_supported) return sleepDeadline(io, total_ms);
    const slice_ms: u64 = 200;
    var remaining = total_ms;
    while (remaining != 0) {
        if (stopRequested()) return;
        const chunk = @min(remaining, slice_ms);
        sleepDeadline(io, chunk);
        remaining -= chunk;
    }
}

fn termToCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @as(i32, code),
        else => -1,
    };
}

fn die(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

test "summarizeDaemonStatus maps daemon JSON to E1 heartbeat daemon summary" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\{"format":"scoot.daemon.status.v1","state":{"status":"running","pid":12,"started_at_unix":10,"updated_at_unix":11,"schedule_enabled":true,"jobs":1,"poll_ms":1000},"pid_file":12,"liveness":"alive","probed_pid":12}
    ;
    const got = try summarizeDaemonStatus(arena, src);
    try std.testing.expectEqualStrings("running", got.state);
    try std.testing.expect(got.clean_prev_stop);
    try std.testing.expectEqual(@as(?i64, 10), got.since);
}

test "summarizeDaemonStatus flags stale running daemon" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\{"state":{"status":"running","started_at_unix":10,"updated_at_unix":11},"liveness":"dead"}
    ;
    const got = try summarizeDaemonStatus(arena, src);
    try std.testing.expectEqualStrings("running", got.state);
    try std.testing.expect(!got.clean_prev_stop);
}

test "post-once requires HTTPS or explicitly insecure loopback URL" {
    try std.testing.expect(centerUrlAllowed("https://center.example/telemetry", false));
    try std.testing.expect(centerUrlAllowed("https://center.example/telemetry", true));
    try std.testing.expect(!centerUrlAllowed("http://localhost:8080/telemetry", false));
    try std.testing.expect(centerUrlAllowed("http://localhost:8080/telemetry", true));
    try std.testing.expect(centerUrlAllowed("http://127.0.0.1:8080/telemetry", true));
    try std.testing.expect(centerUrlAllowed("http://[::1]:8080/telemetry", true));
    try std.testing.expect(!centerUrlAllowed("http://center.example/telemetry", true));
    try std.testing.expect(!centerUrlAllowed("http://10.0.0.5/telemetry", true));
    try std.testing.expect(!centerUrlAllowed("ftp://center.example/telemetry", true));
}

test "backoffCeilingMs grows exponentially and clamps to the cap" {
    try std.testing.expectEqual(@as(u64, 1000), backoffCeilingMs(1, 1000, 60_000));
    try std.testing.expectEqual(@as(u64, 2000), backoffCeilingMs(2, 1000, 60_000));
    try std.testing.expectEqual(@as(u64, 4000), backoffCeilingMs(3, 1000, 60_000));
    try std.testing.expectEqual(@as(u64, 8000), backoffCeilingMs(4, 1000, 60_000));
    // Eventually clamps to the cap and never exceeds it.
    try std.testing.expectEqual(@as(u64, 60_000), backoffCeilingMs(20, 1000, 60_000));
    try std.testing.expectEqual(@as(u64, 60_000), backoffCeilingMs(1000, 1000, 60_000));
    // attempt 0 degrades to the (capped) base without underflowing.
    try std.testing.expectEqual(@as(u64, 1000), backoffCeilingMs(0, 1000, 60_000));
    // A base already above the cap is clamped immediately.
    try std.testing.expectEqual(@as(u64, 5000), backoffCeilingMs(3, 9999, 5000));
}

test "jitteredBackoffMs stays within [base, ceiling] for every attempt" {
    var prng = std.Random.DefaultPrng.init(0xED9E_5EED);
    const rand = prng.random();
    var attempt: u32 = 1;
    while (attempt <= 40) : (attempt += 1) {
        const ceiling = backoffCeilingMs(attempt, 1000, max_backoff_ms);
        var trial: usize = 0;
        while (trial < 64) : (trial += 1) {
            const wait = jitteredBackoffMs(rand, attempt, 1000);
            try std.testing.expect(wait >= @min(@as(u64, 1000), ceiling));
            try std.testing.expect(wait <= ceiling);
        }
    }
}

test "jitteredBackoffMs floors a zero/tiny base so failures never busy-spin" {
    var prng = std.Random.DefaultPrng.init(0xB16B_00B5);
    const rand = prng.random();
    // A 0 base (e.g. an un-normalized interval) must still back off, not spin.
    var attempt: u32 = 1;
    while (attempt <= 8) : (attempt += 1) {
        try std.testing.expect(jitteredBackoffMs(rand, attempt, 0) >= min_backoff_ms);
        try std.testing.expect(jitteredBackoffMs(rand, attempt, 1) >= min_backoff_ms);
    }
}

test "mergeCsv combines flags and env, trims, and drops empties" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = [_][]const u8{ "role:db", "  ", "env:prod" };
    const merged = try mergeCsv(arena, &base, " focus:log-triage , , extra ");
    try std.testing.expectEqual(@as(usize, 4), merged.len);
    try std.testing.expectEqualStrings("role:db", merged[0]);
    try std.testing.expectEqualStrings("env:prod", merged[1]);
    try std.testing.expectEqualStrings("focus:log-triage", merged[2]);
    try std.testing.expectEqualStrings("extra", merged[3]);

    const none = try mergeCsv(arena, &.{}, null);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "nodeDescriptorFrom is advisory: readonly ceiling, derived os/arch, declared tools" {
    const labels = [_][]const u8{"role:db"};
    const skills = [_][]const u8{"log-triage"};
    const node = nodeDescriptorFrom(&labels, &skills);
    try std.testing.expectEqualStrings("readonly", node.capabilities.max_job_policy);
    try std.testing.expect(node.os.len != 0);
    try std.testing.expect(node.arch.len != 0);
    try std.testing.expectEqualStrings("file_read", node.capabilities.tools[0]);
    try std.testing.expectEqualStrings("role:db", node.labels[0]);
    try std.testing.expectEqualStrings("log-triage", node.capabilities.skills[0]);
}

test "parseArgs accepts the run command with loop and capability flags" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const out = &aw.writer;

    const args = [_][]const u8{
        "scoot-edge",                       "run",
        "--interval-ms",                    "1500",
        "--max-posts",                      "3",
        "--report-capabilities",            "--label",
        "role:db",                          "--skill",
        "log-triage",                       "--center-url",
        "https://center.example/telemetry",
    };
    const opts = try parseArgs(arena, out, &args);
    try std.testing.expectEqual(Command.run, opts.command);
    try std.testing.expectEqual(@as(u64, 1500), opts.interval_ms);
    try std.testing.expectEqual(@as(u64, 3), opts.max_posts);
    try std.testing.expect(opts.report_capabilities);
    try std.testing.expectEqual(@as(usize, 1), opts.labels.len);
    try std.testing.expectEqualStrings("role:db", opts.labels[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.skills.len);
    try std.testing.expectEqualStrings("log-triage", opts.skills[0]);
}

test "parseArgs normalizes --interval-ms 0 to the default interval" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const out = &aw.writer;

    const args = [_][]const u8{ "scoot-edge", "run", "--interval-ms", "0" };
    const opts = try parseArgs(arena, out, &args);
    try std.testing.expectEqual(default_interval_ms, opts.interval_ms);
}

test "parseArgs accepts the dispatch command and job-dispatch flags" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const out = &aw.writer;

    const args = [_][]const u8{
        "scoot-edge",       "dispatch",
        "--job-root",       "/tmp/scoot-job-root",
        "--lease-url",      "https://center.example/jobs/lease",
        "--lease-capacity", "3",
        "--idem-cap",       "50",
    };
    const opts = try parseArgs(arena, out, &args);
    try std.testing.expectEqual(Command.dispatch, opts.command);
    try std.testing.expectEqualStrings("/tmp/scoot-job-root", opts.job_root.?);
    try std.testing.expectEqualStrings("https://center.example/jobs/lease", opts.lease_url.?);
    try std.testing.expectEqual(@as(u32, 3), opts.lease_capacity);
    try std.testing.expectEqual(@as(u32, 50), opts.idem_cap);
}

test "parseArgs accepts run --enable-jobs alongside the heartbeat flags" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const out = &aw.writer;

    const args = [_][]const u8{
        "scoot-edge",                        "run",
        "--enable-jobs",                     "--job-root",
        "/tmp/scoot-job-root",               "--lease-url",
        "https://center.example/jobs/lease",
    };
    const opts = try parseArgs(arena, out, &args);
    try std.testing.expectEqual(Command.run, opts.command);
    try std.testing.expect(opts.enable_jobs);
}

test "isSafeIdentifier accepts the safe charset and rejects traversal/empty/oversized ids" {
    try std.testing.expect(isSafeIdentifier("j-91"));
    try std.testing.expect(isSafeIdentifier("job_123.retry-2"));
    try std.testing.expect(!isSafeIdentifier(""));
    try std.testing.expect(!isSafeIdentifier("../../etc/passwd"));
    try std.testing.expect(!isSafeIdentifier("a/b"));
    try std.testing.expect(!isSafeIdentifier("has space"));
    try std.testing.expect(!isSafeIdentifier("semi;colon"));
    const too_long = "a" ** 129;
    try std.testing.expect(!isSafeIdentifier(too_long));
    const max_len = "a" ** 128;
    try std.testing.expect(isSafeIdentifier(max_len));
}

test "validateJobEnvelope accepts a well-formed run job" {
    const env: JobEnvelope = .{ .body = .{
        .job_id = "j-91",
        .idem_key = "idem-91",
        .kind = "run",
        .goal = "summarize today's audit anomalies",
        .requested_policy = "readonly",
        .deadline_ts = 1719600060000,
    } };
    try std.testing.expectEqual(@as(?RejectReason, null), validateJobEnvelope(env));
}

test "validateJobEnvelope rejects wrong version, type, and kind as bad_schema" {
    const base: JobEnvelope = .{ .body = .{ .job_id = "j-1", .idem_key = "k-1", .kind = "run", .goal = "do it" } };

    var bad_v = base;
    bad_v.v = 2;
    try std.testing.expectEqual(RejectReason.bad_schema, validateJobEnvelope(bad_v).?);

    var bad_type = base;
    bad_type.type = "status";
    try std.testing.expectEqual(RejectReason.bad_schema, validateJobEnvelope(bad_type).?);

    var bad_kind = base;
    bad_kind.body.kind = "shell";
    try std.testing.expectEqual(RejectReason.bad_schema, validateJobEnvelope(bad_kind).?);
}

test "validateJobEnvelope rejects unsafe job_id/idem_key and an empty goal" {
    const unsafe_job_id: JobEnvelope = .{ .body = .{ .job_id = "../evil", .idem_key = "k-1", .kind = "run", .goal = "x" } };
    try std.testing.expectEqual(RejectReason.bad_schema, validateJobEnvelope(unsafe_job_id).?);

    const unsafe_idem: JobEnvelope = .{ .body = .{ .job_id = "j-1", .idem_key = "has space", .kind = "run", .goal = "x" } };
    try std.testing.expectEqual(RejectReason.bad_schema, validateJobEnvelope(unsafe_idem).?);

    const empty_goal: JobEnvelope = .{ .body = .{ .job_id = "j-1", .idem_key = "k-1", .kind = "run", .goal = "" } };
    try std.testing.expectEqual(RejectReason.bad_schema, validateJobEnvelope(empty_goal).?);
}

test "validateJobEnvelope rejects an unrecognized requested_policy string" {
    const bad_policy: JobEnvelope = .{ .body = .{
        .job_id = "j-1",
        .idem_key = "k-1",
        .kind = "run",
        .goal = "x",
        .requested_policy = "sudo-mode",
    } };
    try std.testing.expectEqual(RejectReason.bad_schema, validateJobEnvelope(bad_policy).?);

    inline for (.{ "guarded", "readonly", "unrestricted" }) |mode| {
        const ok: JobEnvelope = .{ .body = .{ .job_id = "j-1", .idem_key = "k-1", .kind = "run", .goal = "x", .requested_policy = mode } };
        try std.testing.expectEqual(@as(?RejectReason, null), validateJobEnvelope(ok));
    }
}

test "RejectReason.asString matches the documented wire vocabulary (excluding center-only reasons)" {
    try std.testing.expectEqualStrings("bad_schema", RejectReason.bad_schema.asString());
    try std.testing.expectEqualStrings("at_capacity", RejectReason.at_capacity.asString());
}

test "parseLeaseBody parses NDJSON with multiple jobs and skips blank lines" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"v":1,"type":"job","node_id":"n-7a3","sent_ts":1,"body":{"job_id":"j-1","idem_key":"k-1","kind":"run","goal":"first"}}
        \\
        \\{"v":1,"type":"job","node_id":"n-7a3","sent_ts":2,"body":{"job_id":"j-2","idem_key":"k-2","kind":"run","goal":"second"}}
    ;
    const jobs = try parseLeaseBody(arena, body);
    try std.testing.expectEqual(@as(usize, 2), jobs.len);
    try std.testing.expectEqualStrings("j-1", jobs[0].body.job_id);
    try std.testing.expectEqualStrings("second", jobs[1].body.goal);
}

test "parseLeaseBody turns an unparseable line into a synthetic bad_schema envelope" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const jobs = try parseLeaseBody(arena, "not json at all");
    try std.testing.expectEqual(@as(usize, 1), jobs.len);
    try std.testing.expectEqual(RejectReason.bad_schema, validateJobEnvelope(jobs[0]).?);
}

test "parseEffectivePolicyFromStderr extracts the mode from core's unattended clamp message" {
    const stderr = "[scoot] unattended one-shot: effective policy = readonly (edge.max_job_policy ceiling = readonly)\n";
    try std.testing.expectEqualStrings("readonly", parseEffectivePolicyFromStderr(stderr));
}

test "parseEffectivePolicyFromStderr falls back to unknown when the marker is absent" {
    try std.testing.expectEqualStrings("unknown", parseEffectivePolicyFromStderr("some unrelated stderr output\n"));
    try std.testing.expectEqualStrings("unknown", parseEffectivePolicyFromStderr(""));
}

test "jobTimeoutMs prefers the sooner of the configured timeout and the remaining deadline" {
    const io = std.testing.io;
    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();

    // No deadline at all: falls back to the configured timeout untouched.
    try std.testing.expectEqual(@as(u64, 30_000), jobTimeoutMs(io, 30_000, null));

    // Deadline far in the future: configured timeout is still the sooner bound.
    try std.testing.expectEqual(@as(u64, 30_000), jobTimeoutMs(io, 30_000, now_ms + 3_600_000));

    // Deadline sooner than the configured timeout: deadline wins, within a
    // generous tolerance for the wall-clock read between computing `now_ms`
    // above and inside `jobTimeoutMs`.
    const soon = jobTimeoutMs(io, 30_000, now_ms + 1_000);
    try std.testing.expect(soon <= 1_000 and soon > 0);
}

test "jobTimeoutMs floors an already-expired deadline to 1ms instead of 0 or negative" {
    const io = std.testing.io;
    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    try std.testing.expectEqual(@as(u64, 1), jobTimeoutMs(io, 30_000, now_ms - 60_000));
    try std.testing.expectEqual(@as(u64, 1), jobTimeoutMs(io, 30_000, now_ms));
}

test "buildLeaseUrl percent-encodes node_id and appends capacity" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = try buildLeaseUrl(arena, "https://center.example/jobs/lease", "n-7a3", 2);
    try std.testing.expectEqualStrings("https://center.example/jobs/lease?node=n-7a3&capacity=2", plain);

    // A node id with characters outside the unreserved set must come out
    // percent-encoded, never as a raw query/path delimiter.
    const messy = try buildLeaseUrl(arena, "https://center.example/jobs/lease", "n 7a3/&=", 1);
    try std.testing.expectEqualStrings("https://center.example/jobs/lease?node=n%207a3%2F%26%3D&capacity=1", messy);

    // A lease URL that already carries a query string gets `&`, not a second `?`.
    const with_query = try buildLeaseUrl(arena, "https://center.example/jobs/lease?region=us", "n-1", 5);
    try std.testing.expectEqualStrings("https://center.example/jobs/lease?region=us&node=n-1&capacity=5", with_query);
}

test "idem store: append/load round trip finds the most recent record for a key" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const home = "/tmp/scoot_edge_idem_roundtrip";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try appendIdemRecord(arena, io, home, .{ .idem_key = "k-1", .job_id = "j-1", .phase = "done", .session_id = "job-j-1", .ts = 1 }, 500);
    try appendIdemRecord(arena, io, home, .{ .idem_key = "k-2", .job_id = "j-2", .phase = "failed", .ts = 2 }, 500);
    // A second, later outcome for k-1 (e.g. a hypothetical re-run) must shadow the first.
    try appendIdemRecord(arena, io, home, .{ .idem_key = "k-1", .job_id = "j-1", .phase = "failed", .ts = 3 }, 500);

    const records = try loadIdemStore(arena, io, home);
    try std.testing.expectEqual(@as(usize, 3), records.len);

    const latest_k1 = findIdemRecord(records, "k-1").?;
    try std.testing.expectEqualStrings("failed", latest_k1.phase);
    try std.testing.expectEqual(@as(i64, 3), latest_k1.ts);

    const k2 = findIdemRecord(records, "k-2").?;
    try std.testing.expectEqualStrings("failed", k2.phase);

    try std.testing.expectEqual(@as(?IdemRecord, null), findIdemRecord(records, "never-seen"));
}

test "idem store: appendIdemRecord evicts the oldest records once the cap is exceeded" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const home = "/tmp/scoot_edge_idem_eviction";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cap: u32 = 3;
    var n: i64 = 0;
    while (n < 5) : (n += 1) {
        const key = try std.fmt.allocPrint(arena, "k-{d}", .{n});
        try appendIdemRecord(arena, io, home, .{ .idem_key = key, .job_id = key, .phase = "done", .ts = n }, cap);
    }

    const records = try loadIdemStore(arena, io, home);
    try std.testing.expectEqual(@as(usize, cap), records.len);
    // The oldest two (k-0, k-1) must be gone; the newest three must remain, in order.
    try std.testing.expectEqual(@as(?IdemRecord, null), findIdemRecord(records, "k-0"));
    try std.testing.expectEqual(@as(?IdemRecord, null), findIdemRecord(records, "k-1"));
    try std.testing.expect(findIdemRecord(records, "k-2") != null);
    try std.testing.expect(findIdemRecord(records, "k-3") != null);
    try std.testing.expect(findIdemRecord(records, "k-4") != null);
}

test "idem store: loadIdemStore returns empty for a store that was never written" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const records = try loadIdemStore(arena_state.allocator(), io, "/tmp/scoot_edge_idem_never_written");
    try std.testing.expectEqual(@as(usize, 0), records.len);
}

test "appendProvenanceRecord writes a parseable, JSON-escaped provenance line" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const home = "/tmp/scoot_edge_provenance";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A job_id containing quote/newline-like content (as a bad_schema job
    // might carry) must not corrupt the JSONL structure: std.json escapes it.
    try appendProvenanceRecord(arena, io, home, .{
        .ts = 123,
        .node_id = "n-7a3",
        .job_id = "j-\"91\"",
        .idem_key = "k-91",
        .phase = "rejected",
        .reject_reason = "bad_schema",
    });

    const path = try edgeAuditLogPath(arena, home);
    const records = try readJsonLines(ProvenanceRecord, arena, io, path);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("j-\"91\"", records[0].job_id);
    try std.testing.expectEqualStrings("rejected", records[0].phase);
    try std.testing.expectEqualStrings("bad_schema", records[0].reject_reason.?);
}

test "boundedForReport caps oversized identifiers without truncating short ones" {
    try std.testing.expectEqualStrings("short", boundedForReport("short"));
    const long = "a" ** 300;
    try std.testing.expectEqual(@as(usize, 256), boundedForReport(long).len);
}

test {
    std.testing.refAllDecls(@This());
}
