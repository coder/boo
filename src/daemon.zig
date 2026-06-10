//! The session daemon: owns windows (PTY + libghostty terminal state),
//! accepts client connections on a Unix socket, routes input/output, and
//! executes control commands.
//!
//! Single-threaded poll(2) loop. One client may be attached at a time
//! (attaching steals); any number of transient control (-X) connections
//! may come and go.

const std = @import("std");
const posix = std.posix;

const protocol = @import("protocol.zig");
const keys = @import("keys.zig");
const altscreen = @import("altscreen.zig");
const windowpkg = @import("window.zig");
const Window = windowpkg.Window;
const main = @import("main.zig");

const log = std.log.scoped(.daemon);

pub const Options = struct {
    name: []const u8,
    socket_path: []const u8,
    listen_fd: posix.fd_t,
    argv: []const []const u8,
    rows: u16 = 24,
    cols: u16 = 80,
};

const Conn = struct {
    fd: posix.fd_t,
    decoder: protocol.Decoder,
    attached: bool = false,
    closed: bool = false,

    fn send(self: *Conn, msg_type: protocol.MsgType, payload: []const u8) void {
        if (self.closed) return;
        protocol.writeMsg(self.fd, msg_type, payload) catch {
            self.closed = true;
        };
    }
};

var sigchld_pipe: posix.fd_t = -1;

fn handleSigchld(_: c_int) callconv(.c) void {
    if (sigchld_pipe >= 0) {
        _ = posix.write(sigchld_pipe, "c") catch {};
    }
}

pub const Daemon = struct {
    alloc: std.mem.Allocator,
    opts: Options,

    windows: std.ArrayList(*Window) = .empty,
    next_window_id: u16 = 0,
    active: ?usize = null,
    last_active_id: ?u16 = null,

    conns: std.ArrayList(*Conn) = .empty,
    key_parser: keys.Parser = .{},

    rows: u16,
    cols: u16,

    /// Wall-clock time (milliseconds) of the most recent window output
    /// or client input; reported as session idle time.
    last_activity_ms: i64 = 0,

    sig_read: posix.fd_t = -1,
    quitting: bool = false,

    pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
        var self: Daemon = .{
            .alloc = alloc,
            .opts = opts,
            .rows = opts.rows,
            .cols = opts.cols,
            .last_activity_ms = std.time.milliTimestamp(),
        };
        defer self.deinit();

        // Reap children via the self-pipe trick.
        const pipe_fds = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        self.sig_read = pipe_fds[0];
        sigchld_pipe = pipe_fds[1];
        posix.sigaction(posix.SIG.CHLD, &.{
            .handler = .{ .handler = handleSigchld },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART | posix.SA.NOCLDSTOP,
        }, null);

        // A dying client must never kill the session.
        posix.sigaction(posix.SIG.PIPE, &.{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);
        posix.sigaction(posix.SIG.HUP, &.{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);

        _ = try self.createWindow(opts.argv);
        self.active = 0;

        try self.loop();
    }

    fn deinit(self: *Daemon) void {
        for (self.windows.items) |w| w.destroy();
        self.windows.deinit(self.alloc);
        for (self.conns.items) |c| {
            posix.close(c.fd);
            c.decoder.deinit();
            self.alloc.destroy(c);
        }
        self.conns.deinit(self.alloc);
        posix.close(self.opts.listen_fd);
        std.fs.cwd().deleteFile(self.opts.socket_path) catch {};
        if (self.sig_read >= 0) posix.close(self.sig_read);
        if (sigchld_pipe >= 0) posix.close(sigchld_pipe);
    }

    fn loop(self: *Daemon) !void {
        var fds: std.ArrayList(posix.pollfd) = .empty;
        defer fds.deinit(self.alloc);

        // Parallel array describing what each pollfd refers to.
        const Ref = union(enum) {
            listen,
            sigchld,
            conn: *Conn,
            window: *Window,
        };
        var refs: std.ArrayList(Ref) = .empty;
        defer refs.deinit(self.alloc);

        var buf: [32 * 1024]u8 = undefined;

        while (!self.quitting) {
            fds.clearRetainingCapacity();
            refs.clearRetainingCapacity();

            try fds.append(self.alloc, .{ .fd = self.opts.listen_fd, .events = posix.POLL.IN, .revents = 0 });
            try refs.append(self.alloc, .listen);
            try fds.append(self.alloc, .{ .fd = self.sig_read, .events = posix.POLL.IN, .revents = 0 });
            try refs.append(self.alloc, .sigchld);
            for (self.conns.items) |c| {
                try fds.append(self.alloc, .{ .fd = c.fd, .events = posix.POLL.IN, .revents = 0 });
                try refs.append(self.alloc, .{ .conn = c });
            }
            for (self.windows.items) |w| {
                if (w.pty_fd < 0 or w.dead) continue;
                try fds.append(self.alloc, .{ .fd = w.pty_fd, .events = posix.POLL.IN, .revents = 0 });
                try refs.append(self.alloc, .{ .window = w });
            }

            _ = try posix.poll(fds.items, -1);

            for (fds.items, refs.items) |pfd, ref| {
                if (pfd.revents == 0) continue;
                switch (ref) {
                    .listen => self.acceptConn(),
                    .sigchld => self.reapChildren(&buf),
                    .conn => |c| self.serviceConn(c, &buf),
                    .window => |w| self.serviceWindow(w, &buf),
                }
                if (self.quitting) break;
            }

            self.sweep();
            if (self.windows.items.len == 0) {
                self.broadcastExit("all windows closed");
                break;
            }
        }
    }

    fn acceptConn(self: *Daemon) void {
        const fd = posix.accept(self.opts.listen_fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
            log.warn("accept failed: {}", .{err});
            return;
        };
        const conn = self.alloc.create(Conn) catch {
            posix.close(fd);
            return;
        };
        conn.* = .{ .fd = fd, .decoder = .init(self.alloc) };
        self.conns.append(self.alloc, conn) catch {
            posix.close(fd);
            self.alloc.destroy(conn);
            return;
        };
    }

    fn reapChildren(self: *Daemon, buf: []u8) void {
        _ = posix.read(self.sig_read, buf) catch {};
        // Window teardown happens via PTY EOF, which arrives after all
        // remaining output has been drained; this only reaps zombies.
        var status: c_int = undefined;
        while (std.c.waitpid(-1, &status, std.c.W.NOHANG) > 0) {}
    }

    fn serviceConn(self: *Daemon, conn: *Conn, buf: []u8) void {
        const n = posix.read(conn.fd, buf) catch 0;
        if (n == 0) {
            conn.closed = true;
            return;
        }
        conn.decoder.feed(buf[0..n]) catch {
            conn.closed = true;
            return;
        };
        while (true) {
            const msg = conn.decoder.next() catch {
                conn.closed = true;
                return;
            } orelse break;
            self.handleMsg(conn, msg) catch |err| {
                log.warn("error handling message: {}", .{err});
                conn.closed = true;
                return;
            };
            if (self.quitting or conn.closed) break;
        }
    }

    fn handleMsg(self: *Daemon, conn: *Conn, msg: protocol.Msg) !void {
        switch (msg.type) {
            .attach => {
                const size = try protocol.SizePayload.decode(msg.payload);
                // Steal from any previously attached client.
                for (self.conns.items) |other| {
                    if (other != conn and other.attached) {
                        other.send(.detached, "stolen");
                        other.closed = true;
                    }
                }
                conn.attached = true;
                self.key_parser = .{};
                self.resizeAll(size.rows, size.cols);
                self.updatePassthrough();
                try self.repaintTo(conn);
            },

            .input => {
                if (!conn.attached) return;
                self.last_activity_ms = std.time.milliTimestamp();
                const Handler = struct {
                    daemon: *Daemon,
                    conn: *Conn,
                    pub fn command(h: @This(), cmd: keys.Command) !void {
                        try h.daemon.handleKeyCommand(h.conn, cmd);
                    }
                };
                // When the active window runs the kitty keyboard
                // protocol, the client's terminal mirrors it and sends
                // the prefix key CSI-u encoded.
                const kitty = if (self.activeWindow()) |w| w.kittyKeysActive() else false;
                try self.key_parser.feed(msg.payload, kitty, Handler{ .daemon = self, .conn = conn });
            },

            .resize => {
                if (!conn.attached) return;
                const size = try protocol.SizePayload.decode(msg.payload);
                self.resizeAll(size.rows, size.cols);
            },

            .detach_req => {
                if (!conn.attached) return;
                self.detachConn(conn, "detached");
            },

            .command => try self.handleCommand(conn, msg.payload),

            else => {},
        }
    }

    fn handleKeyCommand(self: *Daemon, conn: *Conn, cmd: keys.Command) !void {
        switch (cmd) {
            .forward => |bytes| if (self.activeWindow()) |w| {
                w.writeInput(bytes) catch {};
            },
            .new_window => {
                const idx = try self.createWindow(&.{});
                self.switchTo(idx);
            },
            .next_window => self.switchRelative(1),
            .prev_window => self.switchRelative(-1),
            .other_window => {
                if (self.last_active_id) |id| {
                    if (self.windowIndexById(id)) |idx| self.switchTo(idx);
                }
            },
            .select_window => |n| {
                if (self.windowIndexById(n)) |idx| {
                    self.switchTo(idx);
                } else {
                    self.message(conn, "no window {d}", .{n});
                }
            },
            .detach => self.detachConn(conn, "detached"),
            .kill_window => if (self.activeWindow()) |w| {
                posix.kill(w.child_pid, posix.SIG.HUP) catch {};
            },
            .list_windows => {
                const list = try self.windowList();
                defer self.alloc.free(list);
                self.message(conn, "{s}", .{list});
            },
            .redraw => try self.repaintTo(conn),
            .unknown => |byte| if (std.ascii.isPrint(byte))
                self.message(conn, "unknown key: ^A {c}", .{byte})
            else
                self.message(conn, "unknown key: ^A ^{c}", .{byte ^ 0x40}),
        }
    }

    fn handleCommand(self: *Daemon, conn: *Conn, payload: []const u8) !void {
        const argv = try protocol.decodeArgv(self.alloc, payload);
        defer self.alloc.free(argv);
        if (argv.len == 0) {
            conn.send(.err, "empty command");
            return;
        }

        const now = std.time.milliTimestamp();
        const cmd = argv[0];
        if (std.mem.eql(u8, cmd, "send")) {
            if (argv.len != 2) {
                conn.send(.err, "usage: send <bytes>");
                return;
            }
            if (self.activeWindow()) |w| {
                w.writeInput(argv[1]) catch {
                    conn.send(.err, "window write failed");
                    return;
                };
                self.last_activity_ms = now;
                conn.send(.ok, "");
            } else conn.send(.err, "no active window");
        } else if (std.mem.eql(u8, cmd, "peek")) {
            const scrollback = argv.len > 1 and std.mem.eql(u8, argv[1], "scrollback");
            if (self.activeWindow()) |w| {
                const text = if (scrollback)
                    try w.plainScrollback(self.alloc)
                else
                    try w.plainScreen(self.alloc);
                defer self.alloc.free(text);
                // Header line with window metadata, then the dump. The
                // title is sanitized so it cannot contain the newline
                // that terminates the header.
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(self.alloc);
                const cursor = &w.term.screens.active.cursor;
                try out.print(self.alloc, "{d}\t{d}\t{d}\t{d}\t{d}\t", .{
                    self.rows,
                    self.cols,
                    cursor.y + 1,
                    cursor.x + 1,
                    w.id,
                });
                for (w.title()) |byte| {
                    if (byte < 0x20 or byte == 0x7f) continue;
                    try out.append(self.alloc, byte);
                }
                try out.append(self.alloc, '\n');
                try out.appendSlice(self.alloc, text);
                if (out.items.len > protocol.max_payload) {
                    out.shrinkRetainingCapacity(protocol.max_payload);
                }
                conn.send(.ok, out.items);
            } else conn.send(.err, "no active window");
        } else if (std.mem.eql(u8, cmd, "windows")) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.alloc);
            for (self.windows.items, 0..) |w, i| {
                if (out.items.len > 0) try out.append(self.alloc, '\n');
                const active: u8 = if (self.active != null and self.active.? == i) '1' else '0';
                const idle: i64 = @max(0, now - w.last_output_ms);
                try out.print(self.alloc, "{d}\t{c}\t{d}\t{s}\t", .{ w.id, active, idle, w.command_title });
                for (w.title()) |byte| {
                    if (byte < 0x20 or byte == 0x7f) continue;
                    try out.append(self.alloc, byte);
                }
            }
            conn.send(.ok, out.items);
        } else if (std.mem.eql(u8, cmd, "info")) {
            var attached = false;
            for (self.conns.items) |c| {
                if (c.attached and !c.closed) attached = true;
            }
            const idle: i64 = @max(0, now - self.last_activity_ms);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.alloc);
            try out.print(self.alloc, "{s}\t{d}\t{s}\t{d}\t", .{
                self.opts.name,
                self.windows.items.len,
                if (attached) "Attached" else "Detached",
                idle,
            });
            // Active window title last; sanitized, so it cannot
            // contain the tabs that separate the fields.
            if (self.activeWindow()) |w| {
                for (w.title()) |byte| {
                    if (byte < 0x20 or byte == 0x7f) continue;
                    try out.append(self.alloc, byte);
                }
            }
            conn.send(.ok, out.items);
        } else if (std.mem.eql(u8, cmd, "quit")) {
            conn.send(.ok, "");
            for (self.windows.items) |w| {
                posix.kill(w.child_pid, posix.SIG.HUP) catch {};
            }
            self.broadcastExit("session terminated");
            self.quitting = true;
        } else {
            conn.send(.err, "unknown command");
        }
    }

    fn serviceWindow(self: *Daemon, win: *Window, buf: []u8) void {
        const n = posix.read(win.pty_fd, buf) catch |err| n: {
            // EIO means the slave side is fully closed: window is done.
            if (err != error.InputOutput) {
                log.warn("window {d} read error: {}", .{ win.id, err });
            }
            break :n 0;
        };
        if (n == 0) {
            win.dead = true;
            return;
        }
        const chunk = buf[0..n];
        const now = std.time.milliTimestamp();
        win.last_output_ms = now;
        self.last_activity_ms = now;

        const conn = (if (win.passthrough) self.attachedConn() else null) orelse {
            // Not passed through: the window answers queries itself.
            win.feed(chunk);
            return;
        };

        // Forward raw bytes, minus alternate-screen toggles: the client
        // canvas cannot switch screens. When the window switches, the
        // rest of the chunk is dropped and the new active screen is
        // repainted from terminal state.
        var out_buf: [32 * 1024 + 32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out_buf);
        const result = win.alt_filter.feed(chunk, &writer) catch
            altscreen.Filter.Result{ .switched = true, .discard_start = 0 };

        // Bytes up to the discard point reach the client's real
        // terminal, which answers any queries among them. The repaint
        // re-renders the discarded tail from terminal state, but it
        // cannot answer queries, so the window must.
        const split = result.discard_start orelse chunk.len;
        win.feed(chunk[0..split]);
        if (split < chunk.len) win.feedDiscarded(chunk[split..]);

        const filtered = writer.buffered();
        if (filtered.len > 0) conn.send(.output, filtered);
        if (result.switched) {
            self.repaintTo(conn) catch |err| {
                log.warn("repaint after screen switch failed: {}", .{err});
            };
        }
    }

    /// Remove closed conns and dead windows. Runs after every poll
    /// dispatch so iteration above never sees mutation.
    fn sweep(self: *Daemon) void {
        var ci: usize = 0;
        while (ci < self.conns.items.len) {
            const c = self.conns.items[ci];
            if (!c.closed) {
                ci += 1;
                continue;
            }
            posix.close(c.fd);
            c.decoder.deinit();
            self.alloc.destroy(c);
            _ = self.conns.swapRemove(ci);
        }

        var wi: usize = 0;
        var active_died = false;
        while (wi < self.windows.items.len) {
            const w = self.windows.items[wi];
            if (!w.dead) {
                wi += 1;
                continue;
            }
            if (self.active) |a| {
                if (a == wi) active_died = true;
            }
            if (self.last_active_id == w.id) self.last_active_id = null;
            w.destroy();
            _ = self.windows.orderedRemove(wi);
            // Fix up active index after removal.
            if (self.active) |a| {
                if (a > wi) self.active = a - 1;
            }
        }

        if (self.windows.items.len == 0) return;
        if (active_died or self.active == null or self.active.? >= self.windows.items.len) {
            self.switchTo(@min(
                self.active orelse 0,
                self.windows.items.len - 1,
            ));
        }
    }

    // -- Window management ------------------------------------------------

    fn createWindow(self: *Daemon, argv: []const []const u8) !usize {
        var env = try std.process.getEnvMap(self.alloc);
        defer env.deinit();
        try env.put("TERM", "xterm-256color");
        try env.put("BOO", self.opts.name);

        var default_argv: [1][]const u8 = .{env.get("SHELL") orelse "/bin/sh"};
        const child_argv: []const []const u8 = if (argv.len > 0) argv else &default_argv;

        const id = self.next_window_id;
        var idbuf: [8]u8 = undefined;
        try env.put("WINDOW", std.fmt.bufPrint(&idbuf, "{d}", .{id}) catch unreachable);

        const win = try Window.create(self.alloc, id, child_argv, &env, self.rows, self.cols);
        errdefer win.destroy();
        try self.windows.append(self.alloc, win);
        self.next_window_id += 1;
        return self.windows.items.len - 1;
    }

    fn activeWindow(self: *Daemon) ?*Window {
        const idx = self.active orelse return null;
        if (idx >= self.windows.items.len) return null;
        return self.windows.items[idx];
    }

    fn attachedConn(self: *Daemon) ?*Conn {
        for (self.conns.items) |c| {
            if (c.attached and !c.closed) return c;
        }
        return null;
    }

    fn windowIndexById(self: *Daemon, id: u16) ?usize {
        for (self.windows.items, 0..) |w, i| {
            if (w.id == id) return i;
        }
        return null;
    }

    fn switchTo(self: *Daemon, idx: usize) void {
        if (idx >= self.windows.items.len) return;
        if (self.active) |a| {
            if (a != idx and a < self.windows.items.len) {
                self.last_active_id = self.windows.items[a].id;
            }
        }
        self.active = idx;
        self.updatePassthrough();
        if (self.attachedConn()) |conn| {
            self.repaintTo(conn) catch |err| {
                log.warn("repaint failed: {}", .{err});
            };
        }
    }

    fn switchRelative(self: *Daemon, dir: i32) void {
        const len = self.windows.items.len;
        if (len == 0) return;
        const cur = self.active orelse 0;
        const next = if (dir > 0)
            (cur + 1) % len
        else
            (cur + len - 1) % len;
        self.switchTo(next);
    }

    fn updatePassthrough(self: *Daemon) void {
        const attached = self.attachedConn() != null;
        for (self.windows.items, 0..) |w, i| {
            w.passthrough = attached and self.active != null and self.active.? == i;
        }
    }

    fn resizeAll(self: *Daemon, rows: u16, cols: u16) void {
        if (rows == 0 or cols == 0) return;
        self.rows = rows;
        self.cols = cols;
        for (self.windows.items) |w| {
            w.resize(rows, cols) catch |err| {
                log.warn("resize window {d} failed: {}", .{ w.id, err });
            };
        }
    }

    fn repaintTo(self: *Daemon, conn: *Conn) !void {
        const win = self.activeWindow() orelse return;
        const bytes = try win.repaint(self.alloc);
        defer self.alloc.free(bytes);
        // The repaint covers everything fed so far; resume passthrough
        // from a clean slate.
        win.alt_filter.reset();
        conn.send(.output, bytes);
    }

    fn detachConn(self: *Daemon, conn: *Conn, reason: []const u8) void {
        conn.send(.detached, reason);
        conn.attached = false;
        conn.closed = true;
        self.updatePassthrough();
    }

    fn broadcastExit(self: *Daemon, reason: []const u8) void {
        for (self.conns.items) |c| {
            if (c.closed) continue;
            c.send(.exit, reason);
            c.closed = true;
        }
        self.quitting = true;
    }

    fn windowList(self: *Daemon) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.alloc);
        for (self.windows.items, 0..) |w, i| {
            if (out.items.len > 0) try out.append(self.alloc, '\n');
            const marker: u8 = if (self.active != null and self.active.? == i) '*' else ' ';
            const line = try std.fmt.allocPrint(self.alloc, "{d}{c} {s}", .{ w.id, marker, w.title() });
            defer self.alloc.free(line);
            try out.appendSlice(self.alloc, line);
        }
        return out.toOwnedSlice(self.alloc);
    }

    fn message(self: *Daemon, conn: *Conn, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(text);
        // Single-line status message at the bottom of the screen,
        // preserving cursor position.
        const flat = std.mem.replaceOwned(u8, self.alloc, text, "\n", " | ") catch return;
        defer self.alloc.free(flat);
        const seq = std.fmt.allocPrint(
            self.alloc,
            "\x1b7\x1b[{d};1H\x1b[0m\x1b[7m {s} \x1b[0m\x1b[K\x1b8",
            .{ self.rows, flat },
        ) catch return;
        defer self.alloc.free(seq);
        conn.send(.output, seq);
    }
};
