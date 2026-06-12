//! boo: sessions that haunt your terminal. A GNU screen style
//! terminal multiplexer built on libghostty (ghostty-vt).

const std = @import("std");
const posix = std.posix;

const client = @import("client.zig");
const daemonpkg = @import("daemon.zig");
const help = @import("help.zig");
const paths = @import("paths.zig");
const protocol = @import("protocol.zig");
const ui = @import("ui.zig");

pub const version = "0.5.15";

/// Exit codes, documented in `boo help`.
const exit_runtime: u8 = 1;
const exit_usage: u8 = 2;
const exit_no_session: u8 = 3;
const exit_timeout: u8 = 4;

fn fail(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("boo: " ++ fmt ++ "\n", args);
    posix.exit(code);
}

/// Usage errors point at the relevant help page.
fn usageFail(comptime cmd: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    const hint = if (cmd.len == 0) "boo help" else "boo help " ++ cmd;
    std.debug.print("boo: " ++ fmt ++ " (run '" ++ hint ++ "')\n", args);
    posix.exit(exit_usage);
}

fn stdoutWrite(bytes: []const u8) !void {
    try protocol.writeAll(posix.STDOUT_FILENO, bytes);
}

fn stdoutPrint(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(text);
    try stdoutWrite(text);
}

pub fn main() !void {
    // Note: not DebugAllocator. The session daemon is forked from this
    // process, and DebugAllocator's stack-trace capture reads process
    // memory through a pid cached before fork(), which blows up in the
    // child once the parent exits. Unit tests still run against
    // std.testing.allocator for leak checking.
    const alloc = std.heap.c_allocator;

    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);
    const args: []const [:0]const u8 = @ptrCast(argv[1..]);

    if (args.len == 0) return stdoutWrite(help.overview);

    const cmd = args[0];
    const rest = args[1..];
    const eql = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;

    if (eql(cmd, "new")) return cmdNew(alloc, rest);
    if (eql(cmd, "attach") or eql(cmd, "at") or eql(cmd, "a")) return cmdAttach(alloc, rest);
    if (eql(cmd, "ui") or eql(cmd, "i")) return cmdUi(alloc, rest);
    if (eql(cmd, "ls") or eql(cmd, "list")) return cmdLs(alloc, rest);
    if (eql(cmd, "send")) return cmdSend(alloc, rest);
    if (eql(cmd, "peek")) return cmdPeek(alloc, rest);
    if (eql(cmd, "wait")) return cmdWait(alloc, rest);
    if (eql(cmd, "kill")) return cmdKill(alloc, rest);
    if (eql(cmd, "rename")) return cmdRename(alloc, rest);
    if (eql(cmd, "version") or eql(cmd, "-V") or eql(cmd, "--version")) return cmdVersion(alloc);
    if (eql(cmd, "help") or eql(cmd, "-h") or eql(cmd, "--help")) return cmdHelp(alloc, rest);
    fail(exit_usage, "unknown command '{s}' (run 'boo help')", .{cmd});
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// Match a flag that carries a value, in both spellings: `--flag value`
/// (consuming the next argument) and `--flag=value`. Returns null when
/// `args[i]` is some other argument.
fn flagValue(
    comptime cmd: []const u8,
    comptime flag: []const u8,
    args: []const [:0]const u8,
    i: *usize,
) ?[]const u8 {
    const arg = args[i.*];
    if (std.mem.eql(u8, arg, flag)) {
        i.* += 1;
        if (i.* >= args.len) usageFail(cmd, flag ++ " requires a value", .{});
        return args[i.*];
    }
    if (std.mem.startsWith(u8, arg, flag ++ "=")) {
        return arg[flag.len + 1 ..];
    }
    return null;
}

fn printHelpPage(name: []const u8) !void {
    const entry = help.find(name) orelse unreachable;
    try stdoutWrite(entry.body);
}

// -- Session resolution ---------------------------------------------------

fn joinNames(alloc: std.mem.Allocator, names: []const []u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |name, i| {
        if (i > 0) out.appendSlice(alloc, ", ") catch break;
        out.appendSlice(alloc, name) catch break;
    }
    return out.items;
}

/// Resolve a session name to an owned, existing session name.
/// Accepts unique prefixes. Exits with code 3 when nothing matches.
fn resolveSession(
    alloc: std.mem.Allocator,
    dir: []const u8,
    want: []const u8,
) ![]u8 {
    const sessions = try paths.listSessions(alloc, dir);
    defer {
        for (sessions) |s| alloc.free(s);
        alloc.free(sessions);
    }

    for (sessions) |s| {
        if (std.mem.eql(u8, s, want)) return alloc.dupe(u8, s);
    }
    var match: ?[]const u8 = null;
    var count: usize = 0;
    for (sessions) |s| {
        if (std.mem.startsWith(u8, s, want)) {
            match = s;
            count += 1;
        }
    }
    if (count == 1) return alloc.dupe(u8, match.?);
    if (count > 1) fail(exit_no_session, "ambiguous session '{s}': matches {s}", .{
        want, joinNames(alloc, sessions),
    });
    fail(exit_no_session, "no session matching '{s}' (run 'boo ls')", .{want});
}

pub const SessionInfo = struct {
    /// Full info payload:
    /// name \t Attached|Detached \t idle_ms \t out_idle_ms \t title.
    text: []u8,
    attached: bool,
    idle_ms: i64,
    /// Time since the window last produced output; drives wait --idle.
    out_idle_ms: i64,
    /// Window title; slices into `text`.
    title: []const u8,
};

/// Query a session daemon, deleting the socket when the daemon is gone.
pub fn sessionInfo(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !?SessionInfo {
    const sock = try paths.socketPath(alloc, dir, name);
    defer alloc.free(sock);
    const result = client.control(alloc, sock, &.{"info"}) catch {
        // Stale socket: the daemon is gone.
        std.fs.cwd().deleteFile(sock) catch {};
        return null;
    };
    errdefer alloc.free(result.text);
    if (!result.ok) return error.BadResponse;

    var it = std.mem.splitScalar(u8, result.text, '\t');
    _ = it.next() orelse return error.BadResponse; // name
    const attached = std.mem.eql(u8, it.next() orelse return error.BadResponse, "Attached");
    const idle_ms = std.fmt.parseInt(i64, it.next() orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    const out_idle_ms = std.fmt.parseInt(i64, it.next() orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    const title = it.rest();
    return .{
        .text = result.text,
        .attached = attached,
        .idle_ms = idle_ms,
        .out_idle_ms = out_idle_ms,
        .title = title,
    };
}

/// Run a control command against a session, mapping a missing or
/// mid-teardown daemon to the documented exit code. An EOF on the
/// control connection means the daemon died before replying, so it is
/// reported the same as a daemon that is already gone.
fn mustControl(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    argv: []const []const u8,
) !client.ControlResult {
    const sock = try paths.socketPath(alloc, dir, name);
    defer alloc.free(sock);
    return client.control(alloc, sock, argv) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused, error.ConnectionLost => fail(
            exit_no_session,
            "no session named {s}",
            .{name},
        ),
        else => return err,
    };
}

// -- Commands -------------------------------------------------------------

fn cmdNew(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var name: ?[]const u8 = null;
    var detached = false;
    var cmd_argv: []const [:0]const u8 = &.{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            cmd_argv = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detached")) {
            detached = true;
        } else if (isHelpFlag(arg)) {
            return printHelpPage("new");
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("new", "unknown flag '{s}'", .{arg});
        } else if (name == null) {
            name = arg;
        } else {
            usageFail("new", "unexpected argument '{s}'; put -- before the command", .{arg});
        }
    }

    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);
    return createSession(alloc, dir, name, detached, @ptrCast(cmd_argv));
}

fn createSession(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name_opt: ?[]const u8,
    detached: bool,
    cmd_argv: []const []const u8,
) !void {
    var name_buf: [paths.max_name_len]u8 = undefined;
    const name = name_opt orelse paths.defaultName(&name_buf, dir);
    paths.validateName(name) catch
        usageFail("new", "invalid session name '{s}'", .{name});

    const sock = try paths.socketPath(alloc, dir, name);
    defer alloc.free(sock);

    const listen_fd = bindListen(alloc, sock) catch |err| switch (err) {
        error.SessionExists => fail(
            exit_runtime,
            "session {s} already exists (run 'boo attach {s}')",
            .{ name, name },
        ),
        else => return err,
    };

    // Fork the session daemon. The listening socket already exists, so
    // there is no race between daemon startup and the first attach.
    // BOO_FOREGROUND=1 keeps the daemon in the foreground, which is
    // useful for debugging.
    if (posix.getenv("BOO_FOREGROUND") != null) {
        try daemonpkg.Daemon.run(alloc, .{
            .name = name,
            .socket_path = sock,
            .listen_fd = listen_fd,
            .argv = cmd_argv,
        });
        return;
    }
    const pid = try posix.fork();
    if (pid == 0) {
        runDaemon(alloc, name, sock, listen_fd, cmd_argv);
    }
    posix.close(listen_fd);

    if (detached) {
        // The name on stdout so scripts can capture it.
        try stdoutPrint(alloc, "{s}\n", .{name});
        return;
    }
    try attachLoop(alloc, dir, name);
}

fn cmdAttach(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var name_arg: ?[]const u8 = null;
    for (args) |arg| {
        if (isHelpFlag(arg)) return printHelpPage("attach");
        if (arg.len > 0 and arg[0] == '-') usageFail("attach", "unknown flag '{s}'", .{arg});
        if (name_arg != null) usageFail("attach", "unexpected argument '{s}'", .{arg});
        name_arg = arg;
    }
    const want = name_arg orelse usageFail("attach", "a session name is required", .{});

    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);
    try attachLoop(alloc, dir, name);
}

fn attachLoop(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !void {
    const sock = try paths.socketPath(alloc, dir, name);
    defer alloc.free(sock);
    const outcome = client.attach(alloc, sock) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => fail(
            exit_no_session,
            "no session named {s}",
            .{name},
        ),
        error.NotATty => fail(exit_runtime, "attach requires a terminal", .{}),
        else => return err,
    };
    switch (outcome) {
        .detached => std.debug.print("[detached from {s}]\n", .{name}),
        .stolen => std.debug.print("[session {s} attached elsewhere]\n", .{name}),
        .ended => std.debug.print("[session {s} ended]\n", .{name}),
        .lost => {
            std.debug.print("[lost connection to {s}]\n", .{name});
            posix.exit(exit_runtime);
        },
    }
}

fn cmdUi(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    for (args) |arg| {
        if (isHelpFlag(arg)) return printHelpPage("ui");
        usageFail("ui", "unexpected argument '{s}'", .{arg});
    }

    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);
    ui.run(alloc, dir) catch |err| switch (err) {
        error.NotATty => fail(exit_runtime, "ui requires a terminal", .{}),
        else => return err,
    };
    std.debug.print("[boo ui closed]\n", .{});
}

fn cmdLs(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var json = false;
    for (args) |arg| {
        if (isHelpFlag(arg)) return printHelpPage("ls");
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else {
            usageFail("ls", "unexpected argument '{s}'", .{arg});
        }
    }

    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);
    const sessions = try paths.listSessions(alloc, dir);
    defer {
        for (sessions) |s| alloc.free(s);
        alloc.free(sessions);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var live: usize = 0;
    var name_width: usize = 4;
    var infos: std.ArrayList(struct { name: []const u8, info: SessionInfo }) = .empty;
    defer {
        for (infos.items) |entry| alloc.free(entry.info.text);
        infos.deinit(alloc);
    }
    for (sessions) |name| {
        const info = sessionInfo(alloc, dir, name) catch continue orelse continue;
        try infos.append(alloc, .{ .name = name, .info = info });
        name_width = @max(name_width, name.len);
        live += 1;
    }

    if (json) {
        try out.append(alloc, '[');
        for (infos.items, 0..) |entry, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"name\":");
            try appendJsonString(alloc, &out, entry.name);
            const tail = try std.fmt.allocPrint(alloc, ",\"attached\":{},\"idle_ms\":{d},\"title\":", .{
                entry.info.attached,
                entry.info.idle_ms,
            });
            defer alloc.free(tail);
            try out.appendSlice(alloc, tail);
            try appendJsonString(alloc, &out, entry.info.title);
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "]\n");
        return stdoutWrite(out.items);
    }

    if (live == 0) {
        return stdoutPrint(alloc, "No sessions in {s}.\n", .{dir});
    }

    try appendPadded(alloc, &out, "NAME", name_width);
    try out.appendSlice(alloc, "  STATE     IDLE  TITLE\n");
    for (infos.items) |entry| {
        try appendPadded(alloc, &out, entry.name, name_width);
        var idle_buf: [32]u8 = undefined;
        const line = try std.fmt.allocPrint(alloc, "  {s: <8}  {s: <4}  {s}\n", .{
            if (entry.info.attached) "attached" else "detached",
            fmtIdle(&idle_buf, entry.info.idle_ms),
            entry.info.title,
        });
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }
    try stdoutWrite(out.items);
}

fn cutTab(rest: *[]const u8) ?[]const u8 {
    const idx = std.mem.indexOfScalar(u8, rest.*, '\t') orelse return null;
    const field = rest.*[0..idx];
    rest.* = rest.*[idx + 1 ..];
    return field;
}

fn cmdSend(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var name_arg: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var keys_arg: ?[]const u8 = null;
    var enter = false;
    var stdin = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("send");
        if (std.mem.eql(u8, arg, "--enter")) {
            enter = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin = true;
        } else if (flagValue("send", "--text", args, &i)) |v| {
            text = v;
        } else if (flagValue("send", "--key", args, &i)) |v| {
            keys_arg = v;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("send", "unknown flag '{s}'", .{arg});
        } else if (name_arg == null) {
            name_arg = arg;
        } else {
            usageFail("send", "unexpected argument '{s}'", .{arg});
        }
    }

    if (text != null and keys_arg != null) {
        usageFail("send", "--text and --key cannot be combined; use two calls", .{});
    }
    if (stdin and (text != null or keys_arg != null)) {
        usageFail("send", "--stdin cannot be combined with --text or --key", .{});
    }
    const want = name_arg orelse usageFail("send", "a session name is required", .{});

    // Resolve the session before potentially blocking on stdin.
    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    if (text) |t| {
        try payload.appendSlice(alloc, t);
    } else if (keys_arg) |list| {
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |key_name| {
            if (key_name.len == 0) continue;
            if (!appendKey(alloc, &payload, key_name)) {
                usageFail("send", "unknown key '{s}'", .{key_name});
            }
        }
    } else {
        const data = try readAllStdin(alloc);
        defer alloc.free(data);
        try payload.appendSlice(alloc, data);
    }
    if (enter) try payload.append(alloc, '\r');

    if (payload.items.len == 0) usageFail("send", "nothing to send", .{});
    if (std.mem.indexOfScalar(u8, payload.items, 0) != null) {
        usageFail("send", "cannot send NUL bytes", .{});
    }

    const result = try mustControl(alloc, dir, name, &.{ "send", payload.items });
    defer alloc.free(result.text);
    if (!result.ok) fail(exit_runtime, "{s}", .{result.text});
}

/// Append the byte sequence for a named key. Returns false when the
/// name is not recognized.
fn appendKey(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) bool {
    const eqli = std.ascii.eqlIgnoreCase;
    const bytes: []const u8 = if (eqli(name, "enter"))
        "\r"
    else if (eqli(name, "tab"))
        "\t"
    else if (eqli(name, "escape") or eqli(name, "esc"))
        "\x1b"
    else if (eqli(name, "space"))
        " "
    else if (eqli(name, "backspace") or eqli(name, "bs"))
        "\x7f"
    else if (eqli(name, "up"))
        "\x1b[A"
    else if (eqli(name, "down"))
        "\x1b[B"
    else if (eqli(name, "right"))
        "\x1b[C"
    else if (eqli(name, "left"))
        "\x1b[D"
    else if (eqli(name, "home"))
        "\x1b[H"
    else if (eqli(name, "end"))
        "\x1b[F"
    else if (name.len == 3 and (name[0] == 'C' or name[0] == 'c') and name[1] == '-' and
        std.ascii.isAlphabetic(name[2]))
    blk: {
        const byte = std.ascii.toLower(name[2]) - 'a' + 1;
        break :blk &[1]u8{byte};
    } else return false;

    out.appendSlice(alloc, bytes) catch return false;
    return true;
}

fn readAllStdin(alloc: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n == 0) break;
        try list.appendSlice(alloc, buf[0..n]);
        if (list.items.len > protocol.max_payload - 64) {
            fail(exit_runtime, "stdin too large to send (max ~1MB)", .{});
        }
    }
    return list.toOwnedSlice(alloc);
}

const Peek = struct {
    rows: u32,
    cols: u32,
    cursor_row: u32,
    cursor_col: u32,
    title: []const u8,
    screen: []const u8,
};

/// Wire format: rows \t cols \t cur_row \t cur_col \t title on the
/// first line, then the screen dump.
fn parsePeek(payload: []const u8) ?Peek {
    const nl = std.mem.indexOfScalar(u8, payload, '\n') orelse return null;
    var rest = payload[0..nl];
    const rows = cutTab(&rest) orelse return null;
    const cols = cutTab(&rest) orelse return null;
    const cur_row = cutTab(&rest) orelse return null;
    const cur_col = cutTab(&rest) orelse return null;
    return .{
        .rows = std.fmt.parseInt(u32, rows, 10) catch return null,
        .cols = std.fmt.parseInt(u32, cols, 10) catch return null,
        .cursor_row = std.fmt.parseInt(u32, cur_row, 10) catch return null,
        .cursor_col = std.fmt.parseInt(u32, cur_col, 10) catch return null,
        .title = rest,
        .screen = payload[nl + 1 ..],
    };
}

fn cmdPeek(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var scrollback = false;
    var json = false;
    var name_arg: ?[]const u8 = null;
    for (args) |arg| {
        if (isHelpFlag(arg)) return printHelpPage("peek");
        if (std.mem.eql(u8, arg, "--scrollback")) {
            scrollback = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("peek", "unknown flag '{s}'", .{arg});
        } else if (name_arg == null) {
            name_arg = arg;
        } else {
            usageFail("peek", "unexpected argument '{s}'", .{arg});
        }
    }
    const want = name_arg orelse usageFail("peek", "a session name is required", .{});

    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);

    const result = try mustControl(alloc, dir, name, &.{
        "peek", if (scrollback) "scrollback" else "screen",
    });
    defer alloc.free(result.text);
    if (!result.ok) fail(exit_runtime, "{s}", .{result.text});

    const peek = parsePeek(result.text) orelse
        fail(exit_runtime, "malformed peek response", .{});

    if (!json) {
        try stdoutWrite(peek.screen);
        if (peek.screen.len > 0 and peek.screen[peek.screen.len - 1] != '\n') {
            try stdoutWrite("\n");
        }
        return;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"session\":");
    try appendJsonString(alloc, &out, name);
    try out.appendSlice(alloc, ",\"title\":");
    try appendJsonString(alloc, &out, peek.title);
    const geo = try std.fmt.allocPrint(
        alloc,
        ",\"rows\":{d},\"cols\":{d},\"cursor\":{{\"row\":{d},\"col\":{d}}},\"screen\":",
        .{ peek.rows, peek.cols, peek.cursor_row, peek.cursor_col },
    );
    defer alloc.free(geo);
    try out.appendSlice(alloc, geo);
    try appendJsonString(alloc, &out, peek.screen);
    try out.appendSlice(alloc, "}\n");
    try stdoutWrite(out.items);
}

/// How long output must stay quiet for `wait --idle` to fire.
const idle_settle_ms: i64 = 2000;

fn cmdWait(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var name_arg: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var idle = false;
    var timeout_str: []const u8 = "30s";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("wait");
        if (std.mem.eql(u8, arg, "--idle")) {
            idle = true;
        } else if (flagValue("wait", "--text", args, &i)) |v| {
            text = v;
        } else if (flagValue("wait", "--timeout", args, &i)) |v| {
            timeout_str = v;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("wait", "unknown flag '{s}'", .{arg});
        } else if (name_arg == null) {
            name_arg = arg;
        } else {
            usageFail("wait", "unexpected argument '{s}'", .{arg});
        }
    }

    if ((text != null) == idle) {
        usageFail("wait", "exactly one of --text or --idle is required", .{});
    }
    const want = name_arg orelse usageFail("wait", "a session name is required", .{});
    const timeout_ms = parseDurationMs(timeout_str) orelse
        usageFail("wait", "bad duration '{s}' (use 500ms, 2s, 1m, 4h, 1d)", .{timeout_str});

    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);

    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        if (text) |needle| {
            const result = try mustControl(alloc, dir, name, &.{ "peek", "screen" });
            defer alloc.free(result.text);
            if (!result.ok) fail(exit_runtime, "{s}", .{result.text});
            const peek = parsePeek(result.text) orelse
                fail(exit_runtime, "malformed peek response", .{});
            if (std.mem.indexOf(u8, peek.screen, needle) != null) return;
        } else {
            const info = try sessionInfo(alloc, dir, name) orelse
                fail(exit_no_session, "no session named {s}", .{name});
            defer alloc.free(info.text);
            if (info.out_idle_ms >= idle_settle_ms) return;
        }
        if (std.time.milliTimestamp() >= deadline) {
            fail(exit_timeout, "wait: timed out after {s}", .{timeout_str});
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn cmdKill(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var all = false;
    var name_arg: ?[]const u8 = null;
    for (args) |arg| {
        if (isHelpFlag(arg)) return printHelpPage("kill");
        if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("kill", "unknown flag '{s}'", .{arg});
        } else if (name_arg == null) {
            name_arg = arg;
        } else {
            usageFail("kill", "unexpected argument '{s}'", .{arg});
        }
    }
    if (all and name_arg != null) {
        usageFail("kill", "--all cannot be combined with a session name", .{});
    }

    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);

    if (all) {
        const sessions = try paths.listSessions(alloc, dir);
        defer {
            for (sessions) |s| alloc.free(s);
            alloc.free(sessions);
        }
        for (sessions) |name| {
            const sock = try paths.socketPath(alloc, dir, name);
            defer alloc.free(sock);
            const result = client.control(alloc, sock, &.{"quit"}) catch {
                std.fs.cwd().deleteFile(sock) catch {};
                continue;
            };
            alloc.free(result.text);
            try stdoutPrint(alloc, "{s}\n", .{name});
        }
        return;
    }

    const want = name_arg orelse usageFail("kill", "a session name or --all is required", .{});
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);
    const result = try mustControl(alloc, dir, name, &.{"quit"});
    defer alloc.free(result.text);
    if (!result.ok) fail(exit_runtime, "{s}", .{result.text});
}

fn cmdRename(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var old_arg: ?[]const u8 = null;
    var new_arg: ?[]const u8 = null;
    for (args) |arg| {
        if (isHelpFlag(arg)) return printHelpPage("rename");
        if (arg.len > 0 and arg[0] == '-') {
            usageFail("rename", "unknown flag '{s}'", .{arg});
        } else if (old_arg == null) {
            old_arg = arg;
        } else if (new_arg == null) {
            new_arg = arg;
        } else {
            usageFail("rename", "unexpected argument '{s}'", .{arg});
        }
    }
    const want = old_arg orelse usageFail("rename", "a session name is required", .{});
    const new_name = new_arg orelse usageFail("rename", "a new session name is required", .{});
    paths.validateName(new_name) catch
        usageFail("rename", "invalid session name '{s}'", .{new_name});

    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);

    const result = try mustControl(alloc, dir, name, &.{ "rename", new_name });
    defer alloc.free(result.text);
    if (!result.ok) fail(exit_runtime, "{s}", .{result.text});
}

fn cmdVersion(alloc: std.mem.Allocator) !void {
    try stdoutPrint(alloc, "boo {s}\n", .{version});
}

fn cmdHelp(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    _ = alloc;
    if (args.len == 0) return stdoutWrite(help.overview);
    if (args.len > 1) usageFail("help", "expected one help page", .{});

    const topic = args[0];
    if (std.mem.eql(u8, topic, "--all")) {
        try stdoutWrite(help.overview);
        for (&help.commands) |*entry| {
            try stdoutWrite("\n");
            try stdoutWrite(entry.body);
        }
        for (&help.topics) |*entry| {
            try stdoutWrite("\n");
            try stdoutWrite(entry.body);
        }
        return;
    }
    if (help.find(topic)) |entry| return stdoutWrite(entry.body);
    usageFail("help", "no help for '{s}'", .{topic});
}

// -- Output helpers -------------------------------------------------------

fn appendPadded(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    width: usize,
) !void {
    try out.appendSlice(alloc, text);
    var i = text.len;
    while (i < width) : (i += 1) try out.append(alloc, ' ');
}

/// Append a JSON string literal, escaping per RFC 8259.
fn appendJsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (byte < 0x20) {
                    var buf: [8]u8 = undefined;
                    const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{byte}) catch unreachable;
                    try out.appendSlice(alloc, esc);
                } else {
                    try out.append(alloc, byte);
                }
            },
        }
    }
    try out.append(alloc, '"');
}

/// Parse a duration like 500ms, 2s, 1m, 4h (or 4hr), 1d. Returns
/// milliseconds.
fn parseDurationMs(s: []const u8) ?u64 {
    const Unit = struct { suffix: []const u8, ms: u64 };
    // "ms" must match before "s", and "hr" before "h".
    const units = [_]Unit{
        .{ .suffix = "ms", .ms = 1 },
        .{ .suffix = "hr", .ms = std.time.ms_per_hour },
        .{ .suffix = "s", .ms = std.time.ms_per_s },
        .{ .suffix = "m", .ms = std.time.ms_per_min },
        .{ .suffix = "h", .ms = std.time.ms_per_hour },
        .{ .suffix = "d", .ms = std.time.ms_per_day },
    };
    for (units) |unit| {
        if (std.mem.endsWith(u8, s, unit.suffix)) {
            const n = std.fmt.parseInt(u64, s[0 .. s.len - unit.suffix.len], 10) catch return null;
            return std.math.mul(u64, n, unit.ms) catch null;
        }
    }
    return null;
}

/// Human idle durations for `ls`: 12s, 5m, 3h.
fn fmtIdle(buf: []u8, ms: i64) []const u8 {
    const s = @divTrunc(@max(0, ms), std.time.ms_per_s);
    if (s < 60) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "?";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(s, 60)}) catch "?";
    return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(s, 3600)}) catch "?";
}

// -- Daemon plumbing ------------------------------------------------------

fn runDaemon(
    alloc: std.mem.Allocator,
    name: []const u8,
    sock: []const u8,
    listen_fd: posix.fd_t,
    argv: []const []const u8,
) noreturn {
    _ = posix.setsid() catch {};

    // Detach stdio. Keep stderr pointed at BOO_LOG if set so std.log
    // output is preserved for debugging.
    const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch posix.exit(1);
    posix.dup2(devnull, 0) catch {};
    posix.dup2(devnull, 1) catch {};
    if (posix.getenv("BOO_LOG")) |log_path| blk: {
        const fd = posix.open(log_path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
        }, 0o600) catch break :blk;
        posix.dup2(fd, 2) catch {};
        posix.close(fd);
    } else {
        posix.dup2(devnull, 2) catch {};
    }
    if (devnull > 2) posix.close(devnull);

    daemonpkg.Daemon.run(alloc, .{
        .name = name,
        .socket_path = sock,
        .listen_fd = listen_fd,
        .argv = argv,
    }) catch |err| {
        std.log.err("daemon failed: {}", .{err});
        posix.exit(1);
    };
    posix.exit(0);
}

fn bindListen(alloc: std.mem.Allocator, sock_path: []const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    if (sock_path.len >= addr.path.len) return error.NameTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..sock_path.len], sock_path);

    posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| switch (err) {
        error.AddressInUse => {
            // Either a live session or a stale socket file.
            if (client.connect(alloc, sock_path)) |probe| {
                posix.close(probe);
                return error.SessionExists;
            } else |_| {
                try std.fs.cwd().deleteFile(sock_path);
                try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
            }
        },
        else => return err,
    };

    try posix.listen(fd, 8);
    return fd;
}

// -- Tests ----------------------------------------------------------------

test "parseDurationMs" {
    try std.testing.expectEqual(@as(?u64, 500), parseDurationMs("500ms"));
    try std.testing.expectEqual(@as(?u64, 2000), parseDurationMs("2s"));
    try std.testing.expectEqual(@as(?u64, 60_000), parseDurationMs("1m"));
    try std.testing.expectEqual(@as(?u64, 4 * 3_600_000), parseDurationMs("4h"));
    try std.testing.expectEqual(@as(?u64, 4 * 3_600_000), parseDurationMs("4hr"));
    try std.testing.expectEqual(@as(?u64, 10 * 86_400_000), parseDurationMs("10d"));
    try std.testing.expectEqual(@as(?u64, null), parseDurationMs("2"));
    try std.testing.expectEqual(@as(?u64, null), parseDurationMs("s"));
    try std.testing.expectEqual(@as(?u64, null), parseDurationMs("hr"));
    try std.testing.expectEqual(@as(?u64, null), parseDurationMs("2x"));
}

test "appendKey named keys" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try std.testing.expect(appendKey(alloc, &out, "Enter"));
    try std.testing.expect(appendKey(alloc, &out, "C-c"));
    try std.testing.expect(appendKey(alloc, &out, "up"));
    try std.testing.expectEqualStrings("\r\x03\x1b[A", out.items);
    try std.testing.expect(!appendKey(alloc, &out, "C-1"));
    try std.testing.expect(!appendKey(alloc, &out, "banana"));
}

test "appendJsonString escapes" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendJsonString(alloc, &out, "a\"b\\c\nd\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", out.items);
}

test "parsePeek" {
    const peek = parsePeek("24\t80\t3\t7\tvim\nline1\nline2").?;
    try std.testing.expectEqual(@as(u32, 24), peek.rows);
    try std.testing.expectEqual(@as(u32, 80), peek.cols);
    try std.testing.expectEqual(@as(u32, 3), peek.cursor_row);
    try std.testing.expectEqual(@as(u32, 7), peek.cursor_col);
    try std.testing.expectEqualStrings("vim", peek.title);
    try std.testing.expectEqualStrings("line1\nline2", peek.screen);
}

test "fmtIdle" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0s", fmtIdle(&buf, 400));
    try std.testing.expectEqualStrings("12s", fmtIdle(&buf, 12_500));
    try std.testing.expectEqualStrings("5m", fmtIdle(&buf, 5 * 60_000));
    try std.testing.expectEqualStrings("2h", fmtIdle(&buf, 2 * 3_600_000));
}

test {
    _ = @import("protocol.zig");
    _ = @import("paths.zig");
    _ = @import("keys.zig");
    _ = @import("pty.zig");
    _ = @import("altscreen.zig");
    _ = @import("window.zig");
    _ = @import("daemon.zig");
    _ = @import("client.zig");
    _ = @import("help.zig");
    _ = @import("ui.zig");
}
