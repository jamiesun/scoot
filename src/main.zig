//! Scoot CLI entrypoint: parses arguments and dispatches to REPL, one-shot eval,
//! daemon, or config commands.
const std = @import("std");
const Io = std.Io;
const scoot = @import("scoot");

var daemon_stop_requested = std.atomic.Value(bool).init(false);

const usage =
    \\Scoot - lightweight AI agent daemon (Daemon / CLI)
    \\
    \\Usage:
    \\  scoot [options] [command]
    \\
    \\Commands:
    \\  repl                 enter interactive REPL (default; /exit quits)
    \\  setup                interactively generate a config directory (quick / multi-instance deploy)
    \\  config               print resolved runtime directory and backend config
    \\  doctor               check local runtime, config, secret source, and audit paths
    \\  policy check <action> <input> [--mode <mode>]
    \\                       explain whether a tool action is allowed under a policy mode
    \\  skills               list discovered skills (name / description / directory)
    \\  skills check [dir]   validate local skill directories; by default scans configured skill paths
    \\  skills pack <dir> [out.tar]
    \\                       validate and export a skill tarball with a .scoot-skill.json review manifest
    \\  wasm-tools check <dir>
    \\                       validate local Wasm tool package boundaries (manifest / policy / schema; does not execute Wasm)
    \\  sessions list        list local persisted sessions
    \\  session show <id>    print one local session transcript as JSONL
    \\  audit show <session-id>
    \\                       print audit events for one session as JSONL
    \\  serve                run a foreground stdio NDJSON app-server protocol
    \\  schedule [list|run]  list / run scheduled jobs (unattended, forced readonly safety mode)
    \\  daemon [run|status|stop]
    \\                       run scheduled jobs as a foreground daemon, recording pid/state and supporting SIGTERM stop
    \\
    \\Options:
    \\  -e, --eval <prompt>  run one goal and exit
    \\  --retries <N>        retry count for transient backend errors in -e mode (default 2, 0 disables retries)
    \\  --scoot-home <dir>   override runtime directory (takes precedence over SCOOT_HOME; useful for test isolation)
    \\  --trace              print execution trace to stderr (-e/--eval and interactive REPL are supported)
    \\  --ticks <N>          schedule run / daemon run exits after N ticks (default 0 means run continuously)
    \\  -h, --help           show this help
    \\  -v, --version        show version
    \\
    \\Runtime directory defaults to ~/.scoot and can be overridden with --scoot-home or SCOOT_HOME.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err_out = &stderr_writer.interface;
    defer err_out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);

    var eval_prompt: ?[]const u8 = null;
    var eval_retries: u32 = default_eval_retries;
    var eval_retries_set = false;
    var scoot_home_override: ?[]const u8 = null;
    var trace = false;
    var cmd_config = false;
    var cmd_doctor = false;
    var cmd_setup = false;
    var cmd_policy_check: ?PolicyCheckCommand = null;
    var cmd_skills: ?SkillsCommand = null;
    var cmd_wasm_tools: ?WasmToolsCommand = null;
    var cmd_sessions: ?SessionsCommand = null;
    var cmd_session: ?SessionCommand = null;
    var cmd_audit: ?AuditCommand = null;
    var cmd_serve = false;
    var cmd_schedule: ?[]const u8 = null; // null means not requested; otherwise list/run.
    var cmd_daemon: ?[]const u8 = null; // null means not requested; otherwise run/status/stop.
    var schedule_ticks: usize = 0; // 0 means run continuously.
    var i: usize = 1; // args[0] is program name.
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "-h") or eql(arg, "--help")) {
            try out.writeAll(usage);
            return;
        } else if (eql(arg, "-v") or eql(arg, "--version")) {
            try out.print("scoot {s}\n", .{scoot.version});
            return;
        } else if (eql(arg, "-e") or eql(arg, "--eval")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("error: -e/--eval requires a prompt argument\n");
                die(out, 2);
            }
            eval_prompt = args[i];
        } else if (eql(arg, "--retries")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("error: --retries requires an integer argument\n");
                die(out, 2);
            }
            eval_retries = std.fmt.parseInt(u32, args[i], 10) catch {
                try out.print("error: --retries argument is not a valid integer: '{s}'\n", .{args[i]});
                die(out, 2);
            };
            eval_retries_set = true;
        } else if (eql(arg, "--scoot-home")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) {
                try out.writeAll("error: --scoot-home requires a directory argument\n");
                die(out, 2);
            }
            scoot_home_override = args[i];
        } else if (eql(arg, "--trace")) {
            trace = true;
        } else if (eql(arg, "--ticks")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("error: --ticks requires an integer argument\n");
                die(out, 2);
            }
            schedule_ticks = std.fmt.parseInt(usize, args[i], 10) catch {
                try out.print("error: --ticks argument is not a valid integer: '{s}'\n", .{args[i]});
                die(out, 2);
            };
        } else if (eql(arg, "setup")) {
            cmd_setup = true;
        } else if (eql(arg, "config")) {
            cmd_config = true;
        } else if (eql(arg, "doctor")) {
            cmd_doctor = true;
        } else if (eql(arg, "policy")) {
            cmd_policy_check = parsePolicyCommand(out, args, &i);
        } else if (eql(arg, "skills")) {
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                if (eql(args[i], "check")) {
                    var target: ?[]const u8 = null;
                    if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                        i += 1;
                        target = args[i];
                    }
                    cmd_skills = .{ .check = target };
                } else if (eql(args[i], "pack")) {
                    if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "-")) {
                        try out.writeAll("error: skills pack requires a skill directory argument\n");
                        die(out, 2);
                    }
                    i += 1;
                    const dir = args[i];
                    var output: ?[]const u8 = null;
                    if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                        i += 1;
                        output = args[i];
                    }
                    cmd_skills = .{ .pack = .{ .dir = dir, .output = output } };
                } else {
                    try out.print("error: unknown skills subcommand '{s}' (available: check / pack)\n", .{args[i]});
                    die(out, 2);
                }
            } else {
                cmd_skills = .list;
            }
        } else if (eql(arg, "wasm-tools")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "-")) {
                try out.writeAll("error: wasm-tools only supports subcommand: check <dir>\n");
                die(out, 2);
            }
            i += 1;
            if (eql(args[i], "check")) {
                if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "-")) {
                    try out.writeAll("error: wasm-tools check requires a tool package directory argument\n");
                    die(out, 2);
                }
                i += 1;
                cmd_wasm_tools = .{ .check = args[i] };
            } else {
                try out.print("error: unknown wasm-tools subcommand '{s}' (available: check)\n", .{args[i]});
                die(out, 2);
            }
        } else if (eql(arg, "sessions")) {
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                if (!eql(args[i], "list")) {
                    try out.print("error: unknown sessions subcommand '{s}' (available: list)\n", .{args[i]});
                    die(out, 2);
                }
            }
            cmd_sessions = .list;
        } else if (eql(arg, "session")) {
            if (i + 2 >= args.len or !eql(args[i + 1], "show")) {
                try out.writeAll("error: session only supports subcommand: show <id>\n");
                die(out, 2);
            }
            i += 2;
            cmd_session = .{ .show = args[i] };
        } else if (eql(arg, "audit")) {
            if (i + 2 >= args.len or !eql(args[i + 1], "show")) {
                try out.writeAll("error: audit only supports subcommand: show <session-id>\n");
                die(out, 2);
            }
            i += 2;
            cmd_audit = .{ .show = args[i] };
        } else if (eql(arg, "serve")) {
            cmd_serve = true;
        } else if (eql(arg, "schedule")) {
            // Optional subaction; default is list, which is read-only. Do not
            // consume the next token if it is an option.
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                cmd_schedule = args[i];
            } else {
                cmd_schedule = "list";
            }
        } else if (eql(arg, "daemon")) {
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                cmd_daemon = args[i];
            } else {
                cmd_daemon = "status";
            }
        } else if (eql(arg, "repl")) {
            // REPL is the default; explicitly accept the command.
        } else {
            try out.print("error: unknown argument '{s}'\n\n", .{arg});
            try out.writeAll(usage);
            die(out, 2);
        }
    }

    // --trace is only meaningful for entries that run the ReACT loop (-e/--eval
    // and default REPL). Reject it for non-agent subcommands instead of silently
    // doing nothing.
    const non_agent_cmd = cmd_config or cmd_doctor or cmd_setup or
        (cmd_policy_check != null) or (cmd_skills != null) or
        (cmd_wasm_tools != null) or (cmd_sessions != null) or
        (cmd_session != null) or (cmd_audit != null) or cmd_serve or
        (cmd_schedule != null) or (cmd_daemon != null);
    if (trace and non_agent_cmd) {
        try out.writeAll("error: --trace is only for -e/--eval or interactive REPL mode\n");
        die(out, 2);
    }
    if (eval_retries_set and eval_prompt == null) {
        try out.writeAll("error: --retries currently only supports -e/--eval one-shot mode\n");
        die(out, 2);
    }

    const dirs = if (scoot_home_override) |home|
        try scoot.paths.Paths.fromHome(arena, home)
    else
        scoot.paths.Paths.resolve(arena, env) catch |err| switch (err) {
            error.NoHomeDir => {
                try out.writeAll("error: cannot determine runtime directory: set --scoot-home, HOME, or SCOOT_HOME\n");
                die(out, 1);
            },
            else => return err,
        };

    // `setup` bootstraps a fresh config directory and must run before the config
    // load/ensure below: it may target a directory that does not exist yet, and
    // it has to work even when the current config file is missing or invalid.
    if (cmd_setup) {
        try runSetup(out, arena, io, env, dirs.home);
        return;
    }

    var load_report: scoot.config.LoadReport = .{};
    var cfg = scoot.config.Config.loadFromDirs(arena, io, dirs, &load_report) catch |err| switch (err) {
        error.InvalidConfig => {
            if (load_report.toml_diag) |d| {
                try out.print(
                    "error: config file parse failed: {s}:{d}:{d} (TOML syntax error near byte {d}).\n",
                    .{ dirs.config_toml_file, d.line, d.col, d.byte },
                );
            } else {
                try out.print(
                    "error: config file parse failed (TOML/JSON syntax or field type mismatch). Check {s} or {s}\n",
                    .{ dirs.config_toml_file, dirs.config_file },
                );
            }
            die(out, 1);
        },
        else => {
            try out.print(
                "error: failed to read config ({s}); checked {s} or {s}\n",
                .{ @errorName(err), dirs.config_toml_file, dirs.config_file },
            );
            die(out, 1);
        },
    };
    // Unknown config keys, often typos, silently fall back to defaults and can
    // quietly reduce safety, e.g. policy misspelled as polcy falling back to
    // guarded. Warn on stderr after successful load so stdout stays scriptable.
    if (load_report.unknown_keys.len > 0) {
        for (load_report.unknown_keys) |k|
            err_out.print("warning: config contains unrecognized key `{s}`, ignored and defaulted (check spelling).\n", .{k}) catch {};
        err_out.flush() catch {};
    }
    if (load_report.deprecated_keys.len > 0) {
        for (load_report.deprecated_keys) |k|
            err_out.print("warning: config key `{s}` was removed and is ignored; Scoot now speaks only the OpenAI Responses API (issue #110).\n", .{k}) catch {};
        err_out.flush() catch {};
    }

    // SCOOT_* env overrides with priority env > config file > defaults. Supports
    // CI/zero-config temporary runs. Plaintext secrets are not read here; they
    // still go through backend.api_key_env, default OPENAI_API_KEY.
    cfg.applyEnvOverrides(arena, env, &load_report) catch |err| {
        try out.print("error: failed to apply environment config overrides ({s})\n", .{@errorName(err)});
        die(out, 1);
    };
    if (load_report.env_warnings.len > 0) {
        for (load_report.env_warnings) |w|
            err_out.print("warning: environment config override ignored: {s}\n", .{w}) catch {};
        err_out.flush() catch {};
    }

    cfg.dirs.ensure(io) catch |err| {
        try out.print("error: failed to create runtime directory ({s}): {s}\n", .{ @errorName(err), cfg.dirs.home });
        die(out, 1);
    };

    if (cmd_config) {
        try out.print("Runtime dir:   {s}\n", .{cfg.dirs.home});
        try out.print("  Config file: {s}\n", .{cfg.active_config_file});
        try out.print("  token:    {s}\n", .{cfg.dirs.token_file});
        try out.print("  skills:   {s}\n", .{cfg.dirs.skills_dir});
        try out.print("  Logs:     {s}\n", .{cfg.dirs.logs_dir});
        try out.print("Backend:       {s} (model={s})\n", .{ cfg.backend.base_url, cfg.backend.model });
        if (cfg.backend.ca_file) |ca| try out.print("  CA:       {s}\n", .{ca});
        try out.print("  timeout:  {d}ms\n", .{cfg.backend.timeout_ms});
        if (cfg.backend.extra_body) |eb| try out.print("  extra fields: {f}\n", .{std.json.fmt(eb, .{})});
        if (cfg.backend.store)
            try out.print("  store: server-side response storage enabled\n", .{});
        try out.print("token source: env[{s}] > file > cmd (plaintext is not stored)\n", .{cfg.backend.api_key_env});
        return;
    }

    if (cmd_doctor) {
        try runDoctor(out, arena, io, env, cfg);
        return;
    }

    if (cmd_policy_check) |pc| {
        try runPolicyCheck(out, arena, io, cfg, pc);
        return;
    }

    if (cmd_skills) |cmd| {
        switch (cmd) {
            .list => try printSkills(out, arena, io, cfg),
            .check => |target| try checkSkills(out, arena, io, cfg, target),
            .pack => |sp| try packSkillCommand(out, arena, io, sp),
        }
        return;
    }

    if (cmd_wasm_tools) |cmd| {
        switch (cmd) {
            .check => |dir| try checkWasmToolPackage(out, arena, io, dir),
        }
        return;
    }

    if (cmd_sessions) |cmd| {
        switch (cmd) {
            .list => try printSessionList(out, arena, io, cfg),
        }
        return;
    }

    if (cmd_session) |cmd| {
        switch (cmd) {
            .show => |id| try printSessionShow(out, arena, io, cfg, id),
        }
        return;
    }

    if (cmd_audit) |cmd| {
        switch (cmd) {
            .show => |session_id| try printAuditShow(out, arena, io, cfg, session_id),
        }
        return;
    }

    if (cmd_serve) {
        validateAgentRuntimeConfig(err_out, cfg);
        try runServe(out, err_out, io, env, cfg, scoot_home_override);
        return;
    }

    if (cmd_schedule) |action| {
        if (eql(action, "list")) {
            try printSchedule(out, cfg);
            return;
        } else if (eql(action, "run")) {
            validateAgentRuntimeConfig(out, cfg);
            try runSchedule(out, arena, io, env, cfg, schedule_ticks);
            return;
        } else {
            try out.print("error: unknown schedule subcommand '{s}' (available: list / run)\n", .{action});
            die(out, 2);
        }
    }

    if (cmd_daemon) |action| {
        if (eql(action, "run")) {
            validateAgentRuntimeConfig(out, cfg);
            try runDaemon(out, arena, io, env, cfg, schedule_ticks);
            return;
        } else if (eql(action, "status")) {
            try printDaemonStatus(out, arena, io, cfg);
            return;
        } else if (eql(action, "stop")) {
            try stopDaemon(out, arena, io, cfg);
            return;
        } else {
            try out.print("error: unknown daemon subcommand '{s}' (available: run / status / stop)\n", .{action});
            die(out, 2);
        }
    }

    if (eval_prompt) |prompt| {
        validateAgentRuntimeConfig(err_out, cfg);
        // In one-shot `-e`, stdout carries only the final answer for scripts and
        // pipes, so warnings/errors go to stderr (issue #23).
        var client = try initBackendClient(err_out, cfg, arena, io, env);

        // Audit trace. If unavailable, degrade to an explicit stderr warning and
        // no trace rather than blocking the run.
        var sink: AuditSink = .{};
        const session_id = try interactiveSessionId(arena, io, "cli");
        const setup = try setupRun(&client, &sink, err_out, arena, io, env, cfg, session_id, scoot.policy.Mode.fromString(cfg.tools.policy));
        var sess = setup.sess;
        var ag = setup.agent;
        try sess.append(arena, .user, prompt);
        if (trace) ag.trace = err_out;
        if (ag.audit) |lg| lg.log(.run, prompt) catch {}; // Run boundary marker with user goal.

        var retries_done: u32 = 0;
        while (true) {
            const reply = ag.run(arena, &sess) catch |err| {
                if (shouldRetryEvalError(err, &client, retries_done, eval_retries)) {
                    retries_done += 1;
                    const delay_ns = evalRetryDelayNs(retries_done);
                    if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
                    try err_out.print(
                        "[scoot] backend transient failure: {s}; retry {d}/{d} in {d}ms.\n",
                        .{ @errorName(err), retries_done, eval_retries, delay_ns / std.time.ns_per_ms },
                    );
                    try printBackendErrorDetail(err_out, &client);
                    try err_out.flush();
                    io.sleep(std.Io.Duration.fromNanoseconds(@intCast(delay_ns)), .awake) catch {};
                    continue;
                }

                if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
                finalizeRun(err_out, io, &sess, cfg.dirs.sessions_dir, &sink);
                try printRunSummary(err_out, arena, "error", &sess, cfg.dirs.sessions_dir, &sink, &client);
                try err_out.print("[scoot] backend call failed: {s}\n", .{@errorName(err)});
                try printBackendErrorDetail(err_out, &client);
                try printBackendFailureHint(err_out, cfg, &client);
                try err_out.flush();
                die(out, 1);
            };
            finalizeRun(err_out, io, &sess, cfg.dirs.sessions_dir, &sink);
            try out.print("{s}\n", .{reply});
            try out.flush();
            try printRunSummary(err_out, arena, "ok", &sess, cfg.dirs.sessions_dir, &sink, &client);
            return;
        }
    }

    validateAgentRuntimeConfig(out, cfg);
    try runRepl(out, err_out, arena, io, env, cfg, trace);
}

fn validateAgentRuntimeConfig(out: *Io.Writer, cfg: scoot.config.Config) void {
    if (cfg.agent.max_turns == 0) {
        out.writeAll("error: agent.max_turns must be greater than 0 for agent runs\n") catch {};
        die(out, 2);
    }
}

fn printBackendErrorDetail(out: *Io.Writer, client: *const scoot.llm.Client) !void {
    const body = client.lastErrorBody();
    if (client.last_error_status == 0 and body.len == 0) return;

    if (client.last_error_status == 0) {
        try out.writeAll("        Backend transport error");
        if (body.len == 0) {
            try out.writeAll(", no detail.\n");
            return;
        }
        try out.print(", detail (first {d} bytes{s}):\n{s}\n", .{
            body.len,
            if (client.last_error_body_truncated) ", truncated" else "",
            body,
        });
        return;
    }

    try out.print("        Backend response status={d}", .{client.last_error_status});
    if (body.len == 0) {
        try out.writeAll(", no response body.\n");
        return;
    }
    try out.print(", body (first {d} bytes{s}):\n{s}\n", .{
        body.len,
        if (client.last_error_body_truncated) ", truncated" else "",
        body,
    });
}

fn printBackendFailureHint(out: *Io.Writer, cfg: scoot.config.Config, client: *const scoot.llm.Client) !void {
    if (client.last_error_status == 0 and client.lastErrorBody().len != 0) {
        try out.print(
            "        Backend {s} (model={s}). Make sure the OpenAI-compatible Responses service is running and reachable.\n",
            .{ cfg.backend.base_url, cfg.backend.model },
        );
        return;
    }
    if (client.last_error_status == 401 or client.last_error_status == 403) {
        try out.print(
            "        Backend {s} (model={s}). Authentication was rejected; set {s} if needed.\n",
            .{ cfg.backend.base_url, cfg.backend.model, cfg.backend.api_key_env },
        );
        return;
    }
    try out.print(
        "        Backend {s} (model={s}). Make sure the OpenAI-compatible Responses service is healthy and accepts this request.\n",
        .{ cfg.backend.base_url, cfg.backend.model },
    );
}

const default_eval_retries: u32 = 2;
const eval_retry_base_delay_ns: u64 = 2 * std.time.ns_per_s;
const eval_retry_max_delay_ns: u64 = 10 * std.time.ns_per_s;

fn shouldRetryEvalError(
    err: anyerror,
    client: *const scoot.llm.Client,
    retries_done: u32,
    max_retries: u32,
) bool {
    if (retries_done >= max_retries) return false;

    if (err == error.BackendError) {
        const status = client.last_error_status;
        return status == 0 or isRetryableBackendStatus(status);
    }

    return isRetryableTransportError(err);
}

fn isRetryableBackendStatus(status: u16) bool {
    return status == 408 or status == 409 or status == 425 or status == 429 or
        status == 500 or status == 502 or status == 503 or status == 504;
}

fn isRetryableTransportError(err: anyerror) bool {
    const name = @errorName(err);
    const retryable = [_][]const u8{
        "ConnectionRefused",
        "ConnectionResetByPeer",
        "ConnectionTimedOut",
        "HttpConnectionClosing",
        "NetworkUnreachable",
        "TemporaryNameServerFailure",
        "TlsInitializationFailed",
    };
    for (retryable) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn evalRetryDelayNs(retry_index: u32) u64 {
    const zero_based = if (retry_index == 0) 0 else retry_index - 1;
    const shift: u6 = @intCast(@min(zero_based, 4));
    const delay = eval_retry_base_delay_ns << shift;
    return @min(delay, eval_retry_max_delay_ns);
}

const PolicyCheckCommand = struct {
    action: []const u8,
    input: []const u8,
    mode: ?[]const u8 = null,
};

const SkillsCommand = union(enum) {
    list,
    check: ?[]const u8,
    pack: SkillPackCommand,
};

const SkillPackCommand = struct {
    dir: []const u8,
    output: ?[]const u8 = null,
};

const WasmToolsCommand = union(enum) {
    check: []const u8,
};

const SessionsCommand = enum {
    list,
};

const SessionCommand = union(enum) {
    show: []const u8,
};

const AuditCommand = union(enum) {
    show: []const u8,
};

fn parsePolicyCommand(out: *Io.Writer, args: []const []const u8, i: *usize) PolicyCheckCommand {
    if (i.* + 1 >= args.len or !eql(args[i.* + 1], "check")) {
        out.writeAll("error: policy only supports subcommand: check <action> <input> [--mode <mode>]\n") catch {};
        die(out, 2);
    }
    if (i.* + 3 >= args.len) {
        out.writeAll("error: policy check requires action and input arguments\n") catch {};
        die(out, 2);
    }

    var pc = PolicyCheckCommand{
        .action = args[i.* + 2],
        .input = args[i.* + 3],
    };
    var j = i.* + 4;
    while (j < args.len) : (j += 1) {
        if (eql(args[j], "--mode")) {
            j += 1;
            if (j >= args.len) {
                out.writeAll("error: --mode requires guarded/readonly/unrestricted argument\n") catch {};
                die(out, 2);
            }
            pc.mode = args[j];
        } else {
            out.print("error: policy check unknown argument '{s}'\n", .{args[j]}) catch {};
            die(out, 2);
        }
    }
    i.* = args.len - 1;
    return pc;
}

fn runPolicyCheck(out: *Io.Writer, arena: std.mem.Allocator, io: std.Io, cfg: scoot.config.Config, pc: PolicyCheckCommand) !void {
    const mode_text = pc.mode orelse cfg.tools.policy;
    const mode = parsePolicyModeStrict(mode_text) orelse {
        try out.print("error: unknown policy mode '{s}' (expected: guarded / readonly / unrestricted)\n", .{mode_text});
        die(out, 2);
    };
    const action = std.meta.stringToEnum(scoot.agent.Action, pc.action) orelse {
        try out.print("error: unknown action '{s}'\n", .{pc.action});
        die(out, 2);
    };
    // Reuse the runtime guard so the preview matches real enforcement exactly:
    // write confinement, SSRF blocking, and the MCP allowlist all apply here
    // because they are evaluated by the same `Agent.guard` path the ReACT loop
    // uses. A second, parallel decision function would silently drift.
    var ag = scoot.agent.Agent.initGuard(io);
    ag.policy_mode = mode;
    ag.confine_writes = cfg.tools.confine_writes;
    ag.block_internal_http = cfg.tools.block_internal_http;
    ag.mcp_servers = cfg.mcp.servers;
    const decision = ag.guard(arena, action, pc.input);

    try out.print("mode={s}\n", .{@tagName(mode)});
    try out.print("action={s}\n", .{@tagName(action)});
    switch (decision) {
        .allow => try out.writeAll("decision=allow\n"),
        .deny => |reason| try out.print("decision=deny\nreason={s}\n", .{reason}),
    }
}

fn parsePolicyModeStrict(s: []const u8) ?scoot.policy.Mode {
    if (eql(s, "guarded")) return .guarded;
    if (eql(s, "readonly")) return .readonly;
    if (eql(s, "unrestricted") or eql(s, "yolo")) return .unrestricted;
    return null;
}

const Doctor = struct {
    out: *Io.Writer,
    failures: usize = 0,
    warnings: usize = 0,

    fn ok(self: *Doctor, name: []const u8, detail: []const u8) !void {
        try self.out.print("OK\t{s}\t{s}\n", .{ name, detail });
    }

    fn info(self: *Doctor, name: []const u8, detail: []const u8) !void {
        try self.out.print("INFO\t{s}\t{s}\n", .{ name, detail });
    }

    fn warn(self: *Doctor, name: []const u8, detail: []const u8) !void {
        self.warnings += 1;
        try self.out.print("WARN\t{s}\t{s}\n", .{ name, detail });
    }

    fn fail(self: *Doctor, name: []const u8, detail: []const u8) !void {
        self.failures += 1;
        try self.out.print("FAIL\t{s}\t{s}\n", .{ name, detail });
    }
};

fn runDoctor(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
) !void {
    var d = Doctor{ .out = out };
    try out.writeAll("scoot doctor\n");

    try d.ok("runtime.home", cfg.dirs.home);
    try checkConfigFile(&d, io, cfg);
    try checkWritablePath(&d, arena, io, "runtime.logs", cfg.dirs.logs_dir);
    try checkWritablePath(&d, arena, io, "runtime.sessions", cfg.dirs.sessions_dir);
    try checkBackendConfig(&d, arena, io, cfg);
    try checkPolicyConfig(&d, arena, cfg);
    try checkAgentConfig(&d, arena, cfg);
    try checkTokenSource(&d, arena, io, env, cfg);
    try checkSkillsConfig(&d, arena, io, cfg);
    try checkScheduleConfig(&d, cfg);

    try d.info("backend.reachability", "skipped; doctor first version does not actively probe the network");
    try out.print("summary\tfailures={d}\twarnings={d}\n", .{ d.failures, d.warnings });
    if (d.failures != 0) die(out, 1);
}

fn checkConfigFile(d: *Doctor, io: std.Io, cfg: scoot.config.Config) !void {
    if (fileExists(io, cfg.active_config_file)) {
        try d.ok("config.file", cfg.active_config_file);
    } else {
        try d.warn("config.file", "no config file found; using built-in defaults");
    }
}

fn checkWritablePath(
    d: *Doctor,
    arena: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    dir: []const u8,
) !void {
    const path = try std.fs.path.join(arena, &.{ dir, ".scoot-doctor-write-test" });
    const cwd = Io.Dir.cwd();
    var f = cwd.createFile(io, path, .{ .truncate = true }) catch |err| {
        try d.fail(name, try std.fmt.allocPrint(arena, "{s}: {s}", .{ dir, @errorName(err) }));
        return;
    };
    f.close(io);
    cwd.deleteFile(io, path) catch {};
    try d.ok(name, dir);
}

fn checkBackendConfig(d: *Doctor, arena: std.mem.Allocator, io: std.Io, cfg: scoot.config.Config) !void {
    if (!startsWithHttp(cfg.backend.base_url)) {
        try d.fail("backend.base_url", "must start with http:// or https://");
    } else {
        try d.ok("backend.base_url", cfg.backend.base_url);
    }
    if (cfg.backend.model.len == 0) {
        try d.fail("backend.model", "model must not be empty");
    } else {
        try d.ok("backend.model", cfg.backend.model);
    }
    if (cfg.backend.timeout_ms == 0) {
        try d.warn("backend.timeout_ms", "0 means no backend hard timeout and is not recommended for agent runs");
    } else {
        try d.ok("backend.timeout_ms", try std.fmt.allocPrint(arena, "{d}ms", .{cfg.backend.timeout_ms}));
    }
    if (cfg.backend.ca_file) |ca| {
        if (fileExists(io, ca)) {
            try d.ok("backend.ca_file", ca);
        } else {
            try d.fail("backend.ca_file", "CA file configured but path is not readable");
        }
    }
}

fn checkPolicyConfig(d: *Doctor, arena: std.mem.Allocator, cfg: scoot.config.Config) !void {
    if (parsePolicyModeStrict(cfg.tools.policy)) |mode| {
        try d.ok("tools.policy", @tagName(mode));
    } else {
        try d.fail("tools.policy", "unknown policy mode; expected guarded / readonly / unrestricted");
    }
    if (cfg.tools.timeout_ms == 0) {
        try d.warn("tools.timeout_ms", "0 means no tool hard timeout and is not recommended for agent runs");
    } else {
        try d.ok("tools.timeout_ms", try std.fmt.allocPrint(arena, "{d}ms", .{cfg.tools.timeout_ms}));
    }

    // issue #50/#113: make effective hardening explicit in doctor so guarded does
    // not appear hardened when guardrails are disabled. block_internal_http and
    // confine_writes both default on.
    const guarded = if (parsePolicyModeStrict(cfg.tools.policy)) |m| m == .guarded else false;
    if (cfg.tools.block_internal_http) {
        try d.ok("tools.block_internal_http", "enabled(rejects loopback/private/link-local/cloud metadata targets to narrow SSRF)");
    } else if (guarded) {
        try d.warn("tools.block_internal_http", "disabled: http_request can access loopback/private/cloud metadata targets; set true unless intentional");
    } else {
        try d.info("tools.block_internal_http", "disabled (current policy mode does not force the network guardrail)");
    }
    if (cfg.tools.confine_writes) {
        try d.ok("tools.confine_writes", "enabled(file_write/file_edit confined to the project root)");
    } else if (guarded) {
        try d.warn("tools.confine_writes", "disabled: file_write/file_edit can target paths outside the project root; set true unless intentional");
    } else {
        try d.info("tools.confine_writes", "disabled (current policy mode does not force write confinement)");
    }
}

fn checkAgentConfig(d: *Doctor, arena: std.mem.Allocator, cfg: scoot.config.Config) !void {
    if (cfg.agent.max_turns == 0) {
        try d.fail("agent.max_turns", "max_turns must be greater than 0");
    } else {
        try d.ok("agent.max_turns", try std.fmt.allocPrint(arena, "{d}", .{cfg.agent.max_turns}));
    }
}

fn checkTokenSource(
    d: *Doctor,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
) !void {
    const token = cfg.resolveToken(arena, io, env) catch |err| switch (err) {
        error.NoApiKey => {
            try d.warn("token", "no token found; ignore for local unauthenticated backends");
            return;
        },
        error.InsecurePermissions => {
            try d.fail("token", "token file permissions are too broad; rejected reading it; run chmod 600");
            return;
        },
        else => {
            try d.warn("token", @errorName(err));
            return;
        },
    };
    try d.ok("token", try std.fmt.allocPrint(arena, "source={s} value={s}", .{
        @tagName(token.source),
        scoot.secret.redact(token.value),
    }));
}

fn checkSkillsConfig(d: *Doctor, arena: std.mem.Allocator, io: std.Io, cfg: scoot.config.Config) !void {
    if (!cfg.skills.enabled) {
        try d.info("skills", "disabled");
        return;
    }
    const paths = cfg.skillPaths(arena) catch |err| {
        try d.fail("skills.paths", @errorName(err));
        return;
    };
    for (paths) |p| {
        if (dirExists(io, p)) {
            try d.ok("skills.path", p);
        } else {
            try d.warn("skills.path", try std.fmt.allocPrint(arena, "{s} does not exist", .{p}));
        }
    }
}

fn checkScheduleConfig(d: *Doctor, cfg: scoot.config.Config) !void {
    if (!cfg.schedule.enabled) {
        try d.info("schedule", "disabled");
        return;
    }
    var invalid: usize = 0;
    for (cfg.schedule.jobs) |job| {
        if (job.toJob() == null) invalid += 1;
    }
    if (invalid == 0) {
        try d.ok("schedule.jobs", "all valid");
    } else {
        try d.warn("schedule.jobs", "invalid job triggers exist and will be skipped at runtime");
    }
}

// --- scoot setup: interactive config directory generator -------------------
//
// Provisions a runtime directory (default ~/.scoot or the resolved SCOOT_HOME)
// in a few prompts: backend base_url/model, the token *source* (env/file/cmd),
// max_turns, and tool policy. The token itself is never written into
// config.toml; only the source is recorded, and a chosen token file is tightened
// to 0600 so secret.zig will accept it. Each generated home is self-contained,
// which is the basis for running multiple isolated instances (and daemons) on
// one host via distinct --scoot-home / SCOOT_HOME values.

const SetupError = error{SetupAborted};

const KeySource = enum { env, file, cmd };

const SetupChoices = struct {
    base_url: []const u8,
    model: []const u8,
    key_source: KeySource,
    api_key_env: []const u8,
    api_key_file: ?[]const u8,
    api_key_cmd: ?[]const u8,
    max_turns: u32,
    policy: []const u8,
};

fn runSetup(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    default_home: []const u8,
) !void {
    var in_buf: [1 << 16]u8 = undefined;
    var ir: Io.File.Reader = .init(.stdin(), io, &in_buf);
    runSetupCore(out, &ir.interface, arena, io, env, default_home) catch |err| switch (err) {
        SetupError.SetupAborted => {
            out.writeAll("\nSetup aborted; no changes were written.\n") catch {};
        },
        else => return err,
    };
}

/// IO-injectable wizard core so tests can drive it with a fixed reader. All
/// filesystem effects happen only after every prompt succeeds, so an aborted
/// run (EOF / Ctrl-D) leaves the target directory untouched.
fn runSetupCore(
    out: *Io.Writer,
    in: *Io.Reader,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    default_home: []const u8,
) !void {
    try out.writeAll(
        \\scoot setup
        \\Interactive configuration generator. Press Enter to accept the [default].
        \\
    );

    const home_in = try promptValue(arena, out, in, "Config directory", default_home);
    const home = try expandTilde(arena, env, home_in);
    const dirs = try scoot.paths.Paths.fromHome(arena, home);

    if (fileExists(io, dirs.config_toml_file)) {
        const question = try std.fmt.allocPrint(arena, "Config already exists at {s}. Overwrite?", .{dirs.config_toml_file});
        if (!try promptYesNo(out, in, question, false)) {
            try out.writeAll("Keeping the existing config; nothing changed.\n");
            return;
        }
    }

    const base_url = try promptValue(arena, out, in, "Backend base_url", "http://127.0.0.1:11434/v1");
    const model = try promptValue(arena, out, in, "Model", "qwen2.5");

    try out.writeAll(
        \\
        \\API key source (the token itself is never written into config.toml):
        \\  1) env  - read from an environment variable (recommended)
        \\  2) file - read from a 0600 token file
        \\  3) cmd  - run a command whose stdout is the token
        \\
    );
    const choice = try promptValue(arena, out, in, "Choose 1/2/3", "1");

    var key_source: KeySource = .env;
    var api_key_env: []const u8 = "OPENAI_API_KEY";
    var api_key_file: ?[]const u8 = null;
    var api_key_cmd: ?[]const u8 = null;
    var token_to_write: ?[]const u8 = null;

    if (eql(choice, "2") or std.ascii.eqlIgnoreCase(choice, "file")) {
        key_source = .file;
        api_key_file = try promptValue(arena, out, in, "Token file path", dirs.token_file);
        const tok = try promptValue(arena, out, in, "Paste token now (blank = create the file later)", "");
        if (tok.len > 0) token_to_write = tok;
    } else if (eql(choice, "3") or std.ascii.eqlIgnoreCase(choice, "cmd")) {
        key_source = .cmd;
        api_key_cmd = try promptNonEmpty(arena, out, in, "Token command (its stdout is the token)");
    } else {
        key_source = .env;
        api_key_env = try promptValue(arena, out, in, "Environment variable name", "OPENAI_API_KEY");
    }

    const max_turns = try promptU32(out, in, "Max ReACT turns", 32);
    const policy = try promptPolicy(arena, out, in);

    const choices = SetupChoices{
        .base_url = base_url,
        .model = model,
        .key_source = key_source,
        .api_key_env = api_key_env,
        .api_key_file = api_key_file,
        .api_key_cmd = api_key_cmd,
        .max_turns = max_turns,
        .policy = policy,
    };

    try dirs.ensure(io);
    if (token_to_write) |tok| try writeTokenFile(io, api_key_file.?, tok);

    const toml = try buildConfigToml(arena, choices);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dirs.config_toml_file, .data = toml });
    Io.Dir.cwd().setFilePermissions(io, dirs.config_toml_file, Io.File.Permissions.fromMode(0o600), .{}) catch {};

    try printSetupSummary(out, dirs, choices, token_to_write != null);
}

/// Expands a leading `~` / `~/` against $HOME so a typed path does not create a
/// literal `~` directory. The `~user` form is intentionally not expanded.
fn expandTilde(arena: std.mem.Allocator, env: *const std.process.Environ.Map, path: []const u8) ![]const u8 {
    if (path.len == 0 or path[0] != '~') return path;
    const home = env.get("HOME") orelse return path;
    if (path.len == 1) return arena.dupe(u8, home);
    if (path[1] == '/') return std.fs.path.join(arena, &.{ home, path[2..] });
    return path;
}

fn writeTokenFile(io: std.Io, path: []const u8, token: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| Io.Dir.cwd().createDirPath(io, parent) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = token });
    // secret.zig refuses to read a token file with any group/other permission bit.
    Io.Dir.cwd().setFilePermissions(io, path, Io.File.Permissions.fromMode(0o600), .{}) catch {};
}

/// Reads one line. Empty input returns an arena copy of `default_val`. EOF aborts
/// the whole wizard. Returned strings are arena-owned because the underlying
/// stdin buffer is reused on the next read.
fn promptValue(
    arena: std.mem.Allocator,
    out: *Io.Writer,
    in: *Io.Reader,
    label: []const u8,
    default_val: []const u8,
) ![]const u8 {
    try out.print("{s} [{s}]: ", .{ label, default_val });
    out.flush() catch {};
    const raw = (readLine(in) catch return SetupError.SetupAborted) orelse return SetupError.SetupAborted;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return arena.dupe(u8, if (trimmed.len == 0) default_val else trimmed);
}

fn promptNonEmpty(
    arena: std.mem.Allocator,
    out: *Io.Writer,
    in: *Io.Reader,
    label: []const u8,
) ![]const u8 {
    while (true) {
        try out.print("{s}: ", .{label});
        out.flush() catch {};
        const raw = (readLine(in) catch return SetupError.SetupAborted) orelse return SetupError.SetupAborted;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len != 0) return arena.dupe(u8, trimmed);
        try out.writeAll("  (a value is required)\n");
    }
}

fn promptYesNo(out: *Io.Writer, in: *Io.Reader, question: []const u8, default_yes: bool) !bool {
    try out.writeAll(question);
    try out.writeAll(if (default_yes) " [Y/n]: " else " [y/N]: ");
    out.flush() catch {};
    const raw = (readLine(in) catch return SetupError.SetupAborted) orelse return SetupError.SetupAborted;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return default_yes;
    return trimmed[0] == 'y' or trimmed[0] == 'Y';
}

fn promptU32(out: *Io.Writer, in: *Io.Reader, label: []const u8, default_val: u32) !u32 {
    while (true) {
        try out.print("{s} [{d}]: ", .{ label, default_val });
        out.flush() catch {};
        const raw = (readLine(in) catch return SetupError.SetupAborted) orelse return SetupError.SetupAborted;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return default_val;
        const v = std.fmt.parseInt(u32, trimmed, 10) catch {
            try out.writeAll("  (enter a whole number)\n");
            continue;
        };
        if (v == 0) {
            try out.writeAll("  (must be greater than 0)\n");
            continue;
        }
        return v;
    }
}

fn promptPolicy(arena: std.mem.Allocator, out: *Io.Writer, in: *Io.Reader) ![]const u8 {
    while (true) {
        const v = try promptValue(arena, out, in, "Tool policy (guarded/readonly/unrestricted)", "guarded");
        if (eql(v, "guarded") or eql(v, "readonly") or eql(v, "unrestricted")) return v;
        try out.writeAll("  (choose guarded, readonly, or unrestricted)\n");
    }
}

fn writeTomlBasicString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn emitTomlKV(w: *Io.Writer, key: []const u8, value: []const u8) !void {
    try w.writeAll(key);
    try w.writeAll(" = ");
    try writeTomlBasicString(w, value);
    try w.writeByte('\n');
}

fn buildConfigToml(arena: std.mem.Allocator, c: SetupChoices) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;

    try w.writeAll(
        \\# Scoot configuration generated by `scoot setup`.
        \\# Loading order: config.toml first, then config.json. Missing fields fall back to
        \\# built-in defaults. Keep secrets out of this file; configure only the token source
        \\# via api_key_env / api_key_file / api_key_cmd. See config.example.toml for all options.
    );
    try w.writeAll("\n\n[backend]\n");
    try emitTomlKV(w, "base_url", c.base_url);
    try emitTomlKV(w, "model", c.model);
    try w.writeAll("timeout_ms = 120000\n");
    switch (c.key_source) {
        .env => try emitTomlKV(w, "api_key_env", c.api_key_env),
        .file => {
            try w.writeAll("# Token is read from this file (must be 0600); env OPENAI_API_KEY is still tried first.\n");
            try emitTomlKV(w, "api_key_file", c.api_key_file.?);
        },
        .cmd => {
            try w.writeAll("# Token is read from this command's stdout; env OPENAI_API_KEY is still tried first.\n");
            try emitTomlKV(w, "api_key_cmd", c.api_key_cmd.?);
        },
    }
    try w.writeAll("\n[agent]\n");
    try w.print("max_turns = {d}\n", .{c.max_turns});
    try w.writeAll("\n[tools]\n");
    try emitTomlKV(w, "policy", c.policy);
    try w.writeAll("\n[audit]\nlevel = \"info\"\nto_file = true\n");

    return aw.written();
}

fn printSetupSummary(out: *Io.Writer, dirs: scoot.paths.Paths, c: SetupChoices, wrote_token: bool) !void {
    try out.print(
        \\
        \\Done. Wrote {s}
        \\  base_url : {s}
        \\  model    : {s}
        \\  policy   : {s}
        \\  max_turns: {d}
        \\
    , .{ dirs.config_toml_file, c.base_url, c.model, c.policy, c.max_turns });

    switch (c.key_source) {
        .env => try out.print("  token    : from env ${s} (export it before running)\n", .{c.api_key_env}),
        .file => if (wrote_token)
            try out.print("  token    : written to {s} (0600)\n", .{c.api_key_file.?})
        else
            try out.print("  token    : will be read from {s}; create it as a 0600 file\n", .{c.api_key_file.?}),
        .cmd => try out.print("  token    : from command `{s}`\n", .{c.api_key_cmd.?}),
    }

    try out.print(
        \\
        \\Created runtime tree under {s} (skills/, logs/, state/sessions/).
        \\Edit {s} to tune advanced options (see config.example.toml).
        \\
        \\Use this instance with either:
        \\  scoot --scoot-home {s}
        \\  SCOOT_HOME={s} scoot daemon run
        \\
    , .{ dirs.home, dirs.config_toml_file, dirs.home, dirs.home });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn startsWithHttp(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ANSI terminal sequences - no TUI dependency, just raw escape codes (like Python 3.13+ REPL).
const ansi = struct {
    const reset: []const u8 = "\x1b[0m";
    const bold: []const u8 = "\x1b[1m";
    const dim: []const u8 = "\x1b[2m";
    const red: []const u8 = "\x1b[31m";
    const green: []const u8 = "\x1b[32m";
    const cyan: []const u8 = "\x1b[36m";
    const bold_green: []const u8 = "\x1b[1;32m";
    const bold_red: []const u8 = "\x1b[1;31m";
};

const repl_hint = "Enter a goal and press return to run. Use \"/help\" for commands and \"/exit\" to quit.\n";

const repl_help =
    \\Scoot runs your goal through a thought-action-observation loop.
    \\
    \\  /help         show this help
    \\  /exit, /quit  exit; the session is persisted automatically
    \\
;

/// Discovers skills and injects the manifest into session system context.
/// Progressive disclosure injects only name, description, and path. Skills are
/// optional; discovery failure or no skills silently skips without blocking main
/// flow or polluting scriptable `-e` output. Registry allocation uses `arena` and
/// is reclaimed with process exit.
fn injectSkills(
    warn: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
    sess: *scoot.session.Session,
) []const scoot.agent.SkillRef {
    if (!cfg.skills.enabled) return &.{};
    const paths = cfg.skillPaths(arena) catch return &.{};
    var reg: scoot.skill.Registry = .{};
    reg.discoverAll(arena, io, paths) catch |err| {
        warn.print("[scoot] skill discovery failed ({s}); skipped skill loading.\n", .{@errorName(err)}) catch {};
        return &.{};
    };
    if (reg.count() == 0) return &.{};
    const text = reg.manifest(arena) catch return &.{};
    sess.append(arena, .system, text) catch {};
    // Map discovered skills to agent name->dir handles so native `skill` can
    // read instructions/resources by name. Registry strings are arena-owned for
    // this run, so no deinit is needed.
    const refs = arena.alloc(scoot.agent.SkillRef, reg.count()) catch return &.{};
    for (reg.skills.items, 0..) |s, i| refs[i] = .{ .name = s.name, .dir = s.dir };
    return refs;
}

/// `scoot skills`: lists discovered skills from all search paths.
fn printSkills(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
) !void {
    const paths = try cfg.skillPaths(arena);
    try out.writeAll("Skill search paths:\n");
    for (paths) |p| try out.print("  {s}\n", .{p});

    if (!cfg.skills.enabled) {
        try out.writeAll("\nSkill support is disabled in config (skills.enabled=false).\n");
        return;
    }

    var reg: scoot.skill.Registry = .{};
    try reg.discoverAll(arena, io, paths);
    if (reg.count() == 0) {
        try out.writeAll("\nNo skills found. Create <skill-name>/SKILL.md with front matter under a search path.\n");
        return;
    }
    try out.print("\nDiscovered {d} skills:\n", .{reg.count()});
    for (reg.skills.items) |s| {
        try out.print("  - {s}:{s}\n    {s}\n", .{ s.name, s.description, s.dir });
        try printSkillMetadata(out, s.capabilities, s.allowed_tools, s.scope, "    ");
    }
}

const SkillCheckSummary = struct {
    checked: usize = 0,
    failures: usize = 0,
    warnings: usize = 0,
};

/// `scoot skills check [dir]`: read-only validation of skill structure. It only
/// parses SKILL.md and never executes scripts.
fn checkSkills(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
    target: ?[]const u8,
) !void {
    var summary: SkillCheckSummary = .{};
    try out.writeAll("Skill validation:\n");

    if (target) |dir| {
        try checkOneSkill(out, arena, io, dir, &summary);
    } else {
        if (!cfg.skills.enabled) {
            summary.warnings += 1;
            try out.writeAll("INFO skills disabled by config (skills.enabled=false)\n");
        } else {
            const paths = try cfg.skillPaths(arena);
            for (paths) |root| {
                try scanSkillRoot(out, arena, io, root, &summary);
            }
            if (summary.checked == 0) {
                summary.warnings += 1;
                try out.writeAll("WARN no skill directories with SKILL.md were found in configured search paths\n");
            }
        }
    }

    try out.print("summary checked={d} failures={d} warnings={d}\n", .{
        summary.checked,
        summary.failures,
        summary.warnings,
    });
    if (summary.failures > 0) die(out, 1);
}

fn scanSkillRoot(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    summary: *SkillCheckSummary,
) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            summary.warnings += 1;
            try out.print("WARN {s}: search path not found\n", .{root});
            return;
        },
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const candidate = try std.fs.path.join(arena, &.{ root, entry.name });
        const md_path = try std.fs.path.join(arena, &.{ candidate, "SKILL.md" });
        if (!fileExists(io, md_path)) continue;
        try checkOneSkill(out, arena, io, candidate, summary);
    }
}

fn checkOneSkill(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    summary: *SkillCheckSummary,
) !void {
    summary.checked += 1;
    const res = try scoot.skill.validateDir(arena, io, dir);
    switch (res) {
        .valid => |meta| {
            try out.print("OK {s} name={s} description={s}\n", .{
                dir,
                meta.name,
                meta.description,
            });
            try printSkillMetadata(out, meta.capabilities, meta.allowed_tools, meta.scope, "");
        },
        .invalid => |msg| {
            summary.failures += 1;
            try out.print("FAIL {s}: {s}\n", .{ dir, msg });
        },
    }
}

fn printSkillMetadata(
    out: *Io.Writer,
    capabilities: []const u8,
    allowed_tools: []const u8,
    scope: []const u8,
    prefix: []const u8,
) !void {
    if (capabilities.len != 0) try out.print("{s}capabilities={s}\n", .{ prefix, capabilities });
    if (allowed_tools.len != 0) try out.print("{s}allowed_tools={s}\n", .{ prefix, allowed_tools });
    if (scope.len != 0) try out.print("{s}scope={s}\n", .{ prefix, scope });
}

/// `scoot wasm-tools check <dir>`: read-only validation of Wasm tool package
/// boundaries, without loading or executing Wasm.
fn checkWasmToolPackage(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
) !void {
    const res = try scoot.wasm_tool.validatePackage(arena, io, dir);
    switch (res) {
        .valid => |summary| {
            try out.print("OK {s} name={s} entry={s}\n", .{ dir, summary.name, summary.entry });
            try out.print("description={s}\n", .{summary.description});
            try out.print("component={s}\n", .{summary.component});
            try out.print("component_bytecode sections={d} types={d} imports={d} functions={d} codes={d} exports={d} data={d}\n", .{
                summary.component_bytecode.sections,
                summary.component_bytecode.types,
                summary.component_bytecode.imported_functions,
                summary.component_bytecode.functions,
                summary.component_bytecode.codes,
                summary.component_bytecode.exports,
                summary.component_bytecode.data_segments,
            });
            try out.print("input_schema={s}\n", .{summary.input_schema});
            try out.print("output_schema={s}\n", .{summary.output_schema});
            try out.writeAll("capabilities=");
            try printList(out, summary.capabilities);
            try out.writeAll("\npolicy_capabilities=");
            try printList(out, summary.policy_capabilities);
            try out.writeAll("\n");
        },
        .invalid => |msg| {
            try out.print("FAIL {s}: {s}\n", .{ dir, msg });
            die(out, 1);
        },
    }
}

fn printSessionList(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
) !void {
    const sessions = try scoot.session.list(arena, io, cfg.dirs.sessions_dir);
    try out.print("Sessions: {d} ({s})\n", .{ sessions.len, cfg.dirs.sessions_dir });
    for (sessions) |s| {
        try out.print("  - {s}  mtime_ms={d}  messages={d}", .{ s.id, s.mtime_ms, s.message_count });
        if (s.first_user_summary.len != 0) try out.print("  first_user={s}", .{s.first_user_summary});
        try out.writeByte('\n');
    }
}

fn printSessionShow(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
    id: []const u8,
) !void {
    const loaded = scoot.session.loadById(arena, io, cfg.dirs.sessions_dir, id) catch |err| switch (err) {
        error.InvalidSessionId => {
            try out.print("error: invalid session id '{s}'\n", .{id});
            die(out, 2);
        },
        error.SessionNotFound => {
            try out.print("error: session not found: {s}\n", .{id});
            die(out, 1);
        },
        error.InvalidSessionLog => {
            try out.print("error: session log is not valid JSONL: {s}\n", .{id});
            die(out, 1);
        },
        else => return err,
    };
    try scoot.session.writeMessagesJsonl(out, loaded.messages);
}

fn printAuditShow(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
    session_id: []const u8,
) !void {
    const events = scoot.audit.querySession(arena, io, cfg.dirs.logs_dir, session_id) catch |err| switch (err) {
        error.InvalidAuditLog => {
            try out.print("error: audit log is not valid JSONL: {s}/audit.jsonl\n", .{cfg.dirs.logs_dir});
            die(out, 1);
        },
        else => return err,
    };
    for (events) |ev| try scoot.audit.writeEventJsonl(out, ev);
}

const ServeRequest = struct {
    id: ?std.json.Value = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

fn runServe(
    out: *Io.Writer,
    err_out: *Io.Writer,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
    scoot_home_override: ?[]const u8,
) !void {
    const rt = scoot.api.start(std.heap.page_allocator, io, .{
        .env = env,
        .scoot_home = scoot_home_override,
    }) catch |err| {
        try err_out.print("[scoot] serve runtime start failed: {s}\n", .{@errorName(err)});
        try err_out.flush();
        die(out, 1);
    };
    defer scoot.api.stop(rt);

    var in_buf: [1 << 16]u8 = undefined;
    var ir: Io.File.Reader = .init(.stdin(), io, &in_buf);
    try serveLoop(out, &ir.interface, rt, io, cfg);
}

fn serveLoop(
    out: *Io.Writer,
    in: *Io.Reader,
    rt: *scoot.api.Runtime,
    io: std.Io,
    cfg: scoot.config.Config,
) !void {
    while (true) {
        const raw = (readLine(in) catch |err| {
            try writeServeError(out, null, "read_error", @errorName(err));
            try out.flush();
            return;
        }) orelse return;
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;

        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        try handleServeLine(out, arena, rt, io, cfg, line);
        try out.flush();
    }
}

fn handleServeLine(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    rt: *scoot.api.Runtime,
    io: std.Io,
    cfg: scoot.config.Config,
    line: []const u8,
) !void {
    const req = std.json.parseFromSliceLeaky(ServeRequest, arena, line, .{ .ignore_unknown_fields = true }) catch {
        try writeServeError(out, null, "bad_json", "request must be a JSON object with id, method, and optional params");
        return;
    };
    const id = req.id;
    if (req.method.len == 0) {
        try writeServeError(out, id, "invalid_request", "method is required");
        return;
    }

    if (eql(req.method, "run")) {
        const goal = serveParamString(req.params, "goal") orelse {
            try writeServeError(out, id, "invalid_params", "run requires params.goal string");
            return;
        };
        const result = scoot.api.runDetailedWithOptions(rt, goal, .{
            .result_allocator = arena,
            .max_retries = default_eval_retries,
        }) catch |err| {
            try writeServeRunError(out, id, rt, err);
            return;
        };
        try writeServeRunResult(out, id, result);
    } else if (eql(req.method, "session.list")) {
        const sessions = scoot.session.list(arena, io, cfg.dirs.sessions_dir) catch |err| {
            try writeServeError(out, id, "session_list_failed", @errorName(err));
            return;
        };
        try writeServeSessionList(out, id, sessions);
    } else if (eql(req.method, "session.get")) {
        const session_id = serveParamString(req.params, "id") orelse {
            try writeServeError(out, id, "invalid_params", "session.get requires params.id string");
            return;
        };
        const loaded = scoot.session.loadById(arena, io, cfg.dirs.sessions_dir, session_id) catch |err| {
            try writeServeError(out, id, serveReadErrorCode(err), @errorName(err));
            return;
        };
        try writeServeSessionGet(out, id, loaded);
    } else if (eql(req.method, "audit.query")) {
        const session_id = serveParamString(req.params, "session_id") orelse {
            try writeServeError(out, id, "invalid_params", "audit.query requires params.session_id string");
            return;
        };
        const events = scoot.audit.querySession(arena, io, cfg.dirs.logs_dir, session_id) catch |err| {
            try writeServeError(out, id, "audit_query_failed", @errorName(err));
            return;
        };
        try writeServeAuditQuery(out, id, session_id, events);
    } else if (eql(req.method, "run.stream")) {
        try writeServeError(out, id, "not_implemented", "run.stream is not implemented in this serial stdio protocol version");
    } else {
        try writeServeError(out, id, "method_not_found", "unknown serve method");
    }
}

fn serveParamString(params: ?std.json.Value, name: []const u8) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const v = p.object.get(name) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn serveReadErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidSessionId => "invalid_params",
        error.SessionNotFound => "not_found",
        else => "session_get_failed",
    };
}

fn writeServeRunResult(out: *Io.Writer, id: ?std.json.Value, result: scoot.api.RunResult) !void {
    try writeServeResultPrefix(out, id);
    try out.writeAll("{\"session_id\":");
    try scoot.jsonio.writeString(out, result.session_id);
    try out.writeAll(",\"reply\":");
    try scoot.jsonio.writeString(out, result.reply);
    try out.writeAll("}}\n");
}

fn writeServeSessionList(out: *Io.Writer, id: ?std.json.Value, sessions: []const scoot.session.Summary) !void {
    try writeServeResultPrefix(out, id);
    try out.writeAll("{\"sessions\":[");
    for (sessions, 0..) |s, idx| {
        if (idx != 0) try out.writeByte(',');
        try out.writeAll("{\"id\":");
        try scoot.jsonio.writeString(out, s.id);
        try out.print(",\"mtime_ms\":{d},\"message_count\":{d},\"first_user_summary\":", .{ s.mtime_ms, s.message_count });
        try scoot.jsonio.writeString(out, s.first_user_summary);
        try out.writeByte('}');
    }
    try out.writeAll("]}}\n");
}

fn writeServeSessionGet(out: *Io.Writer, id: ?std.json.Value, loaded: scoot.session.Loaded) !void {
    try writeServeResultPrefix(out, id);
    try out.writeAll("{\"id\":");
    try scoot.jsonio.writeString(out, loaded.id);
    try out.writeAll(",\"messages\":[");
    for (loaded.messages, 0..) |m, idx| {
        if (idx != 0) try out.writeByte(',');
        try out.writeAll("{\"role\":\"");
        try out.writeAll(@tagName(m.role));
        try out.writeAll("\",\"content\":");
        try scoot.jsonio.writeString(out, m.content);
        try out.writeByte('}');
    }
    try out.writeAll("]}}\n");
}

fn writeServeAuditQuery(out: *Io.Writer, id: ?std.json.Value, session_id: []const u8, events: []const scoot.audit.Event) !void {
    try writeServeResultPrefix(out, id);
    try out.writeAll("{\"session_id\":");
    try scoot.jsonio.writeString(out, session_id);
    try out.writeAll(",\"events\":[");
    for (events, 0..) |ev, idx| {
        if (idx != 0) try out.writeByte(',');
        try out.print("{{\"seq\":{d},\"ts\":{d},\"session_id\":", .{ ev.seq, ev.ts });
        try scoot.jsonio.writeString(out, ev.session_id);
        if (ev.run_id) |run_id| {
            try out.writeAll(",\"run_id\":");
            try scoot.jsonio.writeString(out, run_id);
        }
        try out.writeAll(",\"kind\":\"");
        try out.writeAll(@tagName(ev.kind));
        try out.writeAll("\",\"msg\":");
        try scoot.jsonio.writeString(out, ev.msg);
        try out.writeByte('}');
    }
    try out.writeAll("]}}\n");
}

fn writeServeResultPrefix(out: *Io.Writer, id: ?std.json.Value) !void {
    try out.writeAll("{\"id\":");
    try writeServeId(out, id);
    try out.writeAll(",\"ok\":true,\"result\":");
}

fn writeServeError(out: *Io.Writer, id: ?std.json.Value, code: []const u8, message: []const u8) !void {
    try out.writeAll("{\"id\":");
    try writeServeId(out, id);
    try out.writeAll(",\"ok\":false,\"error\":{\"code\":");
    try scoot.jsonio.writeString(out, code);
    try out.writeAll(",\"message\":");
    try scoot.jsonio.writeString(out, message);
    try out.writeAll("}}\n");
}

fn writeServeRunError(out: *Io.Writer, id: ?std.json.Value, rt: *scoot.api.Runtime, err: anyerror) !void {
    try out.writeAll("{\"id\":");
    try writeServeId(out, id);
    try out.writeAll(",\"ok\":false,\"error\":{\"code\":\"run_failed\",\"message\":");
    try scoot.jsonio.writeString(out, @errorName(err));
    const status = scoot.api.lastBackendStatus(rt);
    if (status != 0) try out.print(",\"backend_status\":{d}", .{status});
    const detail = scoot.api.lastBackendErrorBody(rt);
    if (detail.len != 0) {
        try out.writeAll(",\"backend_detail\":");
        try scoot.jsonio.writeString(out, detail);
        if (scoot.api.lastBackendErrorTruncated(rt))
            try out.writeAll(",\"backend_detail_truncated\":true");
    }
    try out.writeAll("}}\n");
}

fn writeServeId(out: *Io.Writer, id: ?std.json.Value) !void {
    if (id) |value| {
        try out.print("{f}", .{std.json.fmt(value, .{})});
    } else {
        try out.writeAll("null");
    }
}

fn printList(out: *Io.Writer, items: []const []const u8) !void {
    for (items, 0..) |item, idx| {
        if (idx != 0) try out.writeAll(",");
        try out.writeAll(item);
    }
}

const SkillPackFile = struct {
    rel: []const u8,
    size: u64,
};

const SkillPackResult = struct {
    name: []const u8,
    output: []const u8,
    file_count: usize,
    total_bytes: u64,
    skipped_hidden: usize,
};

/// `scoot skills pack <dir> [out.tar]`: validates first, then exports an
/// auditable tar package. Reads the skill directory only and executes no scripts.
fn packSkillCommand(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cmd: SkillPackCommand,
) !void {
    const result = packSkill(arena, io, cmd.dir, cmd.output) catch |err| switch (err) {
        error.InvalidSkill => {
            try out.print("FAIL {s}: invalid skill; run `scoot skills check {s}` for details\n", .{ cmd.dir, cmd.dir });
            die(out, 1);
        },
        error.PathAlreadyExists => {
            const output = cmd.output orelse "default output file";
            try out.print("error: output file already exists: {s}\n", .{output});
            die(out, 1);
        },
        error.UnsupportedSkillPackageEntry => {
            try out.writeAll("error: skill directory contains unsupported file types such as symlinks or device files\n");
            die(out, 1);
        },
        else => return err,
    };

    try out.print(
        "OK packed {s} -> {s}\nfiles={d} bytes={d} skipped_hidden={d}\n",
        .{ result.name, result.output, result.file_count, result.total_bytes, result.skipped_hidden },
    );
}

fn packSkill(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    output_override: ?[]const u8,
) !SkillPackResult {
    const validation = try scoot.skill.validateDir(arena, io, dir);
    const meta = switch (validation) {
        .valid => |m| m,
        .invalid => return error.InvalidSkill,
    };

    var files: std.ArrayList(SkillPackFile) = .empty;
    var skipped_hidden: usize = 0;
    try collectSkillPackFiles(arena, io, dir, "", &files, &skipped_hidden);
    std.mem.sort(SkillPackFile, files.items, {}, struct {
        fn lessThan(_: void, a: SkillPackFile, b: SkillPackFile) bool {
            return std.mem.lessThan(u8, a.rel, b.rel);
        }
    }.lessThan);

    var total_bytes: u64 = 0;
    for (files.items) |f| total_bytes += f.size;

    const output = output_override orelse try std.fmt.allocPrint(arena, "{s}.scoot-skill.tar", .{meta.name});
    const manifest = try skillPackManifest(arena, meta, files.items, total_bytes, skipped_hidden);

    const cwd = Io.Dir.cwd();
    var archive = try cwd.createFile(io, output, .{ .truncate = false, .exclusive = true });
    defer archive.close(io);
    var archive_buf: [8192]u8 = undefined;
    var fw = archive.writer(io, &archive_buf);
    const aw = &fw.interface;

    var tw: std.tar.Writer = .{ .underlying_writer = aw };
    try tw.setRoot(meta.name);
    try tw.writeFileBytes(".scoot-skill.json", manifest, .{ .mode = 0o644, .mtime = 0 });
    for (files.items) |f| {
        const full = try std.fs.path.join(arena, &.{ dir, f.rel });
        const content = try cwd.readFileAlloc(io, full, arena, .limited(8 << 20));
        try tw.writeFileBytes(f.rel, content, .{ .mode = 0o644, .mtime = 0 });
    }
    try tw.finishPedantically();
    try aw.flush();

    return .{
        .name = meta.name,
        .output = output,
        .file_count = files.items.len,
        .total_bytes = total_bytes,
        .skipped_hidden = skipped_hidden,
    };
}

fn collectSkillPackFiles(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    rel: []const u8,
    files: *std.ArrayList(SkillPackFile),
    skipped_hidden: *usize,
) !void {
    const cwd = Io.Dir.cwd();
    const here = if (rel.len == 0) root else try std.fs.path.join(arena, &.{ root, rel });
    var dir = try cwd.openDir(io, here, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') {
            skipped_hidden.* += 1;
            continue;
        }
        const child_rel = if (rel.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, entry.name });

        switch (entry.kind) {
            .directory => try collectSkillPackFiles(arena, io, root, child_rel, files, skipped_hidden),
            .file => {
                const full = try std.fs.path.join(arena, &.{ root, child_rel });
                const stat = try cwd.statFile(io, full, .{});
                try files.append(arena, .{ .rel = child_rel, .size = stat.size });
            },
            else => return error.UnsupportedSkillPackageEntry,
        }
    }
}

const SkillPackManifestFile = struct {
    path: []const u8,
    size: u64,
};

const SkillPackManifest = struct {
    format: []const u8 = "scoot.skill.package.v1",
    name: []const u8,
    description: []const u8,
    capabilities: []const []const u8,
    allowed_tools: []const []const u8,
    scope: []const u8,
    files: []const SkillPackManifestFile,
    file_count: usize,
    total_bytes: u64,
    skipped_hidden: usize,
    policy_note: []const u8 = "Skill scripts and commands do not bypass Scoot policy gates; reading a skill's instructions is a native, audited read-only capability confined to the skill directory.",
};

fn skillPackManifest(
    arena: std.mem.Allocator,
    meta: scoot.skill.Meta,
    files: []const SkillPackFile,
    total_bytes: u64,
    skipped_hidden: usize,
) ![]const u8 {
    const manifest_files = try arena.alloc(SkillPackManifestFile, files.len);
    for (files, 0..) |f, i| manifest_files[i] = .{ .path = f.rel, .size = f.size };
    const capabilities = try scoot.skill.parseInlineList(arena, meta.capabilities);
    const allowed_tools = try scoot.skill.parseInlineList(arena, meta.allowed_tools);

    var aw = std.Io.Writer.Allocating.init(arena);
    try std.json.Stringify.value(SkillPackManifest{
        .name = meta.name,
        .description = meta.description,
        .capabilities = capabilities,
        .allowed_tools = allowed_tools,
        .scope = meta.scope,
        .files = manifest_files,
        .file_count = files.len,
        .total_bytes = total_bytes,
        .skipped_hidden = skipped_hidden,
    }, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    return aw.written();
}

/// Renders a trigger as a human-readable description for `schedule list`.
fn triggerLabel(buf: []u8, trig: scoot.schedule.Trigger) []const u8 {
    return switch (trig) {
        .every_sec => |s| std.fmt.bufPrint(buf, "every {d}s", .{s}) catch "every",
        .at_unix => |t| std.fmt.bufPrint(buf, "@{d}", .{t}) catch "at",
        .cron => |c| std.fmt.bufPrint(buf, "cron '{s}'", .{c}) catch "cron",
    };
}

/// `scoot schedule list`: shows schedule enablement, poll interval, and jobs,
/// including effective execution mode and invalid markers. Read-only and
/// side-effect-free so users can review safety mode and triggers before `run`.
fn printSchedule(out: *Io.Writer, cfg: scoot.config.Config) !void {
    const sc = cfg.schedule;
    try out.print("Schedule: {s} (poll={d}ms, jobs={d})\n", .{
        if (sc.enabled) "enabled" else "disabled (schedule.enabled=false)",
        sc.poll_ms,
        sc.jobs.len,
    });
    if (sc.jobs.len == 0) {
        try out.writeAll("  (no jobs; configure schedule.jobs in the config file)\n");
        return;
    }
    var tbuf: [128]u8 = undefined;
    for (sc.jobs) |jc| {
        if (jc.toJob()) |job| {
            const eff = job.effectiveMode();
            const coerced = if (eff != job.mode) " (coerced)" else "";
            try out.print("  - {s}  [{s}]  mode={s}{s}  goal={s}\n", .{
                jc.id, triggerLabel(&tbuf, job.trigger), @tagName(eff), coerced, job.goal,
            });
        } else {
            try out.print("  - {s}  WARN invalid trigger (exactly one of every_sec/at_unix/cron must be set); will be skipped at runtime\n", .{jc.id});
        }
    }
    if (!sc.enabled) {
        try out.writeAll("\nHint: `scoot schedule run` requires schedule.enabled=true in the config file.\n");
    }
}

/// Single-job runtime context: everything needed to run one job plus a resettable
/// arena. The scheduler only decides due-ness; actual execution is injected via
/// `runJob`, decoupling agent dependencies.
const RunCtx = struct {
    out: *Io.Writer,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
    client: *scoot.llm.Client,
    /// Each job allocates scratch here, then resets with retain_capacity.
    job_arena: *std.heap.ArenaAllocator,

    /// schedule.Scheduler.RunFn callback: runs one due job. Never throws because
    /// it returns void; single-job failure is audited/printed and the daemon loop continues.
    fn runJob(ctx: *anyopaque, job: *scoot.schedule.Job) void {
        const self: *RunCtx = @ptrCast(@alignCast(ctx));
        const a = self.job_arena.allocator();
        defer _ = self.job_arena.reset(.retain_capacity); // Reclaim this turn's scratch.

        // Unattended execution forces the safe mode: guarded tripwire is
        // meaningless unattended, so correct it to readonly.
        const eff = job.effectiveMode();

        const sid = std.fmt.allocPrint(a, "job-{s}", .{job.id}) catch return;
        // schedule/daemon stdout is the run log, so degradation warnings go to self.out.
        var sink: AuditSink = .{};
        const setup = setupRun(self.client, &sink, self.out, a, self.io, self.env, self.cfg, sid, eff) catch return;
        var sess = setup.sess;
        var ag = setup.agent;
        sess.append(a, .user, job.goal) catch {};

        if (ag.audit) |lg| {
            const marker = std.fmt.allocPrint(a, "schedule job={s} mode={s} goal={s}", .{
                job.id, @tagName(eff), job.goal,
            }) catch job.goal;
            lg.log(.run, marker) catch {};
        }

        self.out.print("[scoot] > job {s} ({s}): {s}\n", .{ job.id, @tagName(eff), job.goal }) catch {};
        const reply = ag.run(a, &sess) catch |err| {
            if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
            finalizeRun(self.out, self.io, &sess, self.cfg.dirs.sessions_dir, &sink);
            self.out.print("[scoot] x job {s} failed: {s} (continuing to next)\n", .{ job.id, @errorName(err) }) catch {};
            self.out.flush() catch {};
            return;
        };
        finalizeRun(self.out, self.io, &sess, self.cfg.dirs.sessions_dir, &sink);
        self.out.print("[scoot] OK job {s}: {s}\n", .{ job.id, reply }) catch {};
        self.out.flush() catch {}; // Keep progress visible in long runs.
    }
};

const ScheduleLoad = struct {
    scheduler: scoot.schedule.Scheduler,
    valid: usize,
};

fn loadSchedule(out: *Io.Writer, arena: std.mem.Allocator, cfg: scoot.config.Config) !ScheduleLoad {
    var sch: scoot.schedule.Scheduler = .{};
    var valid: usize = 0;
    for (cfg.schedule.jobs) |jc| {
        const job = jc.toJob() orelse {
            try out.print("[scoot] skipping invalid job '{s}' (set every_sec, at_unix, or cron).\n", .{jc.id});
            continue;
        };
        try sch.add(arena, job); // Job content borrows cfg/arena lifetime.
        valid += 1;
    }
    return .{ .scheduler = sch, .valid = valid };
}

fn runSchedulerLoop(
    io: std.Io,
    scheduler: *scoot.schedule.Scheduler,
    poll_ms: u64,
    max_ticks: usize,
    stop_flag: ?*std.atomic.Value(bool),
    ctx: *anyopaque,
    runFn: scoot.schedule.Scheduler.RunFn,
) usize {
    var total: usize = 0;
    var ticks: usize = 0;
    while (max_ticks == 0 or ticks < max_ticks) : (ticks += 1) {
        if (isStopRequested(stop_flag)) break;
        const now_unix = std.Io.Timestamp.now(io, .real).toSeconds();
        total += scheduler.tick(now_unix, ctx, runFn);
        if (isStopRequested(stop_flag)) break;
        if (max_ticks != 0 and ticks + 1 >= max_ticks) break;
        io.sleep(std.Io.Duration.fromMilliseconds(@intCast(poll_ms)), .awake) catch break;
    }
    return total;
}

fn isStopRequested(stop_flag: ?*std.atomic.Value(bool)) bool {
    const flag = stop_flag orelse return false;
    return flag.load(.acquire);
}

/// `scoot schedule run [--ticks N]`: loads valid jobs and enters a daemon loop
/// that wakes the agent when due. `schedule.enabled` must be explicitly true
/// because unattended autonomous execution is high risk and disabled by default.
/// `client`/`token` are built once for the daemon lifetime; each job scratch uses
/// a resettable arena.
fn runSchedule(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
    ticks: usize,
) !void {
    const sc = cfg.schedule;
    if (!sc.enabled) {
        try out.writeAll("[scoot] schedule is disabled: set schedule.enabled=true in the config file before running.\n");
        die(out, 1);
    }

    var loaded = try loadSchedule(out, arena, cfg);
    const valid = loaded.valid;
    if (valid == 0) {
        try out.writeAll("[scoot] no runnable jobs; exiting.\n");
        return;
    }

    var client = try initBackendClient(out, cfg, arena, io, env);

    var job_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer job_arena.deinit();

    var rctx = RunCtx{
        .out = out,
        .io = io,
        .env = env,
        .cfg = cfg,
        .client = &client,
        .job_arena = &job_arena,
    };

    try out.print("[scoot] schedule started: {d} jobs, poll={d}ms, {s} (backend {s}, model={s}).\n", .{
        valid,
        sc.poll_ms,
        if (ticks == 0) "run continuously (Ctrl-C to exit)" else "bounded run",
        cfg.backend.base_url,
        cfg.backend.model,
    });
    try out.flush();

    const fired = runSchedulerLoop(io, &loaded.scheduler, sc.poll_ms, ticks, null, &rctx, RunCtx.runJob);
    try out.print("[scoot] schedule finished: total fired {d} times.\n", .{fired});
}

fn runDaemon(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
    ticks: usize,
) !void {
    const sc = cfg.schedule;
    if (!sc.enabled) {
        try out.writeAll("[scoot] daemon requires schedule config: set schedule.enabled=true.\n");
        die(out, 1);
    }

    const previous_state = scoot.daemon.readState(arena, io, cfg.dirs.state_dir) catch |err| blk: {
        try out.print("[scoot] warning: could not read daemon state file ({s}); will overwrite with new state.\n", .{@errorName(err)});
        break :blk null;
    };
    if (scoot.daemon.previousRunWasUnclean(previous_state)) {
        const prev = previous_state.?;
        // issue #53: previous state is still running. If that pid is alive and
        // not this process, another daemon is running, so refuse duplicate start
        // to avoid two instances sharing schedule/state files. Otherwise treat it
        // as stale state after a crash and continue restart recovery. signal-0
        // cannot distinguish PID reuse, accepted as residual risk.
        if (scoot.daemon.pidAlive(prev.pid) and prev.pid != currentPid()) {
            try out.print(
                "[scoot] refusing to start: detected daemon already running (pid={d} started_at={d}). Run `scoot daemon stop` first.\n",
                .{ prev.pid, prev.started_at_unix },
            );
            die(out, 1);
        }
        try out.print(
            "[scoot] detected previous daemon did not record a clean stop: pid={d} started_at={d} (process is no longer alive; continuing with restart recovery semantics).\n",
            .{ prev.pid, prev.started_at_unix },
        );
    }

    var loaded = try loadSchedule(out, arena, cfg);
    const valid = loaded.valid;
    if (valid == 0) {
        try out.writeAll("[scoot] no runnable jobs; daemon exits.\n");
        return;
    }

    var client = try initBackendClient(out, cfg, arena, io, env);

    var job_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer job_arena.deinit();

    var rctx = RunCtx{
        .out = out,
        .io = io,
        .env = env,
        .cfg = cfg,
        .client = &client,
        .job_arena = &job_arena,
    };

    daemon_stop_requested.store(false, .release);
    installDaemonSignalHandlers();

    const pid = currentPid();
    const started_at = std.Io.Timestamp.now(io, .real).toSeconds();
    try scoot.daemon.writePid(arena, io, cfg.dirs.state_dir, pid);
    try scoot.daemon.writeState(arena, io, cfg.dirs.state_dir, .{
        .status = "running",
        .pid = pid,
        .started_at_unix = started_at,
        .updated_at_unix = started_at,
        .schedule_enabled = sc.enabled,
        .jobs = valid,
        .poll_ms = sc.poll_ms,
    });

    try out.print("[scoot] daemon started: pid={d} jobs={d} poll={d}ms, {s}.\n", .{
        pid,
        valid,
        sc.poll_ms,
        if (ticks == 0) "run continuously (daemon stop or Ctrl-C to exit)" else "bounded run",
    });
    try out.flush();

    const fired = runSchedulerLoop(io, &loaded.scheduler, sc.poll_ms, ticks, &daemon_stop_requested, &rctx, RunCtx.runJob);
    const stopped_at = std.Io.Timestamp.now(io, .real).toSeconds();
    const reason = if (daemon_stop_requested.load(.acquire)) "signal" else if (ticks != 0) "ticks" else "loop_end";
    try scoot.daemon.writeState(arena, io, cfg.dirs.state_dir, .{
        .status = "stopped",
        .pid = pid,
        .started_at_unix = started_at,
        .updated_at_unix = stopped_at,
        .stopped_at_unix = stopped_at,
        .stop_reason = reason,
        .schedule_enabled = sc.enabled,
        .jobs = valid,
        .poll_ms = sc.poll_ms,
    });
    scoot.daemon.clearPid(arena, io, cfg.dirs.state_dir);
    try out.print("[scoot] daemon stopped: reason={s} fired={d}.\n", .{ reason, fired });
}

fn printDaemonStatus(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
) !void {
    const state = try scoot.daemon.readState(arena, io, cfg.dirs.state_dir);
    const pid = try scoot.daemon.readPid(arena, io, cfg.dirs.state_dir);
    const state_path = try scoot.daemon.statePath(arena, cfg.dirs.state_dir);
    const pid_path = try scoot.daemon.pidPath(arena, cfg.dirs.state_dir);

    if (state) |s| {
        try out.print("daemon status={s} pid={d} jobs={d} poll_ms={d}\n", .{ s.status, s.pid, s.jobs, s.poll_ms });
        try out.print("started_at={d} updated_at={d}\n", .{ s.started_at_unix, s.updated_at_unix });
        if (s.stopped_at_unix) |t| try out.print("stopped_at={d}\n", .{t});
        if (s.stop_reason) |reason| try out.print("stop_reason={s}\n", .{reason});
    } else {
        try out.writeAll("daemon status=unknown (no daemon state file yet)\n");
    }
    if (pid) |p| {
        try out.print("pid_file={s} pid={d}\n", .{ pid_path, p });
    } else {
        try out.print("pid_file={s} missing\n", .{pid_path});
    }
    try out.print("state_file={s}\n", .{state_path});

    // issue #53: real liveness probe, replacing the old "not_probed" placeholder.
    // Prefer pid file value, then fall back to state pid.
    const probe_pid: ?i64 = if (pid) |p| p else if (state) |s| s.pid else null;
    if (probe_pid) |pp| {
        const alive = scoot.daemon.pidAlive(pp);
        try out.print("liveness={s} probed_pid={d}\n", .{ if (alive) "alive" else "dead", pp });
        // If state still says running but the process is dead, reconcile by
        // writing stopped state and clearing stale pid file to avoid persistent
        // false running status.
        if (!alive) {
            if (state) |s| {
                if (std.mem.eql(u8, s.status, "running")) {
                    try writeDaemonStoppedAfterFailedStop(arena, io, cfg, pp, "stale_pid_reconciled");
                    scoot.daemon.clearPid(arena, io, cfg.dirs.state_dir);
                    try out.writeAll("[scoot] reconciled stale running state to stopped and removed pid file.\n");
                }
            }
        }
    } else {
        try out.writeAll("liveness=unknown (no pid to probe)\n");
    }
}

fn stopDaemon(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
) !void {
    const pid = (try scoot.daemon.readPid(arena, io, cfg.dirs.state_dir)) orelse {
        try out.writeAll("[scoot] no daemon pid file; daemon may not be running.\n");
        return;
    };
    if (pid <= 0) {
        try out.print("[scoot] invalid daemon pid: {d}\n", .{pid});
        die(out, 1);
    }
    const state = (try scoot.daemon.readState(arena, io, cfg.dirs.state_dir)) orelse {
        try out.print("[scoot] refusing to signal pid={d}: daemon state is missing; treating pid file as stale.\n", .{pid});
        scoot.daemon.clearPid(arena, io, cfg.dirs.state_dir);
        return;
    };
    if (!std.mem.eql(u8, state.status, "running") or state.pid != pid) {
        try out.print(
            "[scoot] refusing to signal pid={d}: daemon state says status={s} pid={d}; treating pid file as stale.\n",
            .{ pid, state.status, state.pid },
        );
        scoot.daemon.clearPid(arena, io, cfg.dirs.state_dir);
        return;
    }
    // issue #53: probe before SIGTERM. If already dead, clear pid file and
    // reconcile state instead of signaling a stale pid. This narrows the PID
    // reuse worst case together with status probes.
    if (!scoot.daemon.pidAlive(pid)) {
        try out.print("[scoot] daemon pid={d} is not alive; cleaning pid file and reconciling state.\n", .{pid});
        scoot.daemon.clearPid(arena, io, cfg.dirs.state_dir);
        try writeDaemonStoppedAfterFailedStop(arena, io, cfg, pid, "process_not_alive");
        return;
    }
    std.posix.kill(@intCast(pid), .TERM) catch |err| switch (err) {
        error.ProcessNotFound => {
            try out.print("[scoot] pid={d} does not exist; cleaning stale pid file.\n", .{pid});
            scoot.daemon.clearPid(arena, io, cfg.dirs.state_dir);
            try writeDaemonStoppedAfterFailedStop(arena, io, cfg, pid, "process_not_found");
            return;
        },
        error.PermissionDenied => {
            try out.print("[scoot] no permission to stop daemon pid={d}.\n", .{pid});
            die(out, 1);
        },
        else => return err,
    };
    try out.print("[scoot] sent SIGTERM to daemon pid={d}.\n", .{pid});
}

fn writeDaemonStoppedAfterFailedStop(
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
    pid: i64,
    reason: []const u8,
) !void {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    try scoot.daemon.writeState(arena, io, cfg.dirs.state_dir, .{
        .status = "stopped",
        .pid = pid,
        .started_at_unix = now,
        .updated_at_unix = now,
        .stopped_at_unix = now,
        .stop_reason = reason,
        .schedule_enabled = cfg.schedule.enabled,
        .jobs = cfg.schedule.jobs.len,
        .poll_ms = cfg.schedule.poll_ms,
    });
}

fn installDaemonSignalHandlers() void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = handleDaemonSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &action, null);
    std.posix.sigaction(.INT, &action, null);
}

fn handleDaemonSignal(_: std.posix.SIG) callconv(.c) void {
    daemon_stop_requested.store(true, .release);
}

fn currentPid() i64 {
    return @intCast(std.posix.system.getpid());
}

/// Resolves API token from env > file > cmd. Local unauthenticated backends may
/// leave it empty. Explicitly configured file/cmd sources that fail produce
/// warnings instead of being silently treated as no-auth.
fn resolveToken(
    warn: *Io.Writer,
    cfg: scoot.config.Config,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    const explicit_source = cfg.backend.api_key_file != null or cfg.backend.api_key_cmd != null;
    const s = cfg.resolveToken(arena, io, env) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Token file exists but permissions are too broad: warn with chmod 600
        // guidance and continue with empty token. Never read world-readable secrets.
        error.InsecurePermissions => {
            try warn.print(
                "[scoot] warning: token file permissions are too broad (group/other readable); rejected reading it.\n" ++
                    "        Run `chmod 600 {s}` and retry.\n",
                .{cfg.backend.api_key_file orelse cfg.dirs.token_file},
            );
            return "";
        },
        // All sources missed: local Ollama-like backends may need no key, so
        // continue silently with empty token. Warn only when file/cmd was
        // explicitly configured but still missed.
        error.NoApiKey => {
            if (explicit_source) {
                try warn.print(
                    "[scoot] warning: config specifies a token file or credential command, but no token was loaded.\n" ++
                        "        Check that the file exists and is non-empty, or that the credential command works.\n",
                    .{},
                );
            }
            return "";
        },
        else => return err,
    };
    return s.value;
}

/// Resolves token and builds backend client. Shared by -e, REPL, schedule, and
/// daemon to avoid drift. `warn` receives degradation warnings such as missing
/// token source or broad permissions. Interactive entries pass stdout; `-e`
/// passes stderr to preserve scriptable output (issue #23).
fn initBackendClient(
    warn: *Io.Writer,
    cfg: scoot.config.Config,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !scoot.llm.Client {
    const token = try resolveToken(warn, cfg, arena, io, env);
    var client = scoot.llm.Client.init(io, cfg.backend.base_url, cfg.backend.model, token);
    client.ca_file = cfg.backend.ca_file;
    client.timeout_ms = cfg.backend.timeout_ms;
    client.extra_body = cfg.backend.extra_body;
    client.model_ctx.store = cfg.backend.store;
    return client;
}

/// Setup result for one run. client/sink storage is caller-owned so agent
/// pointers stay stable. This struct only carries session and agent by value;
/// neither is self-referential.
const RunSetup = struct {
    sess: scoot.session.Session,
    agent: scoot.agent.Agent,
};

/// Shared setup for session (system prompt + skills) and agent (policy, timeout,
/// CA, audit sink). Used by -e, REPL, and schedule jobs to avoid near-duplicate
/// setup drift (issue #30). `warn` routes degradation warnings such as skill
/// discovery or audit open failures: -e uses stderr, others use stdout
/// (issue #23). Callers append user/goal messages, set trace, and write run
/// boundary audit markers according to entry semantics.
fn setupRun(
    client: *scoot.llm.Client,
    sink: *AuditSink,
    warn: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
    session_id: []const u8,
    policy_mode: scoot.policy.Mode,
) !RunSetup {
    var sess = scoot.session.Session.init(session_id);
    try sess.append(arena, .system, scoot.agent.system_prompt);
    const skills = injectSkills(warn, arena, io, cfg, &sess);

    var ag = scoot.agent.Agent.initClient(client);
    ag.max_turns = cfg.agent.max_turns;
    ag.tool_timeout_ms = cfg.tools.timeout_ms;
    ag.policy_mode = policy_mode;
    ag.ca_file = cfg.backend.ca_file;
    ag.env = env;
    ag.context_budget_bytes = cfg.agent.context_budget_bytes;
    ag.compactor = try cfg.resolveCompressor(arena);
    ag.confine_writes = cfg.tools.confine_writes;
    ag.block_internal_http = cfg.tools.block_internal_http;
    ag.skills = skills;
    ag.mcp_servers = cfg.mcp.servers;

    sink.open(warn, arena, io, cfg.dirs.logs_dir);
    sink.setContext(session_id, null);
    ag.audit = sink.loggerPtr();

    return .{ .sess = sess, .agent = ag };
}

/// Generates a distinct transcript id for one interactive/scripted interaction.
/// schedule/daemon jobs still pass stable `job-<id>` ids to preserve aggregation.
fn interactiveSessionId(arena: std.mem.Allocator, io: std.Io, prefix: []const u8) ![]const u8 {
    const ts_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return formatInteractiveSessionId(arena, prefix, ts_ms, currentPid());
}

fn formatInteractiveSessionId(arena: std.mem.Allocator, prefix: []const u8, ts_ms: i64, pid: i64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}-{d}-{d}", .{ prefix, ts_ms, pid });
}

/// Interactive REPL: reuses the ReACT loop across multiple turns in one session.
/// With a human present, one backend failure prints a warning and continues
/// rather than terminating the whole session. On exit, persists session/audit.
fn runRepl(
    out: *Io.Writer,
    err_out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
    trace: bool,
) !void {
    // REPL is human-attended and stdout is the conversation UI, so warnings use out.
    var client = try initBackendClient(out, cfg, arena, io, env);
    var sink: AuditSink = .{};
    const session_id = try interactiveSessionId(arena, io, "repl");
    const setup = try setupRun(&client, &sink, out, arena, io, env, cfg, session_id, scoot.policy.Mode.fromString(cfg.tools.policy));
    var sess = setup.sess;
    var ag = setup.agent;
    // Match -e/--eval: trace goes to stderr so stdout conversation can redirect cleanly.
    if (trace) ag.trace = err_out;

    // Python-style banner: version + model on first line, hint on second.
    try out.print(ansi.bold ++ "Scoot {s}" ++ ansi.reset ++ " (model " ++ ansi.cyan ++ "{s}" ++ ansi.reset ++ ", policy {s})\n", .{
        scoot.version, cfg.backend.model, cfg.tools.policy,
    });
    if (trace) try out.writeAll(ansi.dim ++ "(--trace enabled: execution trace is written to stderr)" ++ ansi.reset ++ "\n");
    try out.writeAll(repl_hint);

    var in_buf: [1 << 16]u8 = undefined;
    var ir: Io.File.Reader = .init(.stdin(), io, &in_buf);

    replLoop(out, &ir.interface, &ag, &sess, arena, true) catch {};

    finalizeRun(err_out, io, &sess, cfg.dirs.sessions_dir, &sink);
    try printRunSummary(err_out, arena, "ok", &sess, cfg.dirs.sessions_dir, &sink, &client);
    try out.writeAll("Goodbye.\n");
}

/// REPL main loop, decoupled from IO source and backend for injectable tests.
/// `backing` owns cross-turn session history. Session history and per-turn scratch
/// accumulate in `backing`; REPL is user-driven and bounded, so this is acceptable.
/// Unattended daemon/schedule paths must use recyclable allocation for long runs.
fn replLoop(
    out: *Io.Writer,
    in: *Io.Reader,
    ag: *scoot.agent.Agent,
    sess: *scoot.session.Session,
    backing: std.mem.Allocator,
    color: bool,
) !void {
    const prompt = if (color) "\n" ++ ansi.bold_green ++ ">>> " ++ ansi.reset else "\n>>> ";
    const err_pre = if (color) ansi.bold_red ++ "x" ++ ansi.reset ++ " " else "x ";
    while (true) {
        try out.writeAll(prompt);
        out.flush() catch {}; // Show prompt before blocking read; failure only affects display.
        const raw = (readLine(in) catch break) orelse break;
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        if (eql(line, "/exit") or eql(line, "/quit")) break;
        if (eql(line, "/help")) {
            try out.writeAll(repl_help);
            continue;
        }

        try sess.append(backing, .user, line); // append copies line before it expires.
        if (ag.audit) |lg| lg.log(.run, line) catch {};

        const reply = ag.run(backing, sess) catch |err| {
            if (ag.trace) |tw| tw.flush() catch {};
            if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
            try out.print("{s}Backend call failed: {s} (check backend configuration and availability)\n", .{ err_pre, @errorName(err) });
            continue; // REPL does not exit on one failure.
        };
        if (ag.trace) |tw| tw.flush() catch {}; // Flush trace promptly to stderr.
        defer backing.free(reply); // No-op under arena; prevents leaks with real allocators.
        try out.print("{s}\n", .{reply});
    }
}

/// Reads one line from reader, trimming trailing \r\n. EOF with no residual line returns null.
fn readLine(in: *Io.Reader) !?[]const u8 {
    const line = in.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => {
            const rest = in.take(in.bufferedLen()) catch return null;
            if (rest.len == 0) return null;
            return rest; // Final residual line without newline.
        },
        else => return err,
    };
    return std.mem.trimEnd(u8, line, "\r\n");
}

/// Audit persistence handle: opens logs/audit.jsonl for append and owns buffer/writer.
const AuditSink = struct {
    file: ?Io.File = null,
    fw: Io.File.Writer = undefined,
    logger: scoot.audit.Logger = undefined,
    buf: [4096]u8 = undefined,

    /// Opens audit log at EOF. If open fails, degrades to explicit warning and no
    /// trace, neither silently black-boxing nor blocking the task on log failure.
    fn open(self: *AuditSink, warn: *Io.Writer, arena: std.mem.Allocator, io: std.Io, logs_dir: []const u8) void {
        const path = std.fmt.allocPrint(arena, "{s}/audit.jsonl", .{logs_dir}) catch return;
        _ = scoot.audit.rotateFileIfTooLarge(io, arena, path, scoot.audit.default_max_jsonl_bytes) catch false;
        const f = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch |err| {
            warn.print("[scoot] warning: audit log cannot be written ({s}: {s}); this run will not be audited\n", .{ path, @errorName(err) }) catch {};
            return;
        };
        self.file = f;
        f.setPermissions(io, std.Io.File.Permissions.fromMode(0o600)) catch {};
        self.fw = f.writer(io, &self.buf);
        if (f.stat(io)) |st| {
            self.fw.seekTo(st.size) catch {}; // Append at EOF without overwriting history.
        } else |_| {}
        self.logger = scoot.audit.Logger.init(&self.fw.interface, io);
    }

    /// Logger pointer injectable into agent; null if open failed.
    fn loggerPtr(self: *AuditSink) ?*scoot.audit.Logger {
        return if (self.file != null) &self.logger else null;
    }

    fn setContext(self: *AuditSink, session_id: []const u8, run_id: ?[]const u8) void {
        if (self.loggerPtr()) |lg| lg.setContext(session_id, run_id);
    }

    fn close(self: *AuditSink, io: std.Io) void {
        if (self.file) |f| {
            self.fw.interface.flush() catch {};
            f.close(io);
        }
    }

    fn stats(self: *const AuditSink) scoot.audit.Stats {
        return if (self.file != null) self.logger.stats else .{};
    }
};

/// Finalizes one run: flushes/closes audit and appends session snapshot. Best effort.
fn finalizeRun(warn: *Io.Writer, io: std.Io, sess: *scoot.session.Session, sessions_dir: []const u8, sink: *AuditSink) void {
    sink.close(io);
    sess.persist(io, sessions_dir) catch |err| {
        var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
        const transcript = std.fmt.bufPrint(&pathbuf, "{s}/{s}.jsonl", .{ sessions_dir, sess.id }) catch "<transcript>";
        warn.print("[scoot] warning: transcript could not be persisted ({s}: {s}).\n", .{ transcript, @errorName(err) }) catch {};
        warn.flush() catch {};
    };
}

fn printRunSummary(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    status: []const u8,
    sess: *const scoot.session.Session,
    sessions_dir: []const u8,
    sink: *const AuditSink,
    client: *const scoot.llm.Client,
) !void {
    const st = sink.stats();
    const transcript = try std.fmt.allocPrint(arena, "{s}/{s}.jsonl", .{ sessions_dir, sess.id });
    const backend = if (client.last_error_status == 0)
        if (client.lastErrorBody().len == 0) "ok" else "transport_error"
    else
        try std.fmt.allocPrint(arena, "status={d}", .{client.last_error_status});
    try out.print(
        "[scoot] summary status={s} turns={d} tools={d} policy_deny={d} system_error={d} events={d} backend={s} transcript={s}\n",
        .{ status, st.thought, st.tool_call, st.policy_deny, st.system_error, st.total(), backend, transcript },
    );
    try out.flush();
}

/// Exits cleanly after printing user-facing expected failures, flushing stdout.
fn die(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

const TestBrain = struct {
    steps: []const []const u8,
    idx: usize = 0,
};

fn testBrainComplete(
    ctx: *anyopaque,
    a: std.mem.Allocator,
    msgs: []const scoot.llm.Message,
    opts: scoot.llm.ChatOptions,
) anyerror!scoot.llm.Completion {
    _ = msgs;
    _ = opts;
    const self: *TestBrain = @ptrCast(@alignCast(ctx));
    if (self.idx >= self.steps.len) return error.ScriptExhausted;
    const c = self.steps[self.idx];
    self.idx += 1;
    return .{ .content = try a.dupe(u8, c), .finish_reason = "stop" };
}

test "replLoop: multiple turns skip blank lines exit and continue after backend failure" {
    const gpa = std.testing.allocator;
    // Only one scripted final step; second real input exhausts script and simulates backend failure.
    var brain = TestBrain{ .steps = &.{
        "{\"thought\":\"finish\",\"action\":\"final\",\"action_input\":\"hello\"}",
    } };
    var ag = scoot.agent.Agent{
        .io = std.testing.io,
        .complete_ctx = &brain,
        .complete_fn = testBrainComplete,
        .max_turns = 4,
    };

    var sess = scoot.session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, scoot.agent.system_prompt);

    // Input: valid, empty, whitespace, second valid failure, /exit, then unread tail.
    var in = Io.Reader.fixed("hi\n\n   \nsecond\n/exit\nSHOULD_NOT_BE_READ\n");
    var obuf: [4096]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);

    try replLoop(&ow, &in, &ag, &sess, gpa, false);

    const o = ow.buffered();
    try std.testing.expect(std.mem.indexOf(u8, o, "hello") != null); // First turn succeeded.
    try std.testing.expect(std.mem.indexOf(u8, o, "Backend call failed") != null); // Second failed but continued.
    try std.testing.expect(std.mem.indexOf(u8, o, "SHOULD_NOT_BE_READ") == null); // Stop reading after /exit.
    // Two user inputs should enter session history.
    var user_msgs: usize = 0;
    for (sess.items()) |m| {
        if (m.role == .user) user_msgs += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), user_msgs); // "hi" and "second".
}

test "replLoop: --trace writes trace to injected trace writer without polluting stdout conversation" {
    const gpa = std.testing.allocator;
    var brain = TestBrain{ .steps = &.{
        "{\"thought\":\"finish\",\"action\":\"final\",\"action_input\":\"hello\"}",
    } };
    var tracebuf: [4096]u8 = undefined;
    var tw = Io.Writer.fixed(&tracebuf);
    var ag = scoot.agent.Agent{
        .io = std.testing.io,
        .complete_ctx = &brain,
        .complete_fn = testBrainComplete,
        .max_turns = 4,
        .trace = &tw, // Simulate runRepl pointing ag.trace to stderr under --trace.
    };

    var sess = scoot.session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, scoot.agent.system_prompt);

    var in = Io.Reader.fixed("hi\n/exit\n");
    var obuf: [4096]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);

    try replLoop(&ow, &in, &ag, &sess, gpa, false);

    const o = ow.buffered();
    try std.testing.expect(std.mem.indexOf(u8, o, "hello") != null); // Reply still goes to stdout.
    try std.testing.expect(std.mem.indexOf(u8, o, "[trace") == null); // Trace does not mix into chat.

    const t = tw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, t, "[trace 1] reason: finish") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "[trace 1] action: final") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "[trace 1] final: hello") != null);
}

test "formatInteractiveSessionId: cli/repl ids are per-run and file-safe" {
    const gpa = std.testing.allocator;

    const cli = try formatInteractiveSessionId(gpa, "cli", 1718600000123, 4242);
    defer gpa.free(cli);
    const repl = try formatInteractiveSessionId(gpa, "repl", 1718600000123, 4242);
    defer gpa.free(repl);

    try std.testing.expectEqualStrings("cli-1718600000123-4242", cli);
    try std.testing.expectEqualStrings("repl-1718600000123-4242", repl);
}

test "readLine: with newline/without trailing newline/empty input" {
    var in1 = Io.Reader.fixed("a\nbb\n");
    try std.testing.expectEqualStrings("a", (try readLine(&in1)).?);
    try std.testing.expectEqualStrings("bb", (try readLine(&in1)).?);
    try std.testing.expect((try readLine(&in1)) == null);

    var in2 = Io.Reader.fixed("tail-no-nl");
    try std.testing.expectEqualStrings("tail-no-nl", (try readLine(&in2)).?);
    try std.testing.expect((try readLine(&in2)) == null);

    var in3 = Io.Reader.fixed("");
    try std.testing.expect((try readLine(&in3)) == null);
}

test "serveLoop: handles read APIs bad JSON and unknown methods as NDJSON" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const home = "/tmp/scoot_serve_loop_test";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dirs = try scoot.paths.Paths.fromHome(arena, home);
    try dirs.ensure(io);
    const cfg: scoot.config.Config = .{ .dirs = dirs };

    try cwd.writeFile(io, .{
        .sub_path = home ++ "/state/sessions/alpha.jsonl",
        .data =
        \\{"role":"system","content":"sys"}
        \\{"role":"user","content":"hello\nworld"}
        \\{"role":"assistant","content":"done"}
        \\
        ,
    });
    try cwd.writeFile(io, .{
        .sub_path = home ++ "/logs/audit.jsonl",
        .data =
        \\{"seq":0,"ts":10,"session_id":"alpha","kind":"run","msg":"hello"}
        \\{"seq":1,"ts":11,"session_id":"beta","kind":"run","msg":"other"}
        \\
        ,
    });

    var in = Io.Reader.fixed(
        \\{not json}
        \\{"id":"list-1","method":"session.list","params":{}}
        \\{"id":2,"method":"session.get","params":{"id":"alpha"}}
        \\{"id":"audit-1","method":"audit.query","params":{"session_id":"alpha"}}
        \\{"id":"missing","method":"bogus","params":{}}
        \\
    );
    var obuf: [8192]u8 = undefined;
    var out = Io.Writer.fixed(&obuf);
    const rt: *scoot.api.Runtime = undefined;

    try serveLoop(&out, &in, rt, io, cfg);
    const got = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "\"id\":null,\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"code\":\"bad_json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"id\":\"list-1\",\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"sessions\":[{\"id\":\"alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"id\":2,\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"messages\":[{\"role\":\"system\",\"content\":\"sys\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"session_id\":\"alpha\",\"events\":[{\"seq\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"code\":\"method_not_found\"") != null);
}

fn testGuardDecision(
    arena: std.mem.Allocator,
    mode: scoot.policy.Mode,
    action: scoot.agent.Action,
    input: []const u8,
) scoot.policy.Decision {
    var ag = scoot.agent.Agent.initGuard(std.testing.io);
    ag.policy_mode = mode;
    return ag.guard(arena, action, input);
}

test "policy check shares the runtime guard (no decision drift)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (testGuardDecision(arena, .guarded, .bash, "rm -rf /")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (testGuardDecision(arena, .readonly, .file_read, "{\"path\":\"README.md\"}")) {
        .allow => {},
        .deny => return error.ExpectedAllow,
    }
    switch (testGuardDecision(arena, .readonly, .file_read, "{\"path\":\"/etc/passwd\"}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (testGuardDecision(arena, .readonly, .glob, "{\"pattern\":\"**/*.zig\",\"root\":\".\"}")) {
        .allow => {},
        .deny => return error.ExpectedAllow,
    }
    switch (testGuardDecision(arena, .readonly, .glob, "{\"pattern\":\"**/*\",\"root\":\"..\"}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (testGuardDecision(arena, .readonly, .recall, "{\"query\":\"old\"}")) {
        .allow => {},
        .deny => return error.ExpectedAllow,
    }
    switch (testGuardDecision(arena, .readonly, .file_write, "{\"path\":\"x\",\"content\":\"y\"}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (testGuardDecision(arena, .readonly, .bash, "cat README.md")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (testGuardDecision(arena, .readonly, .http_request, "{\"method\":\"GET\",\"url\":\"https://example.com\"}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (testGuardDecision(arena, .readonly, .http_request, "{\"method\":\"POST\",\"url\":\"https://example.com\"}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (testGuardDecision(arena, .readonly, .parallel, "{\"calls\":[{\"action\":\"file_read\",\"input\":\"{\\\"path\\\":\\\"README.md\\\"}\"}]}")) {
        .allow => {},
        .deny => return error.ExpectedAllow,
    }
    switch (testGuardDecision(arena, .readonly, .parallel, "{\"calls\":[{\"action\":\"http_request\",\"input\":\"{\\\"method\\\":\\\"GET\\\",\\\"url\\\":\\\"https://example.com\\\"}\"}]}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (testGuardDecision(arena, .guarded, .parallel, "{\"calls\":[{\"action\":\"file_write\",\"input\":\"{\\\"path\\\":\\\"x\\\",\\\"content\\\":\\\"y\\\"}\"}]}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }

    // Regression: the previous CLI-only decision path allowed these in guarded
    // mode while the runtime guard denied them. The unified path must deny.
    switch (testGuardDecision(arena, .guarded, .file_write, "{\"path\":\"/etc/evil\",\"content\":\"x\"}")) {
        .deny => {},
        .allow => return error.ExpectedDeny, // confine_writes must reject out-of-root writes.
    }
    switch (testGuardDecision(arena, .guarded, .http_request, "{\"method\":\"GET\",\"url\":\"http://169.254.169.254/latest/meta-data/\"}")) {
        .deny => {},
        .allow => return error.ExpectedDeny, // block_internal_http must reject cloud metadata.
    }
    switch (testGuardDecision(arena, .guarded, .mcp_call, "{\"server\":\"nope\",\"tool\":\"x\",\"args\":{}}")) {
        .deny => {},
        .allow => return error.ExpectedDeny, // MCP allowlist must reject unknown servers.
    }
}

test "checkPolicyConfig: reports effective hardening guardrail state(issue #50)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Default mode (guarded + block_internal_http=true + confine_writes=true):
    // both hardening checks should be OK with no WARN.
    {
        var buf: [4096]u8 = undefined;
        var ow = Io.Writer.fixed(&buf);
        var d = Doctor{ .out = &ow };
        const cfg: scoot.config.Config = .{ .dirs = undefined };
        try checkPolicyConfig(&d, arena, cfg);
        const o = ow.buffered();
        try std.testing.expect(std.mem.indexOf(u8, o, "OK\ttools.block_internal_http") != null);
        try std.testing.expect(std.mem.indexOf(u8, o, "OK\ttools.confine_writes") != null);
        try std.testing.expectEqual(@as(usize, 0), d.warnings);
    }

    // Explicitly disabling SSRF guard under guarded should WARN.
    {
        var buf: [4096]u8 = undefined;
        var ow = Io.Writer.fixed(&buf);
        var d = Doctor{ .out = &ow };
        var cfg: scoot.config.Config = .{ .dirs = undefined };
        cfg.tools.block_internal_http = false;
        try checkPolicyConfig(&d, arena, cfg);
        const o = ow.buffered();
        try std.testing.expect(std.mem.indexOf(u8, o, "WARN\ttools.block_internal_http") != null);
        try std.testing.expect(d.warnings >= 1);
    }

    // Explicitly disabling write confinement under guarded should WARN.
    {
        var buf: [4096]u8 = undefined;
        var ow = Io.Writer.fixed(&buf);
        var d = Doctor{ .out = &ow };
        var cfg: scoot.config.Config = .{ .dirs = undefined };
        cfg.tools.confine_writes = false;
        try checkPolicyConfig(&d, arena, cfg);
        const o = ow.buffered();
        try std.testing.expect(std.mem.indexOf(u8, o, "WARN\ttools.confine_writes") != null);
        try std.testing.expect(d.warnings >= 1);
    }
}

test "packSkill: exports tar package and writes review manifest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const root = "/tmp/scoot_skill_pack_ok";
    const out_path = "/tmp/scoot_skill_pack_ok.tar";
    cwd.deleteTree(io, root) catch {};
    cwd.deleteFile(io, out_path) catch {};
    defer cwd.deleteTree(io, root) catch {};
    defer cwd.deleteFile(io, out_path) catch {};

    try cwd.createDirPath(io, root ++ "/scripts");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/SKILL.md",
        .data = "---\nname: pack-ok\ndescription: Pack test skill.\ncapabilities: [instructions, scripts]\nallowed_tools: [bash, file_read]\nscope: workflow\n---\n# Pack\n",
    });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/scripts/run.sh", .data = "echo ok\n" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/.env", .data = "SECRET=must-not-package\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try packSkill(arena, io, root, out_path);
    try std.testing.expectEqualStrings("pack-ok", result.name);
    try std.testing.expectEqual(@as(usize, 2), result.file_count);
    try std.testing.expectEqual(@as(usize, 1), result.skipped_hidden);

    const archive = try cwd.readFileAlloc(io, out_path, arena, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, archive, "scoot.skill.package.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"capabilities\": [") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"scripts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"allowed_tools\": [") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"file_read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"scope\": \"workflow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "pack-ok/.scoot-skill.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "pack-ok/SKILL.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "pack-ok/scripts/run.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "must-not-package") == null);
}

test "packSkill: invalid skill is not packed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const root = "/tmp/scoot_skill_pack_invalid";
    const out_path = "/tmp/scoot_skill_pack_invalid.tar";
    cwd.deleteTree(io, root) catch {};
    cwd.deleteFile(io, out_path) catch {};
    defer cwd.deleteTree(io, root) catch {};
    defer cwd.deleteFile(io, out_path) catch {};

    try cwd.createDirPath(io, root);
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/SKILL.md",
        .data = "---\nname: no-description\n---\n# Invalid\n",
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try std.testing.expectError(error.InvalidSkill, packSkill(arena_state.allocator(), io, root, out_path));
    try std.testing.expect(!fileExists(io, out_path));
}

test "shouldRetryEvalError retries transient backend errors up to the limit" {
    var client = scoot.llm.Client.init(std.testing.io, "http://backend", "model", "");

    client.last_error_status = 429;
    try std.testing.expect(shouldRetryEvalError(error.BackendError, &client, 0, 2));
    try std.testing.expect(shouldRetryEvalError(error.BackendError, &client, 1, 2));
    try std.testing.expect(!shouldRetryEvalError(error.BackendError, &client, 2, 2));

    client.last_error_status = 503;
    try std.testing.expect(shouldRetryEvalError(error.BackendError, &client, 0, 1));

    client.last_error_status = 400;
    try std.testing.expect(!shouldRetryEvalError(error.BackendError, &client, 0, 2));

    client.last_error_status = 0;
    try std.testing.expect(!shouldRetryEvalError(error.Unauthorized, &client, 0, 2));
}

test "evalRetryDelayNs: bounded exponential backoff" {
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_s), evalRetryDelayNs(1));
    try std.testing.expectEqual(@as(u64, 4 * std.time.ns_per_s), evalRetryDelayNs(2));
    try std.testing.expectEqual(@as(u64, 8 * std.time.ns_per_s), evalRetryDelayNs(3));
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_s), evalRetryDelayNs(4));
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_s), evalRetryDelayNs(10));
}

test "parsePolicyModeStrict rejects unknown policy" {
    try std.testing.expectEqual(scoot.policy.Mode.guarded, parsePolicyModeStrict("guarded").?);
    try std.testing.expectEqual(scoot.policy.Mode.readonly, parsePolicyModeStrict("readonly").?);
    try std.testing.expectEqual(scoot.policy.Mode.unrestricted, parsePolicyModeStrict("unrestricted").?);
    try std.testing.expect(parsePolicyModeStrict("surprise") == null);
}

test "schedule: cron trigger loads and appears runnable in list" {
    const jobs = [_]scoot.config.JobConfig{
        .{ .id = "tick", .goal = "g", .every_sec = 5 },
        .{ .id = "nightly", .goal = "g", .cron = "0 3 * * *" },
    };
    var cfg: scoot.config.Config = .{ .dirs = undefined };
    cfg.schedule = .{ .enabled = true, .jobs = &jobs };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // loadSchedule: every_sec and cron both count as valid jobs.
    var lbuf: [1024]u8 = undefined;
    var lw = Io.Writer.fixed(&lbuf);
    const loaded = try loadSchedule(&lw, arena.allocator(), cfg);
    try std.testing.expectEqual(@as(usize, 2), loaded.valid);
    const lout = lw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, lout, "nightly") == null);
    try std.testing.expect(std.mem.indexOf(u8, lout, "cron not supported") == null);

    // printSchedule: cron jobs show execution mode and are no longer INACTIVE.
    var pbuf: [1024]u8 = undefined;
    var pw = Io.Writer.fixed(&pbuf);
    try printSchedule(&pw, cfg);
    const pout = pw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, pout, "cron '0 3 * * *'") != null);
    try std.testing.expect(std.mem.indexOf(u8, pout, "INACTIVE") == null);
}

test "AuditSink: audit file is created owner-only" {
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const dir = "/tmp/scoot_audit_sink_mode_test";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var warn_buf: [512]u8 = undefined;
    var warn = Io.Writer.fixed(&warn_buf);
    var sink: AuditSink = .{};
    sink.open(&warn, arena, io, dir);
    if (sink.loggerPtr()) |lg| try lg.log(.run, "mode-test");
    sink.close(io);

    const st = try cwd.statFile(io, dir ++ "/audit.jsonl", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}

test "buildConfigToml: writes chosen fields, escapes strings, never inlines secrets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const toml = try buildConfigToml(arena, .{
        .base_url = "https://api.example.com/\"weird\"\\path/v1",
        .model = "gpt-4o-mini",
        .key_source = .file,
        .api_key_env = "OPENAI_API_KEY",
        .api_key_file = "/home/user/.scoot/token",
        .api_key_cmd = null,
        .max_turns = 16,
        .policy = "readonly",
    });

    try std.testing.expect(std.mem.indexOf(u8, toml, "model = \"gpt-4o-mini\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "api_key_file = \"/home/user/.scoot/token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "max_turns = 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "policy = \"readonly\"") != null);
    // Quotes and backslashes inside values must be TOML-escaped.
    try std.testing.expect(std.mem.indexOf(u8, toml, "\\\"weird\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "\\\\path") != null);
    // The file source must not also emit an active cmd assignment (the header
    // comment naming all three sources is expected and fine).
    try std.testing.expect(std.mem.indexOf(u8, toml, "api_key_cmd = ") == null);
}

test "runSetupCore: generates 0600 config + token file and runtime tree, no secret in config" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const home = "/tmp/scoot_setup_core_test";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    // Answers: dir(default), base_url, model, source 2 (file), file path(default),
    // token value, max_turns, policy(default).
    var in = Io.Reader.fixed("\n" ++
        "http://localhost:8080/v1\n" ++
        "gpt-4o-mini\n" ++
        "2\n" ++
        "\n" ++
        "sk-secret-xyz\n" ++
        "16\n" ++
        "\n");
    var obuf: [8192]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);

    try runSetupCore(&ow, &in, arena, io, &env, home);

    const cfg_path = home ++ "/config.toml";
    const st = try cwd.statFile(io, cfg_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);

    const body = try cwd.readFileAlloc(io, cfg_path, arena, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, body, "base_url = \"http://localhost:8080/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "model = \"gpt-4o-mini\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "max_turns = 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "api_key_file = ") != null);
    // Secret must never land in config.toml.
    try std.testing.expect(std.mem.indexOf(u8, body, "sk-secret-xyz") == null);

    const tok_path = home ++ "/token";
    const tst = try cwd.statFile(io, tok_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), tst.permissions.toMode() & 0o777);
    const tok = try cwd.readFileAlloc(io, tok_path, arena, .limited(1024));
    try std.testing.expectEqualStrings("sk-secret-xyz", tok);

    // The runtime tree must be created.
    var d = try cwd.openDir(io, home ++ "/state/sessions", .{});
    d.close(io);
}

test "runSetupCore: declining overwrite of an existing config leaves it unchanged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const home = "/tmp/scoot_setup_decline_test";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};
    try cwd.createDirPath(io, home);
    try cwd.writeFile(io, .{ .sub_path = home ++ "/config.toml", .data = "ORIGINAL\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    // dir(default), then decline the overwrite prompt.
    var in = Io.Reader.fixed("\n" ++ "n\n");
    var obuf: [4096]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);

    try runSetupCore(&ow, &in, arena, io, &env, home);

    const body = try cwd.readFileAlloc(io, home ++ "/config.toml", arena, .limited(1024));
    try std.testing.expectEqualStrings("ORIGINAL\n", body);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(scoot);
}
