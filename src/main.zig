//! ghostscreen: a GNU screen style terminal multiplexer built on
//! libghostty (ghostty-vt) for terminal emulation.

const std = @import("std");
const posix = std.posix;

const client = @import("client.zig");
const daemonpkg = @import("daemon.zig");
const paths = @import("paths.zig");
const protocol = @import("protocol.zig");

pub const version = "0.0.1";

const usage =
    \\usage: ghostscreen [options] [command ...]
    \\
    \\Start a new session running `command` (default: $SHELL) and attach.
    \\
    \\options:
    \\  -S <name>     session name (default: pid of the creating process)
    \\  -d -m         start the session detached (do not attach)
    \\  -r [name]     reattach to a session (steals an attached session)
    \\  -ls, --list   list sessions
    \\  -X <cmd ...>  send a control command to a session (see below)
    \\  -h, --help    show this help
    \\  -V, --version show version
    \\
    \\key bindings (prefix C-a):
    \\  c new window     n/p next/prev      0-9 select window
    \\  d detach         k kill window      w list windows
    \\  a send literal C-a   C-a a second C-a switches to previous window
    \\  l redraw
    \\
    \\control commands (-X):
    \\  stuff <text>       send text to the active window (\n \r \t \e \xHH)
    \\  hardcopy <path>    write a plain-text dump of the active window
    \\  new-window [cmd]   create a window
    \\  select <n> | next | prev | windows | kill-window | info | quit
    \\
    \\environment:
    \\  GHOSTSCREEN_DIR    socket directory (default: $XDG_RUNTIME_DIR/ghostscreen)
    \\
;

const Action = union(enum) {
    create: struct { detached: bool },
    reattach,
    list,
    command,
    help,
    show_version,
};

const Args = struct {
    action: Action = .{ .create = .{ .detached = false } },
    session: ?[]const u8 = null,
    rest: []const []const u8 = &.{},
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("ghostscreen: " ++ fmt ++ "\n", args);
    posix.exit(1);
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

    const args = parseArgs(argv[1..]);

    switch (args.action) {
        .help => {
            std.debug.print("{s}", .{usage});
            return;
        },
        .show_version => {
            std.debug.print("ghostscreen {s}\n", .{version});
            return;
        },
        .list => try cmdList(alloc),
        .command => try cmdControl(alloc, args),
        .reattach => try cmdReattach(alloc, args),
        .create => |c| try cmdCreate(alloc, args, c.detached),
    }
}

fn parseArgs(argv: []const [:0]const u8) Args {
    var args: Args = .{};
    var detached = false;
    var create_only = false;
    var i: usize = 0;
    var rest_start: ?usize = null;

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            rest_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "-S")) {
            i += 1;
            if (i >= argv.len) fatal("-S requires a session name", .{});
            args.session = argv[i];
        } else if (std.mem.eql(u8, arg, "-d")) {
            detached = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            create_only = true;
        } else if (std.mem.eql(u8, arg, "-r")) {
            args.action = .reattach;
            if (i + 1 < argv.len and argv[i + 1].len > 0 and argv[i + 1][0] != '-') {
                i += 1;
                args.session = argv[i];
            }
        } else if (std.mem.eql(u8, arg, "-ls") or std.mem.eql(u8, arg, "--list")) {
            args.action = .list;
        } else if (std.mem.eql(u8, arg, "-X")) {
            args.action = .command;
            rest_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            args.action = .help;
            return args;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            args.action = .show_version;
            return args;
        } else if (arg.len > 0 and arg[0] == '-') {
            fatal("unknown option: {s} (see --help)", .{arg});
        } else {
            rest_start = i;
            break;
        }
    }

    if (rest_start) |start| {
        if (start < argv.len) {
            args.rest = @ptrCast(argv[start..]);
        }
    }

    if (detached or create_only) {
        if (!(detached and create_only)) fatal("-d and -m must be used together", .{});
        args.action = .{ .create = .{ .detached = true } };
    }
    return args;
}

fn cmdList(alloc: std.mem.Allocator) !void {
    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);
    const sessions = try paths.listSessions(alloc, dir);
    defer {
        for (sessions) |s| alloc.free(s);
        alloc.free(sessions);
    }

    if (sessions.len == 0) {
        std.debug.print("No sessions in {s}.\n", .{dir});
        return;
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const out = &stdout_writer.interface;

    for (sessions) |name| {
        const sock = try paths.socketPath(alloc, dir, name);
        defer alloc.free(sock);
        const result = client.control(alloc, sock, &.{"info"}) catch {
            // Stale socket: the daemon is gone.
            std.fs.cwd().deleteFile(sock) catch {};
            continue;
        };
        defer alloc.free(result.text);
        // info is "name\t<n> windows\tAttached|Detached"
        try out.print("\t{s}\n", .{result.text});
    }
    try out.flush();
}

fn resolveSession(alloc: std.mem.Allocator, args: Args, dir: []const u8) ![]u8 {
    if (args.session) |name| {
        paths.validateName(name) catch fatal("invalid session name: {s}", .{name});
        return alloc.dupe(u8, name);
    }
    const sessions = try paths.listSessions(alloc, dir);
    defer {
        for (sessions) |s| alloc.free(s);
        alloc.free(sessions);
    }
    if (sessions.len == 0) fatal("no sessions (use ghostscreen to create one)", .{});
    if (sessions.len > 1) fatal("multiple sessions; pick one with -S (see -ls)", .{});
    return alloc.dupe(u8, sessions[0]);
}

fn cmdControl(alloc: std.mem.Allocator, args: Args) !void {
    if (args.rest.len == 0) fatal("-X requires a command", .{});
    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, args, dir);
    defer alloc.free(name);
    const sock = try paths.socketPath(alloc, dir, name);
    defer alloc.free(sock);

    const result = client.control(alloc, sock, args.rest) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => fatal("no session named {s}", .{name}),
        else => return err,
    };
    defer alloc.free(result.text);

    if (result.ok) {
        if (result.text.len > 0) {
            var buf: [4096]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&buf);
            const out = &stdout_writer.interface;
            try out.print("{s}\n", .{result.text});
            try out.flush();
        }
    } else {
        std.debug.print("ghostscreen: {s}\n", .{result.text});
        posix.exit(1);
    }
}

fn cmdReattach(alloc: std.mem.Allocator, args: Args) !void {
    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, args, dir);
    defer alloc.free(name);
    const sock = try paths.socketPath(alloc, dir, name);
    defer alloc.free(sock);
    try attachLoop(alloc, sock, name);
}

fn cmdCreate(alloc: std.mem.Allocator, args: Args, detached: bool) !void {
    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);

    var name_buf: [32]u8 = undefined;
    const name = args.session orelse paths.defaultName(&name_buf);
    paths.validateName(name) catch fatal("invalid session name: {s}", .{name});

    const sock = try paths.socketPath(alloc, dir, name);
    defer alloc.free(sock);

    const listen_fd = bindListen(alloc, sock) catch |err| switch (err) {
        error.SessionExists => fatal("session {s} already exists (use -r to attach)", .{name}),
        else => return err,
    };

    // Fork the session daemon. The listening socket already exists, so
    // there is no race between daemon startup and the first attach.
    // GHOSTSCREEN_FOREGROUND=1 keeps the daemon in the foreground, which
    // is useful for debugging.
    if (posix.getenv("GHOSTSCREEN_FOREGROUND") != null) {
        try daemonpkg.Daemon.run(alloc, .{
            .name = name,
            .socket_path = sock,
            .listen_fd = listen_fd,
            .argv = args.rest,
        });
        return;
    }
    const pid = try posix.fork();
    if (pid == 0) {
        runDaemon(alloc, name, sock, listen_fd, args.rest);
    }
    posix.close(listen_fd);

    if (detached) {
        std.debug.print("ghostscreen: started detached session {s}\n", .{name});
        return;
    }
    try attachLoop(alloc, sock, name);
}

fn runDaemon(
    alloc: std.mem.Allocator,
    name: []const u8,
    sock: []const u8,
    listen_fd: posix.fd_t,
    argv: []const []const u8,
) noreturn {
    _ = posix.setsid() catch {};

    // Detach stdio. Keep stderr pointed at GHOSTSCREEN_LOG if set so
    // std.log output is preserved for debugging.
    const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch posix.exit(1);
    posix.dup2(devnull, 0) catch {};
    posix.dup2(devnull, 1) catch {};
    if (posix.getenv("GHOSTSCREEN_LOG")) |log_path| blk: {
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

fn attachLoop(alloc: std.mem.Allocator, sock: []const u8, name: []const u8) !void {
    const outcome = client.attach(alloc, sock) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => fatal("no session named {s}", .{name}),
        error.NotATty => fatal("attach requires a terminal", .{}),
        else => return err,
    };
    switch (outcome) {
        .detached => std.debug.print("[detached from {s}]\n", .{name}),
        .stolen => std.debug.print("[session {s} attached elsewhere]\n", .{name}),
        .ended => std.debug.print("[session {s} ended]\n", .{name}),
        .lost => {
            std.debug.print("[lost connection to {s}]\n", .{name});
            posix.exit(1);
        },
    }
}

test {
    _ = @import("protocol.zig");
    _ = @import("paths.zig");
    _ = @import("keys.zig");
    _ = @import("pty.zig");
    _ = @import("window.zig");
    _ = @import("daemon.zig");
    _ = @import("client.zig");
}
