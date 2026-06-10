//! Client side: interactive attach (raw TTY <-> daemon socket) and
//! one-shot control commands (-X).

const std = @import("std");
const posix = std.posix;

const protocol = @import("protocol.zig");
const ptypkg = @import("pty.zig");
const window = @import("window.zig");

const log = std.log.scoped(.client);

/// The attached client renders inside the terminal's own alternate
/// screen (like screen and tmux), so detaching restores the user's
/// pre-attach shell view. `1049h` also saves the cursor, which the
/// final `1049l` restores after undoing any state the session set.
const enter_sequence = "\x1b[?1049h";
const restore_sequence = window.reset_state_sequence ++ "\x1b[?1049l";

pub const Outcome = enum { detached, stolen, ended, lost };

var signal_pipe: posix.fd_t = -1;

fn handleSignal(sig: c_int) callconv(.c) void {
    if (signal_pipe >= 0) {
        const byte: [1]u8 = .{@intCast(sig & 0xff)};
        _ = posix.write(signal_pipe, &byte) catch {};
    }
}

pub fn connect(alloc: std.mem.Allocator, socket_path: []const u8) !posix.fd_t {
    _ = alloc;
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    if (socket_path.len >= addr.path.len) return error.NameTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);
    try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    return fd;
}

/// Attach the calling terminal to a session. Blocks until detach or
/// session end. Stdin/stdout must be the controlling TTY.
pub fn attach(alloc: std.mem.Allocator, socket_path: []const u8) !Outcome {
    const tty: posix.fd_t = 0;
    if (!posix.isatty(tty)) return error.NotATty;

    const sock = try connect(alloc, socket_path);
    defer posix.close(sock);

    // Signal plumbing: SIGWINCH resizes, SIGTERM/SIGHUP detach.
    const pipe_fds = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);
    signal_pipe = pipe_fds[1];
    defer signal_pipe = -1;
    const sigact: posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sigact, null);
    posix.sigaction(posix.SIG.TERM, &sigact, null);
    posix.sigaction(posix.SIG.HUP, &sigact, null);
    posix.sigaction(posix.SIG.PIPE, &.{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    // Raw mode, then move the terminal onto its alternate screen so
    // the session view never disturbs the user's shell scrollback.
    const saved = try posix.tcgetattr(tty);
    var raw = saved;
    rawMode(&raw);
    try posix.tcsetattr(tty, .FLUSH, raw);
    defer restoreTty(tty, saved);
    try protocol.writeAll(1, enter_sequence);

    // Handshake with our current size.
    const ws = ptypkg.getSize(tty) catch ptypkg.makeWinsize(24, 80);
    try protocol.writeMsg(sock, .attach, &(protocol.SizePayload{
        .rows = ws.row,
        .cols = ws.col,
    }).encode());

    var decoder: protocol.Decoder = .init(alloc);
    defer decoder.deinit();

    var buf: [32 * 1024]u8 = undefined;
    var fds = [_]posix.pollfd{
        .{ .fd = tty, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = sock, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = pipe_fds[0], .events = posix.POLL.IN, .revents = 0 },
    };

    var stdin_open = true;
    while (true) {
        for (&fds) |*pfd| pfd.revents = 0;
        // poll() ignores negative fds; once stdin is gone we only wait
        // for the daemon's detach acknowledgement.
        fds[0].fd = if (stdin_open) tty else -1;
        _ = try posix.poll(&fds, -1);

        // Signals.
        if (fds[2].revents != 0) {
            while (true) {
                const n = posix.read(pipe_fds[0], &buf) catch 0;
                if (n == 0) break;
                for (buf[0..n]) |sig| switch (sig) {
                    posix.SIG.WINCH => {
                        const new_ws = ptypkg.getSize(tty) catch continue;
                        protocol.writeMsg(sock, .resize, &(protocol.SizePayload{
                            .rows = new_ws.row,
                            .cols = new_ws.col,
                        }).encode()) catch {};
                    },
                    else => protocol.writeMsg(sock, .detach_req, "") catch {},
                };
                if (n < buf.len) break;
            }
        }

        // Terminal input -> daemon.
        if (stdin_open and fds[0].revents != 0) {
            const n = posix.read(tty, &buf) catch 0;
            if (n == 0) {
                // TTY is gone; ask for an orderly detach.
                stdin_open = false;
                protocol.writeMsg(sock, .detach_req, "") catch {};
            } else {
                try protocol.writeMsg(sock, .input, buf[0..n]);
            }
        }

        // Daemon -> terminal output and lifecycle messages.
        if (fds[1].revents != 0) {
            const n = posix.read(sock, &buf) catch 0;
            if (n == 0) return .lost;
            try decoder.feed(buf[0..n]);
            while (try decoder.next()) |msg| {
                switch (msg.type) {
                    .output => try protocol.writeAll(1, msg.payload),
                    .detached => {
                        return if (std.mem.eql(u8, msg.payload, "stolen")) .stolen else .detached;
                    },
                    .exit => return .ended,
                    else => {},
                }
            }
        }
    }
}

fn rawMode(t: *posix.termios) void {
    t.iflag.IGNBRK = false;
    t.iflag.BRKINT = false;
    t.iflag.PARMRK = false;
    t.iflag.ISTRIP = false;
    t.iflag.INLCR = false;
    t.iflag.IGNCR = false;
    t.iflag.ICRNL = false;
    t.iflag.IXON = false;
    t.oflag.OPOST = false;
    t.lflag.ECHO = false;
    t.lflag.ECHONL = false;
    t.lflag.ICANON = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;
    t.cflag.CSIZE = .CS8;
    t.cflag.PARENB = false;
    t.cc[@intFromEnum(posix.V.MIN)] = 1;
    t.cc[@intFromEnum(posix.V.TIME)] = 0;
}

fn restoreTty(tty: posix.fd_t, saved: posix.termios) void {
    protocol.writeAll(1, restore_sequence) catch {};
    posix.tcsetattr(tty, .FLUSH, saved) catch {};
}

pub const ControlResult = struct {
    ok: bool,
    /// Allocated; caller frees.
    text: []u8,
};

/// Send a single control command (-X) and wait for the reply.
pub fn control(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    argv: []const []const u8,
) !ControlResult {
    const sock = try connect(alloc, socket_path);
    defer posix.close(sock);

    const payload = try protocol.encodeArgv(alloc, argv);
    defer alloc.free(payload);
    try protocol.writeMsg(sock, .command, payload);

    var decoder: protocol.Decoder = .init(alloc);
    defer decoder.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(sock, &buf) catch 0;
        if (n == 0) return error.ConnectionLost;
        try decoder.feed(buf[0..n]);
        while (try decoder.next()) |msg| {
            switch (msg.type) {
                .ok => return .{ .ok = true, .text = try alloc.dupe(u8, msg.payload) },
                .err => return .{ .ok = false, .text = try alloc.dupe(u8, msg.payload) },
                // Skip async frames (e.g. exit broadcast racing a quit).
                else => {},
            }
        }
    }
}
