//! PTY allocation and child process spawning.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

/// Terminal ioctl request codes. Zig's std does not define the set
/// variants for darwin, so the (ABI-stable) BSD values are spelled out.
pub const Tio = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        pub const IOCGWINSZ: c_ulong = 0x40087468;
        pub const IOCSWINSZ: c_ulong = 0x80087467;
        pub const IOCSCTTY: c_ulong = 0x20007461;
    },
    .linux => struct {
        pub const IOCGWINSZ: c_ulong = std.os.linux.T.IOCGWINSZ;
        pub const IOCSWINSZ: c_ulong = std.os.linux.T.IOCSWINSZ;
        pub const IOCSCTTY: c_ulong = std.os.linux.T.IOCSCTTY;
    },
    else => @compileError("unsupported OS"),
};

pub const Winsize = std.posix.winsize;

pub fn makeWinsize(rows: u16, cols: u16) Winsize {
    return .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
}

pub const Pty = struct {
    master: posix.fd_t,
    slave_path: [128]u8,
    slave_path_len: usize,

    pub fn open(size: Winsize) !Pty {
        const master = posix_openpt(@bitCast(@as(u32, @bitCast(posix.O{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }))));
        if (master < 0) return error.OpenPtyFailed;
        errdefer posix.close(master);

        if (grantpt(master) != 0) return error.OpenPtyFailed;
        if (unlockpt(master) != 0) return error.OpenPtyFailed;

        var self: Pty = .{
            .master = master,
            .slave_path = undefined,
            .slave_path_len = 0,
        };
        if (ptsname_r(master, &self.slave_path, self.slave_path.len) != 0) {
            return error.OpenPtyFailed;
        }
        self.slave_path_len = std.mem.indexOfScalar(u8, &self.slave_path, 0) orelse {
            return error.OpenPtyFailed;
        };

        try setSize(master, size);
        return self;
    }

    pub fn slavePath(self: *const Pty) [:0]const u8 {
        return self.slave_path[0..self.slave_path_len :0];
    }

    pub fn setSize(fd: posix.fd_t, size: Winsize) !void {
        if (ioctl(fd, Tio.IOCSWINSZ, @intFromPtr(&size)) != 0) {
            return error.IoctlFailed;
        }
    }
};

pub fn getSize(fd: posix.fd_t) !Winsize {
    var ws: Winsize = undefined;
    if (ioctl(fd, Tio.IOCGWINSZ, @intFromPtr(&ws)) != 0) {
        return error.IoctlFailed;
    }
    return ws;
}

pub const SpawnOptions = struct {
    argv: []const []const u8,
    env: *std.process.EnvMap,
    size: Winsize,
};

pub const Spawned = struct {
    pid: posix.pid_t,
    master: posix.fd_t,
};

/// Fork a child running argv with a fresh PTY as its controlling
/// terminal. Returns the child pid and the PTY master fd.
pub fn spawnInPty(alloc: std.mem.Allocator, opts: SpawnOptions) !Spawned {
    const pty = try Pty.open(opts.size);
    errdefer posix.close(pty.master);

    // Prepare exec arguments before forking; only async-signal-safe
    // calls are allowed in the child.
    const argv0 = try alloc.dupeZ(u8, opts.argv[0]);
    defer alloc.free(argv0);
    const argv = try alloc.allocSentinel(?[*:0]const u8, opts.argv.len, null);
    defer alloc.free(argv);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    for (opts.argv, 0..) |arg, i| argv[i] = try arena.allocator().dupeZ(u8, arg);
    const envp = try std.process.createEnvironFromMap(arena.allocator(), opts.env, .{});

    const slave_path = pty.slavePath();

    const pid = try posix.fork();
    if (pid == 0) {
        // Child. Become a session leader and acquire the PTY slave as
        // the controlling terminal.
        _ = posix.setsid() catch posix.exit(127);
        const slave = posix.openZ(slave_path, .{ .ACCMODE = .RDWR }, 0) catch posix.exit(127);
        if (ioctl(slave, Tio.IOCSCTTY, @as(c_ulong, 0)) != 0) posix.exit(127);

        posix.dup2(slave, 0) catch posix.exit(127);
        posix.dup2(slave, 1) catch posix.exit(127);
        posix.dup2(slave, 2) catch posix.exit(127);
        if (slave > 2) posix.close(slave);
        posix.close(pty.master);

        const err = posix.execvpeZ(argv0, argv, envp);
        _ = err catch {};
        posix.exit(127);
    }

    return .{ .pid = pid, .master = pty.master };
}
