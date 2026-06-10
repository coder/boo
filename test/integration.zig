//! End-to-end tests that drive the real ghostscreen binary through a
//! real PTY: a test "terminal" (PTY master) hosts the attach client as
//! its controlling terminal, exactly like a user's terminal would.

const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");

const exe_path: []const u8 = build_options.exe_path;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn kill(pid: std.c.pid_t, sig: c_int) c_int;

const default_timeout_ms: u64 = 10_000;

/// Terminal ioctl request codes; Zig's std lacks the darwin set variants.
const Tio = switch (@import("builtin").os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        const IOCSWINSZ: c_ulong = 0x80087467;
        const IOCSCTTY: c_ulong = 0x20007461;
    },
    .linux => struct {
        const IOCSWINSZ: c_ulong = std.os.linux.T.IOCSWINSZ;
        const IOCSCTTY: c_ulong = std.os.linux.T.IOCSCTTY;
    },
    else => @compileError("unsupported OS"),
};

/// Per-test environment: an isolated socket directory under /tmp (kept
/// short because of sockaddr_un path limits).
const Harness = struct {
    alloc: std.mem.Allocator,
    dir: []u8,

    fn init(alloc: std.mem.Allocator) !Harness {
        var random_bytes: [6]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var suffix: [12]u8 = undefined;
        const hex = std.fmt.bufPrint(&suffix, "{x}", .{&random_bytes}) catch unreachable;
        const dir = try std.fmt.allocPrint(alloc, "/tmp/gstest-{s}", .{hex});
        errdefer alloc.free(dir);
        try std.fs.cwd().makePath(dir);
        return .{ .alloc = alloc, .dir = dir };
    }

    fn deinit(self: *Harness) void {
        // Best effort: terminate any session daemons still running.
        if (std.fs.cwd().openDir(self.dir, .{ .iterate = true })) |d| {
            var iter_dir = d;
            defer iter_dir.close();
            var it = iter_dir.iterate();
            while (it.next() catch null) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
                const name = entry.name[0 .. entry.name.len - ".sock".len];
                const result = self.control(name, &.{"quit"}) catch continue;
                self.alloc.free(result.stdout);
                self.alloc.free(result.stderr);
            }
        } else |_| {}
        std.Thread.sleep(50 * std.time.ns_per_ms);
        std.fs.cwd().deleteTree(self.dir) catch {};
        self.alloc.free(self.dir);
    }

    fn run(self: *Harness, argv: []const []const u8) !std.process.Child.RunResult {
        var full_argv: std.ArrayList([]const u8) = .empty;
        defer full_argv.deinit(self.alloc);
        try full_argv.append(self.alloc, exe_path);
        try full_argv.appendSlice(self.alloc, argv);

        var env = try std.process.getEnvMap(self.alloc);
        defer env.deinit();
        try env.put("GHOSTSCREEN_DIR", self.dir);

        return std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = full_argv.items,
            .env_map = &env,
        });
    }

    fn control(self: *Harness, session: []const u8, cmd: []const []const u8) !std.process.Child.RunResult {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        try argv.appendSlice(self.alloc, &.{ "-S", session, "-X" });
        try argv.appendSlice(self.alloc, cmd);
        return self.run(argv.items);
    }

    /// Run a control command and require success.
    fn mustControl(self: *Harness, session: []const u8, cmd: []const []const u8) !void {
        const result = try self.control(session, cmd);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print("control {s} failed: {s}\n", .{ cmd[0], result.stderr });
            return error.ControlFailed;
        }
    }

    fn startDetached(self: *Harness, session: []const u8, cmd: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        try argv.appendSlice(self.alloc, &.{ "-d", "-m", "-S", session });
        try argv.appendSlice(self.alloc, cmd);
        const result = try self.run(argv.items);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print("startDetached failed: {s}\n", .{result.stderr});
            return error.StartFailed;
        }
        try self.waitSessionUp(session);
    }

    fn waitSessionUp(self: *Harness, session: []const u8) !void {
        var deadline = Deadline.init(default_timeout_ms);
        while (true) {
            const result = try self.control(session, &.{"info"});
            defer self.alloc.free(result.stdout);
            defer self.alloc.free(result.stderr);
            if (result.term == .Exited and result.term.Exited == 0) return;
            try deadline.tick("session did not come up");
        }
    }

    /// Poll the active window's screen contents until `needle` shows up.
    fn waitHardcopyContains(self: *Harness, session: []const u8, needle: []const u8) ![]u8 {
        const path = try std.fmt.allocPrint(self.alloc, "{s}/hardcopy.txt", .{self.dir});
        defer self.alloc.free(path);

        var deadline = Deadline.init(default_timeout_ms);
        var last: ?[]u8 = null;
        errdefer if (last) |l| self.alloc.free(l);
        while (true) {
            try self.mustControl(session, &.{ "hardcopy", path });
            if (last) |l| self.alloc.free(l);
            last = null;
            last = std.fs.cwd().readFileAlloc(self.alloc, path, 1 << 20) catch null;
            if (last) |content| {
                if (std.mem.indexOf(u8, content, needle) != null) return content;
            }
            deadline.tick("hardcopy never contained needle") catch |err| {
                std.debug.print("--- last hardcopy ---\n{s}\n---\n", .{last orelse "<none>"});
                return err;
            };
        }
    }
};

const Deadline = struct {
    end: i64,

    fn init(ms: u64) Deadline {
        return .{ .end = std.time.milliTimestamp() + @as(i64, @intCast(ms)) };
    }

    fn tick(self: *Deadline, comptime what: []const u8) !void {
        if (std.time.milliTimestamp() > self.end) {
            std.debug.print("timeout: " ++ what ++ "\n", .{});
            return error.Timeout;
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
};

/// A ghostscreen client process running on a real PTY owned by the test.
const PtyClient = struct {
    alloc: std.mem.Allocator,
    master: posix.fd_t,
    pid: posix.pid_t,
    output: std.ArrayList(u8) = .empty,
    exited: ?u32 = null,

    fn spawn(
        harness: *Harness,
        argv: []const []const u8,
        rows: u16,
        cols: u16,
    ) !PtyClient {
        const alloc = harness.alloc;

        // PTY pair.
        const master = posix_openpt(@bitCast(@as(u32, @bitCast(posix.O{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }))));
        if (master < 0) return error.OpenPtyFailed;
        errdefer posix.close(master);
        if (grantpt(master) != 0) return error.OpenPtyFailed;
        if (unlockpt(master) != 0) return error.OpenPtyFailed;
        var path_buf: [128]u8 = undefined;
        if (ptsname_r(master, &path_buf, path_buf.len) != 0) return error.OpenPtyFailed;
        const path_len = std.mem.indexOfScalar(u8, &path_buf, 0) orelse return error.OpenPtyFailed;
        const slave_path = path_buf[0..path_len :0];

        // Open the slave before setting the size: macOS rejects
        // TIOCSWINSZ on the master until the slave has been opened.
        const slave = posix.openZ(slave_path, .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }, 0) catch return error.OpenPtyFailed;
        errdefer posix.close(slave);

        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (ioctl(slave, Tio.IOCSWINSZ, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }

        // Exec args, prepared before fork.
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const argv0 = try arena.dupeZ(u8, exe_path);
        const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len + 1, null);
        argv_z[0] = argv0;
        for (argv, 1..) |arg, i| argv_z[i] = try arena.dupeZ(u8, arg);

        var env = try std.process.getEnvMap(arena);
        try env.put("GHOSTSCREEN_DIR", harness.dir);
        const envp = try std.process.createEnvironFromMap(arena, &env, .{});

        const pid = try posix.fork();
        if (pid == 0) {
            // Child: make the inherited PTY slave the controlling
            // terminal (login_tty pattern).
            _ = posix.setsid() catch posix.exit(127);
            if (ioctl(slave, Tio.IOCSCTTY, @as(c_ulong, 0)) != 0) {
                posix.exit(127);
            }
            posix.dup2(slave, 0) catch posix.exit(127);
            posix.dup2(slave, 1) catch posix.exit(127);
            posix.dup2(slave, 2) catch posix.exit(127);
            if (slave > 2) posix.close(slave);
            posix.close(master);
            const err = posix.execveZ(argv0, argv_z, envp);
            _ = err catch {};
            posix.exit(127);
        }

        posix.close(slave);
        return .{ .alloc = alloc, .master = master, .pid = pid };
    }

    fn deinit(self: *PtyClient) void {
        if (self.exited == null) {
            _ = kill(self.pid, posix.SIG.KILL);
            var status: c_int = undefined;
            _ = std.c.waitpid(self.pid, &status, 0);
        }
        posix.close(self.master);
        self.output.deinit(self.alloc);
    }

    fn send(self: *PtyClient, bytes: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) i += try posix.write(self.master, bytes[i..]);
    }

    fn setSize(self: *PtyClient, rows: u16, cols: u16) !void {
        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (ioctl(self.master, Tio.IOCSWINSZ, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }
    }

    fn pump(self: *PtyClient, timeout_ms: i32) !bool {
        var fds = [_]posix.pollfd{
            .{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 },
        };
        const n = try posix.poll(&fds, timeout_ms);
        if (n == 0) return false;
        var buf: [4096]u8 = undefined;
        const got = posix.read(self.master, &buf) catch |err| switch (err) {
            error.InputOutput => return error.ClientGone,
            else => return err,
        };
        if (got == 0) return error.ClientGone;
        try self.output.appendSlice(self.alloc, buf[0..got]);
        return true;
    }

    /// Read output until `needle` appears anywhere in the accumulated
    /// stream. Fails loudly with the captured output on timeout.
    fn waitFor(self: *PtyClient, needle: []const u8) !void {
        var deadline = Deadline.init(default_timeout_ms);
        while (std.mem.indexOf(u8, self.output.items, needle) == null) {
            _ = self.pump(100) catch |err| switch (err) {
                error.ClientGone => {
                    if (std.mem.indexOf(u8, self.output.items, needle) != null) return;
                    std.debug.print(
                        "client exited; output so far:\n{s}\n",
                        .{self.output.items},
                    );
                    return err;
                },
                else => return err,
            };
            deadline.tick("waiting for output") catch |err| {
                std.debug.print(
                    "--- waiting for {s} --- captured:\n{s}\n---\n",
                    .{ needle, self.output.items },
                );
                return err;
            };
        }
    }

    /// Drop accumulated output so later waitFor calls only see new data.
    fn clearOutput(self: *PtyClient) void {
        self.output.clearRetainingCapacity();
    }

    fn waitExit(self: *PtyClient) !u32 {
        if (self.exited) |code| return code;
        var deadline = Deadline.init(default_timeout_ms);
        while (true) {
            var status: c_int = undefined;
            const r = std.c.waitpid(self.pid, &status, std.c.W.NOHANG);
            if (r == self.pid) {
                const code: u32 = if (std.c.W.IFEXITED(@bitCast(status)))
                    std.c.W.EXITSTATUS(@bitCast(status))
                else
                    128;
                self.exited = code;
                return code;
            }
            // Keep draining the PTY so the client can't block on writes.
            _ = self.pump(0) catch {};
            try deadline.tick("waiting for client exit");
        }
    }
};

test "detached session: stuff and hardcopy through libghostty" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("t1", &.{"cat"});
    try h.mustControl("t1", &.{ "stuff", "round-trip-42\\n" });

    const content = try h.waitHardcopyContains("t1", "round-trip-42");
    defer alloc.free(content);
}

test "vt sequences: cursor movement, SGR, and clear are emulated" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("t2", &.{"cat"});
    // Paint NOISE, clear the screen, write at row 3 col 5, color a word.
    try h.mustControl("t2", &.{
        "stuff",
        "NOISE\\e[2J\\e[3;5HPOS\\e[1;31mRED\\e[0m-END\\n",
    });

    const content = try h.waitHardcopyContains("t2", "POSRED-END");
    defer alloc.free(content);

    // The clear must have removed earlier output.
    try std.testing.expect(std.mem.indexOf(u8, content, "NOISE") == null);

    // Row 3 starts with 4 blank columns (cursor positioning worked and
    // the hardcopy reflects screen geometry, not the byte stream).
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // row 1
    _ = lines.next(); // row 2
    const row3 = lines.next() orelse return error.MissingRow;
    try std.testing.expect(std.mem.startsWith(u8, row3, "    POS"));
}

test "attach over a real tty: echo, then detach with C-a d" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "-S", "t3", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("t3");

    try client.send("typed-into-tty\r");
    try client.waitFor("typed-into-tty");

    try client.send("\x01d"); // C-a d
    try client.waitFor("detached from t3");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // Session survives the detach.
    const result = try h.control("t3", &.{"info"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Detached") != null);
}

test "reattach rehydrates the screen from terminal state" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("t4", &.{"cat"});
    try h.mustControl("t4", &.{ "stuff", "persisted-99\\n" });
    const content = try h.waitHardcopyContains("t4", "persisted-99");
    alloc.free(content);

    // Reattach: the repaint must reproduce content written while detached.
    var client = try PtyClient.spawn(&h, &.{ "-r", "t4" }, 24, 80);
    defer client.deinit();
    try client.waitFor("persisted-99");

    try client.send("\x01d");
    try client.waitFor("detached from t4");
    _ = try client.waitExit();
}

test "window size: initial attach size and SIGWINCH resize reach the app" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "-S", "t5", "/bin/sh" }, 12, 57);
    defer client.deinit();
    try h.waitSessionUp("t5");

    const size_file = try std.fmt.allocPrint(alloc, "{s}/size.txt", .{h.dir});
    defer alloc.free(size_file);

    const cmd1 = try std.fmt.allocPrint(alloc, "stty size > {s}\\n", .{size_file});
    defer alloc.free(cmd1);
    try h.mustControl("t5", &.{ "stuff", cmd1 });
    try waitFileEquals(alloc, size_file, "12 57\n");

    // Dynamic resize: change the outer terminal size; SIGWINCH propagates
    // client -> daemon -> window PTY.
    try client.setSize(30, 90);
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        try h.mustControl("t5", &.{ "stuff", cmd1 });
        std.Thread.sleep(50 * std.time.ns_per_ms);
        const content = std.fs.cwd().readFileAlloc(alloc, size_file, 4096) catch "";
        defer if (content.len > 0) alloc.free(content);
        if (std.mem.eql(u8, content, "30 90\n")) break;
        try deadline.tick("resize never reached the inner tty");
    }
}

test "multiple windows: create, switch, and list" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "-S", "t6", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("t6");

    try client.send("first-window-data\r");
    try client.waitFor("first-window-data");

    // C-a c: new window (running the default shell); give it a marker.
    try client.send("\x01c");
    try client.send("echo second-window-data\r");
    try client.waitFor("second-window-data");

    // C-a p: back to window 0; the repaint comes from ghostty state.
    client.clearOutput();
    try client.send("\x01p");
    try client.waitFor("first-window-data");

    const result = try h.control("t6", &.{"windows"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "0*") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "1 ") != null);
}

test "session listing shows attach state" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("listed", &.{"cat"});

    const detached = try h.run(&.{"-ls"});
    defer alloc.free(detached.stdout);
    defer alloc.free(detached.stderr);
    try std.testing.expect(std.mem.indexOf(u8, detached.stdout, "listed") != null);
    try std.testing.expect(std.mem.indexOf(u8, detached.stdout, "Detached") != null);

    var client = try PtyClient.spawn(&h, &.{ "-r", "listed" }, 24, 80);
    defer client.deinit();

    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const attached = try h.run(&.{"-ls"});
        defer alloc.free(attached.stdout);
        defer alloc.free(attached.stderr);
        if (std.mem.indexOf(u8, attached.stdout, "Attached") != null) break;
        try deadline.tick("session never showed as attached");
    }
}

test "quit ends the session and notifies the attached client" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "-S", "t8", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("t8");

    try h.mustControl("t8", &.{"quit"});
    try client.waitFor("session t8 ended");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The socket is gone: control commands now fail.
    const result = try h.control("t8", &.{"info"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(result.term != .Exited or result.term.Exited != 0);
}

test "attach without a tty fails cleanly" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("t9", &.{"cat"});
    const result = try h.run(&.{ "-r", "t9" });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(result.term == .Exited and result.term.Exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "requires a terminal") != null);
}

fn waitFileEquals(alloc: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const content = std.fs.cwd().readFileAlloc(alloc, path, 4096) catch "";
        defer if (content.len > 0) alloc.free(content);
        if (std.mem.eql(u8, content, expected)) return;
        deadline.tick("file never matched") catch |err| {
            std.debug.print("--- file {s} content: {s} (wanted {s})\n", .{ path, content, expected });
            return err;
        };
    }
}
