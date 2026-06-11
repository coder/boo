//! The session daemon: owns the window (PTY + libghostty terminal
//! state), accepts client connections on a Unix socket, routes
//! input/output, and executes control commands.
//!
//! Single-threaded poll(2) loop. One client may be attached at a time
//! (attaching steals); any number of transient control connections
//! may come and go.

const std = @import("std");
const posix = std.posix;

const protocol = @import("protocol.zig");
const keys = @import("keys.zig");
const altscreen = @import("altscreen.zig");
const paths = @import("paths.zig");
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

    win: ?*Window = null,

    conns: std.ArrayList(*Conn) = .empty,
    key_parser: keys.Parser = .{},

    /// Owned replacements for opts.name and opts.socket_path after a
    /// rename; the startup values are borrowed from the caller.
    owned_name: ?[]u8 = null,
    owned_socket_path: ?[]u8 = null,

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

        self.win = try createWindow(self.alloc, opts.name, opts.argv, self.rows, self.cols);

        try self.loop();
    }

    fn deinit(self: *Daemon) void {
        if (self.win) |w| w.destroy();
        for (self.conns.items) |c| {
            posix.close(c.fd);
            c.decoder.deinit();
            self.alloc.destroy(c);
        }
        self.conns.deinit(self.alloc);
        posix.close(self.opts.listen_fd);
        std.fs.cwd().deleteFile(self.opts.socket_path) catch {};
        if (self.owned_name) |n| self.alloc.free(n);
        if (self.owned_socket_path) |p| self.alloc.free(p);
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
            if (self.liveWindow()) |w| {
                if (w.pty_fd >= 0) {
                    try fds.append(self.alloc, .{ .fd = w.pty_fd, .events = posix.POLL.IN, .revents = 0 });
                    try refs.append(self.alloc, .{ .window = w });
                }
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
            if (self.liveWindow() == null) {
                self.broadcastExit("command exited");
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
                self.resizeWindow(size.rows, size.cols);
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
                // When the window runs the kitty keyboard protocol,
                // the client's terminal mirrors it and sends the
                // prefix key CSI-u encoded.
                const kitty = if (self.liveWindow()) |w| w.kittyKeysActive() else false;
                try self.key_parser.feed(msg.payload, kitty, Handler{ .daemon = self, .conn = conn });
            },

            .resize => {
                if (!conn.attached) return;
                const size = try protocol.SizePayload.decode(msg.payload);
                self.resizeWindow(size.rows, size.cols);
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
        // A detach earlier in the same input batch ended the
        // attachment. Bytes after the detach key (auto-repeats of a
        // held C-d arriving coalesced, or keys typed during the
        // detach round trip) belong to no window; forwarding them
        // would EOF or garble the program the user just left.
        if (!conn.attached) return;
        switch (cmd) {
            .forward => |bytes| if (self.liveWindow()) |w| {
                w.writeInput(bytes) catch {};
            },
            .detach => |byte| self.detachConn(
                conn,
                // A C-d triggered detach warns the client that the
                // user may be holding the byte that EOFs shells.
                if (byte == 0x04) "detached-eof" else "detached",
            ),
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
            if (self.liveWindow()) |w| {
                w.writeInput(argv[1]) catch {
                    conn.send(.err, "window write failed");
                    return;
                };
                self.last_activity_ms = now;
                conn.send(.ok, "");
            } else conn.send(.err, "no window");
        } else if (std.mem.eql(u8, cmd, "peek")) {
            const scrollback = argv.len > 1 and std.mem.eql(u8, argv[1], "scrollback");
            if (self.liveWindow()) |w| {
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
                try out.print(self.alloc, "{d}\t{d}\t{d}\t{d}\t", .{
                    self.rows,
                    self.cols,
                    cursor.y + 1,
                    cursor.x + 1,
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
            } else conn.send(.err, "no window");
        } else if (std.mem.eql(u8, cmd, "info")) {
            var attached = false;
            for (self.conns.items) |c| {
                if (c.attached and !c.closed) attached = true;
            }
            const idle: i64 = @max(0, now - self.last_activity_ms);
            const out_idle: i64 = if (self.liveWindow()) |w|
                @max(0, now - w.last_output_ms)
            else
                0;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.alloc);
            try out.print(self.alloc, "{s}\t{s}\t{d}\t{d}\t", .{
                self.opts.name,
                if (attached) "Attached" else "Detached",
                idle,
                out_idle,
            });
            // Window title last; sanitized, so it cannot contain the
            // tabs that separate the fields.
            if (self.liveWindow()) |w| {
                for (w.title()) |byte| {
                    if (byte < 0x20 or byte == 0x7f) continue;
                    try out.append(self.alloc, byte);
                }
            }
            conn.send(.ok, out.items);
        } else if (std.mem.eql(u8, cmd, "rename")) {
            if (argv.len != 2) {
                conn.send(.err, "usage: rename <new-name>");
                return;
            }
            self.rename(conn, argv[1]);
        } else if (std.mem.eql(u8, cmd, "quit")) {
            conn.send(.ok, "");
            if (self.win) |w| {
                posix.kill(w.child_pid, posix.SIG.HUP) catch {};
            }
            self.broadcastExit("session terminated");
            self.quitting = true;
        } else {
            conn.send(.err, "unknown command");
        }
    }

    /// Move the session to a new name by renaming the listening
    /// socket; established connections survive, and new clients find
    /// the session under the new name.
    fn rename(self: *Daemon, conn: *Conn, new_name: []const u8) void {
        paths.validateName(new_name) catch {
            conn.send(.err, "invalid session name");
            return;
        };
        if (std.mem.eql(u8, new_name, self.opts.name)) {
            conn.send(.ok, "");
            return;
        }

        const dir = std.fs.path.dirname(self.opts.socket_path) orelse ".";
        const new_path = paths.socketPath(self.alloc, dir, new_name) catch {
            conn.send(.err, "rename failed");
            return;
        };
        const new_owned_name = self.alloc.dupe(u8, new_name) catch {
            self.alloc.free(new_path);
            conn.send(.err, "rename failed");
            return;
        };

        // Refuse to clobber another session's socket. Checking first
        // is racy, but the window is tiny and losing the race only
        // replaces a socket the same way 'kill' would free it.
        if (std.fs.cwd().access(new_path, .{})) |_| {
            self.alloc.free(new_path);
            self.alloc.free(new_owned_name);
            conn.send(.err, "a session with that name already exists");
            return;
        } else |_| {}

        std.fs.cwd().rename(self.opts.socket_path, new_path) catch {
            self.alloc.free(new_path);
            self.alloc.free(new_owned_name);
            conn.send(.err, "rename failed");
            return;
        };

        if (self.owned_name) |n| self.alloc.free(n);
        if (self.owned_socket_path) |p| self.alloc.free(p);
        self.owned_name = new_owned_name;
        self.owned_socket_path = new_path;
        self.opts.name = new_owned_name;
        self.opts.socket_path = new_path;
        log.info("renamed to {s}", .{new_name});
        conn.send(.ok, "");
    }

    fn serviceWindow(self: *Daemon, win: *Window, buf: []u8) void {
        const n = posix.read(win.pty_fd, buf) catch |err| n: {
            // EIO means the slave side is fully closed: window is done.
            if (err != error.InputOutput) {
                log.warn("window read error: {}", .{err});
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

    /// Remove closed conns. Runs after every poll dispatch so
    /// iteration above never sees mutation.
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
    }

    // -- Window management ------------------------------------------------

    fn createWindow(
        alloc: std.mem.Allocator,
        session_name: []const u8,
        argv: []const []const u8,
        rows: u16,
        cols: u16,
    ) !*Window {
        var env = try std.process.getEnvMap(alloc);
        defer env.deinit();
        try env.put("TERM", "xterm-256color");
        try env.put("BOO", session_name);

        var default_argv: [1][]const u8 = .{env.get("SHELL") orelse "/bin/sh"};
        const child_argv: []const []const u8 = if (argv.len > 0) argv else &default_argv;

        return Window.create(alloc, child_argv, &env, rows, cols);
    }

    fn liveWindow(self: *Daemon) ?*Window {
        const w = self.win orelse return null;
        if (w.dead) return null;
        return w;
    }

    fn attachedConn(self: *Daemon) ?*Conn {
        for (self.conns.items) |c| {
            if (c.attached and !c.closed) return c;
        }
        return null;
    }

    fn updatePassthrough(self: *Daemon) void {
        const attached = self.attachedConn() != null;
        if (self.liveWindow()) |w| w.passthrough = attached;
    }

    fn resizeWindow(self: *Daemon, rows: u16, cols: u16) void {
        if (rows == 0 or cols == 0) return;
        self.rows = rows;
        self.cols = cols;
        if (self.liveWindow()) |w| {
            w.resize(rows, cols) catch |err| {
                log.warn("resize window failed: {}", .{err});
            };
        }
    }

    fn repaintTo(self: *Daemon, conn: *Conn) !void {
        const win = self.liveWindow() orelse return;
        const bytes = try win.repaint(self.alloc);
        defer self.alloc.free(bytes);
        // The repaint covers everything fed so far; resume passthrough
        // from a clean slate.
        win.alt_filter.reset();
        conn.send(.output, bytes);
        // Repaints accompany every screen identity change (attach,
        // redraw, alt-screen switches), so this keeps the client's
        // picture of the application's screen current.
        conn.send(.screen, if (win.onAltScreen()) "alt" else "primary");
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
