//! The session daemon: owns the window (PTY + libghostty terminal
//! state), accepts client connections on a Unix socket, routes
//! input/output, and executes control commands.
//!
//! Single-threaded poll(2) loop. One client may be attached at a time
//! (attaching steals); any number of transient control connections
//! may come and go.
//!
//! Client sockets are non-blocking and per-connection output is queued
//! and flushed on POLLOUT, so a client that reads slowly never blocks
//! the loop. A blocking write here would stall the PTY and every other
//! client until the slow reader caught up (the boo-ui freeze this
//! design guards against).

const std = @import("std");
const posix = std.posix;

const protocol = @import("protocol.zig");
const keys = @import("keys.zig");
const altscreen = @import("altscreen.zig");
const paths = @import("paths.zig");
const cwd = @import("cwd.zig");
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
    /// Working directory for the session command; null inherits the
    /// daemon's own directory.
    cwd: ?[]const u8 = null,
};

/// Hard cap on a single connection's queued-but-unsent output. The
/// daemon never blocks on a client write (see `Conn.flush`), so a
/// client that stops reading would otherwise grow this without bound.
/// A client that falls this far behind is dropped instead; it
/// reconnects and gets a fresh repaint. Generous, so an ordinary burst
/// (a full-screen repaint is kilobytes) never trips it.
const max_conn_out: usize = 8 * 1024 * 1024;

/// Upper bound on how long teardown waits for queued finals to drain.
const shutdown_drain_ms: i64 = 250;

const Conn = struct {
    alloc: std.mem.Allocator,
    fd: posix.fd_t,
    decoder: protocol.Decoder,
    attached: bool = false,
    /// A ui view (vs a plain attach): gets its scrollback history
    /// replayed on attach so a wheel-up can page it.
    ui: bool = false,
    /// The connection is finished: its fd is dead or it was dropped.
    /// `sweep` closes the fd and frees it.
    closed: bool = false,
    /// A final frame (detach or exit) is queued: read no more input and
    /// close once `out` has drained, so the client still sees it.
    shutdown: bool = false,
    /// Frames queued for the client but not yet written to the socket.
    /// The socket is non-blocking, so a slow reader backs up here
    /// instead of blocking the loop. Drained on POLLOUT.
    out: std.ArrayList(u8) = .empty,
    /// Drop threshold for `out`; a field so tests can shrink it.
    out_cap: usize = max_conn_out,

    /// Queue a frame and write what the socket will take right now.
    /// Never blocks: the unsent remainder waits for the next POLLOUT. A
    /// client that backs up past `out_cap` is dropped rather than
    /// buffered without bound.
    fn send(self: *Conn, msg_type: protocol.MsgType, payload: []const u8) void {
        if (self.closed or self.shutdown) return;
        protocol.appendMsg(self.alloc, &self.out, msg_type, payload) catch {
            self.drop();
            return;
        };
        if (self.out.items.len > self.out_cap) {
            self.drop();
            return;
        }
        self.flush();
    }

    /// Write as much of `out` as the socket accepts without blocking. A
    /// full send buffer (WouldBlock) just leaves the remainder for the
    /// next POLLOUT; any other error drops the connection.
    fn flush(self: *Conn) void {
        if (self.closed) return;
        var off: usize = 0;
        while (off < self.out.items.len) {
            const n = posix.write(self.fd, self.out.items[off..]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.drop();
                    return;
                },
            };
            if (n == 0) break;
            off += n;
        }
        if (off == self.out.items.len) {
            self.out.clearRetainingCapacity();
        } else if (off > 0) {
            const remaining = self.out.items.len - off;
            std.mem.copyForwards(u8, self.out.items[0..remaining], self.out.items[off..]);
            self.out.shrinkRetainingCapacity(remaining);
        }
    }

    /// Discard queued output and mark the connection dead.
    fn drop(self: *Conn) void {
        self.closed = true;
        self.out.clearRetainingCapacity();
    }

    fn deinit(self: *Conn) void {
        self.out.deinit(self.alloc);
        self.decoder.deinit();
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

    /// Output arrived while no client was attached: the session has
    /// activity you have not seen. The ui flags it; attaching clears it.
    unread: bool = false,

    /// Wall-clock time (milliseconds) of the last bell that rang while
    /// no client was attached, or 0 for none since you last looked. A
    /// bell is an explicit "your turn" request; the info reply reports
    /// it as an age so the ui can combine it with output idle time.
    /// Attaching clears it.
    last_bell_ms: i64 = 0,

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

        self.win = try createWindow(self.alloc, opts.name, opts.argv, self.rows, self.cols, opts.cwd);

        try self.loop();
    }

    fn deinit(self: *Daemon) void {
        if (self.win) |w| w.destroy();
        for (self.conns.items) |c| {
            posix.close(c.fd);
            c.deinit();
            self.alloc.destroy(c);
        }
        self.conns.deinit(self.alloc);
        self.retireListener();
        if (self.owned_name) |n| self.alloc.free(n);
        if (self.owned_socket_path) |p| self.alloc.free(p);
        if (self.sig_read >= 0) posix.close(self.sig_read);
        if (sigchld_pipe >= 0) posix.close(sigchld_pipe);
    }

    /// Close the listening socket and remove its file so new clients
    /// resolve "no session" instead of connecting to a dying daemon
    /// and reading EOF.
    fn retireListener(self: *Daemon) void {
        if (self.opts.listen_fd < 0) return;
        posix.close(self.opts.listen_fd);
        self.opts.listen_fd = -1;
        std.fs.cwd().deleteFile(self.opts.socket_path) catch {};
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
                if (c.closed) continue;
                // A connection whose final frame has drained is done;
                // close it so sweep can free it this cycle.
                if (c.shutdown and c.out.items.len == 0) {
                    c.closed = true;
                    continue;
                }
                var events: i16 = 0;
                // Read input until shutdown; a shutdown conn only
                // drains its queued tail.
                if (!c.shutdown) events |= posix.POLL.IN;
                // Watch for writability whenever output is queued.
                if (c.out.items.len > 0) events |= posix.POLL.OUT;
                try fds.append(self.alloc, .{ .fd = c.fd, .events = events, .revents = 0 });
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
                    .conn => |c| {
                        // Drain queued output first so a writable socket
                        // makes room before any new input is handled.
                        if ((pfd.revents & posix.POLL.OUT) != 0) c.flush();
                        if (!c.closed and !c.shutdown and
                            (pfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0)
                        {
                            self.serviceConn(c, &buf);
                        }
                    },
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

        // Give queued finals (detach, exit, command replies) a bounded
        // chance to reach clients before the fds close in deinit.
        self.drainOutbound();
    }

    fn acceptConn(self: *Daemon) void {
        // Non-blocking so the daemon's writes to this client never
        // block the loop; output the socket cannot take yet is queued
        // on the Conn and flushed on POLLOUT.
        const fd = posix.accept(self.opts.listen_fd, null, null, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK) catch |err| {
            log.warn("accept failed: {}", .{err});
            return;
        };
        const conn = self.alloc.create(Conn) catch {
            posix.close(fd);
            return;
        };
        conn.* = .{ .alloc = self.alloc, .fd = fd, .decoder = .init(self.alloc) };
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
        const n = posix.read(conn.fd, buf) catch |err| switch (err) {
            // A POLLOUT-only wake (or spurious readiness) has nothing
            // to read yet; that is not an EOF.
            error.WouldBlock => return,
            else => {
                conn.closed = true;
                return;
            },
        };
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
            .ui => conn.ui = true,

            .bg_color => {
                // The client probed its real terminal's background and
                // reported it; the window uses it to answer OSC 11
                // queries and the color-scheme DSR from the session.
                const bg = protocol.RgbPayload.decode(msg.payload) catch return;
                if (self.liveWindow()) |w| w.setBackground(bg);
            },

            .attach => {
                const size = try protocol.SizePayload.decode(msg.payload);
                // Steal from any previously attached client.
                for (self.conns.items) |other| {
                    if (other != conn and other.attached) {
                        other.send(.detached, "stolen");
                        other.attached = false;
                        // Let the steal notice drain before closing.
                        other.shutdown = true;
                    }
                }
                conn.attached = true;
                // Attaching is viewing, so the session's output is no
                // longer unseen.
                self.unread = false;
                self.last_bell_ms = 0;
                self.key_parser = .{};
                self.resizeWindow(size.rows, size.cols);
                self.updatePassthrough();
                // A ui view starts with an empty terminal; seed its
                // scrollback with the window's history (sized to the
                // client) before the repaint puts the live screen at
                // the bottom. conn.ui is set by the `.ui` marker the
                // client sends just before attaching. Best effort:
                // failure just means no history.
                if (conn.ui) self.historyTo(conn) catch {};
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
                // When the window runs the kitty keyboard protocol
                // or modifyOtherKeys, the client's terminal mirrors
                // it and sends the prefix key encoded.
                const prot: keys.Protocols = if (self.liveWindow()) |w| .{
                    .kitty = w.kittyKeysActive(),
                    .modify = w.modifyKeysActive(),
                } else .{};
                try self.key_parser.feed(msg.payload, prot, Handler{ .daemon = self, .conn = conn });
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
            // Age of the last bell that rang while you were away, or -1
            // for none. Reported against the same `now` as out_idle so
            // the ui can compare the two.
            const bell_idle: i64 = if (self.last_bell_ms != 0)
                @max(0, now - self.last_bell_ms)
            else
                -1;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.alloc);
            try out.print(self.alloc, "{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t", .{
                self.opts.name,
                if (attached) "Attached" else "Detached",
                idle,
                out_idle,
                @intFromBool(self.unread),
                bell_idle,
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
        } else if (std.mem.eql(u8, cmd, "inspect")) {
            // A richer report than `info`, for `boo inspect`: one
            // key<TAB>value per line. The client splits each line on its
            // first tab only, so cwd, command, and title values may
            // themselves contain spaces.
            var clients: usize = 0;
            for (self.conns.items) |c| {
                if (c.attached and !c.closed) clients += 1;
            }
            const w = self.liveWindow();
            const idle: i64 = @max(0, now - self.last_activity_ms);
            const out_idle: i64 = if (w) |lw| @max(0, now - lw.last_output_ms) else 0;
            const pid: posix.pid_t = if (w) |lw| lw.child_pid else 0;
            const screen: []const u8 = if (w) |lw|
                (if (lw.onAltScreen()) "alt" else "primary")
            else
                "primary";

            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.alloc);
            try out.print(self.alloc, "name\t{s}\n", .{self.owned_name orelse self.opts.name});
            try out.print(self.alloc, "state\t{s}\n", .{if (clients > 0) "Attached" else "Detached"});
            try out.print(self.alloc, "clients\t{d}\n", .{clients});
            try out.print(self.alloc, "pid\t{d}\n", .{pid});

            // command: the requested argv, or the resolved shell for a
            // session started with no command.
            try out.appendSlice(self.alloc, "command\t");
            if (self.opts.argv.len > 0) {
                for (self.opts.argv, 0..) |a, i| {
                    if (i > 0) try out.append(self.alloc, ' ');
                    try out.appendSlice(self.alloc, a);
                }
            } else if (w) |lw| {
                try out.appendSlice(self.alloc, lw.command_title);
            }
            try out.append(self.alloc, '\n');

            try out.appendSlice(self.alloc, "cwd\t");
            if (w) |lw| {
                var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (cwd.ofPid(&cwd_buf, lw.child_pid)) |d| try out.appendSlice(self.alloc, d);
            }
            try out.append(self.alloc, '\n');

            try out.print(self.alloc, "rows\t{d}\n", .{self.rows});
            try out.print(self.alloc, "cols\t{d}\n", .{self.cols});
            try out.print(self.alloc, "idle_ms\t{d}\n", .{idle});
            try out.print(self.alloc, "out_idle_ms\t{d}\n", .{out_idle});
            try out.print(self.alloc, "screen\t{s}\n", .{screen});

            // title last; sanitized, so it carries no tabs or newlines.
            try out.appendSlice(self.alloc, "title\t");
            if (w) |lw| {
                for (lw.title()) |byte| {
                    if (byte < 0x20 or byte == 0x7f) continue;
                    try out.append(self.alloc, byte);
                }
            }
            conn.send(.ok, out.items);
        } else if (std.mem.eql(u8, cmd, "cwd")) {
            // Report the session command's current working directory so
            // a new session created from `boo ui` can be born there.
            if (self.liveWindow()) |w| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                if (cwd.ofPid(&buf, w.child_pid)) |dir| {
                    conn.send(.ok, dir);
                } else conn.send(.err, "working directory unavailable");
            } else conn.send(.err, "no window");
        } else if (std.mem.eql(u8, cmd, "rename")) {
            if (argv.len != 2) {
                conn.send(.err, "usage: rename <new-name>");
                return;
            }
            self.rename(conn, argv[1]);
        } else if (std.mem.eql(u8, cmd, "quit")) {
            // Retire the listener before acking: by the time the kill
            // client sees the reply, the socket file is gone, so a
            // follow-up command resolves "no session" instead of
            // connecting to the dying daemon and reading EOF.
            self.retireListener();
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
        // Output produced while nothing is attached marks the session
        // unread, so the ui can flag activity since you last looked.
        // Attaching clears it.
        const detached = self.attachedConn() == null;
        if (detached) self.unread = true;

        // Strip OSC 11 background queries up front and answer them from
        // the reported terminal background. They must not also reach an
        // attached client's real terminal, which would answer them a
        // second time, so this runs before any passthrough forwarding.
        // The filter only removes bytes, so the cleaned copy never
        // outgrows the chunk; on the impossible overflow, fall back to
        // the raw chunk rather than dropping output.
        var clean_buf: [32 * 1024]u8 = undefined;
        var clean_writer = std.Io.Writer.fixed(&clean_buf);
        const cleaned = cleaned: {
            win.filterColorQueries(chunk, &clean_writer) catch break :cleaned chunk;
            break :cleaned clean_writer.buffered();
        };

        const conn = (if (win.passthrough) self.attachedConn() else null) orelse {
            // Not passed through: the window answers queries itself.
            win.feed(cleaned);
            self.noteBell(win, detached, now);
            return;
        };

        // Forward raw bytes, minus alternate-screen toggles: the client
        // canvas cannot switch screens. When the window switches, the
        // rest of the chunk is dropped and the new active screen is
        // repainted from terminal state.
        var out_buf: [32 * 1024 + 32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out_buf);
        // The active screen before this chunk. A switch the filter does
        // not see (a full reset, RIS, returns to the primary screen
        // without a 47/1047/1049 toggle) still has to repaint so the
        // client's `.screen` state stays authoritative.
        const was_alt = win.onAltScreen();
        const result = win.alt_filter.feed(cleaned, &writer) catch
            altscreen.Filter.Result{ .switched = true, .discard_start = 0 };

        // Bytes up to the discard point reach the client's real
        // terminal, which answers any queries among them. The repaint
        // re-renders the discarded tail from terminal state, but it
        // cannot answer queries, so the window must.
        const split = result.discard_start orelse cleaned.len;
        win.feed(cleaned[0..split]);
        if (split < cleaned.len) win.feedDiscarded(cleaned[split..]);
        self.noteBell(win, detached, now);

        const filtered = writer.buffered();
        if (filtered.len > 0) conn.send(.output, filtered);
        // Repaint when the filter stripped a toggle, or when the active
        // screen changed by a path the filter cannot see (e.g. RIS), so
        // a fresh repaint and `.screen` reach the client either way.
        if (result.switched or win.onAltScreen() != was_alt) {
            self.repaintTo(conn) catch |err| {
                log.warn("repaint after screen change failed: {}", .{err});
            };
        }
    }

    /// Consume the window's bell latch. A bell that rang while no client
    /// was attached records the time as an explicit "your turn" signal;
    /// a bell seen while attached already reached the client's terminal,
    /// so it is only cleared.
    fn noteBell(self: *Daemon, win: *Window, detached: bool, now: i64) void {
        if (!win.bell) return;
        win.bell = false;
        if (detached) self.last_bell_ms = now;
    }

    /// Remove closed conns. Runs after every poll dispatch so
    /// iteration above never sees mutation.
    fn sweep(self: *Daemon) void {
        var removed = false;
        var ci: usize = 0;
        while (ci < self.conns.items.len) {
            const c = self.conns.items[ci];
            if (!c.closed) {
                ci += 1;
                continue;
            }
            posix.close(c.fd);
            c.deinit();
            self.alloc.destroy(c);
            _ = self.conns.swapRemove(ci);
            removed = true;
        }
        // A dropped or abruptly closed client may have been the
        // attached view; recompute passthrough so the window resumes
        // answering its own queries once no client remains, instead of
        // staying silent waiting for a terminal that is gone.
        if (removed) self.updatePassthrough();
    }

    // -- Window management ------------------------------------------------

    fn createWindow(
        alloc: std.mem.Allocator,
        session_name: []const u8,
        argv: []const []const u8,
        rows: u16,
        cols: u16,
        cwd_opt: ?[]const u8,
    ) !*Window {
        var env = try std.process.getEnvMap(alloc);
        defer env.deinit();
        try env.put("TERM", "xterm-256color");
        try env.put("BOO", session_name);

        var default_argv: [1][]const u8 = .{env.get("SHELL") orelse "/bin/sh"};
        const child_argv: []const []const u8 = if (argv.len > 0) argv else &default_argv;

        return Window.create(alloc, child_argv, &env, rows, cols, cwd_opt);
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

    /// Send the window's scrollback history to a ui view as a stream of
    /// `output` frames, to be fed before the repaint. The replay can be
    /// larger than one frame, so it is split across messages; the client
    /// feeds them in order into its terminal, so an escape sequence split
    /// across the boundary still parses.
    fn historyTo(self: *Daemon, conn: *Conn) !void {
        const win = self.liveWindow() orelse return;
        const bytes = (try win.historyReplay(self.alloc)) orelse return;
        defer self.alloc.free(bytes);
        var i: usize = 0;
        while (i < bytes.len) {
            const end = @min(i + protocol.max_payload, bytes.len);
            conn.send(.output, bytes[i..end]);
            i = end;
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
        // Close once the detach notice has drained, not before, so the
        // client still receives it.
        conn.shutdown = true;
        self.updatePassthrough();
    }

    fn broadcastExit(self: *Daemon, reason: []const u8) void {
        for (self.conns.items) |c| {
            if (c.closed or c.shutdown) continue;
            c.send(.exit, reason);
            // Drain the exit notice before closing (see drainOutbound).
            c.shutdown = true;
        }
        self.quitting = true;
    }

    /// Best-effort flush of every connection's queued output before
    /// teardown, so a final frame (detach, exit, command reply) still
    /// reaches a client that is reading. Bounded by `shutdown_drain_ms`
    /// so a client that stopped reading cannot delay shutdown.
    fn drainOutbound(self: *Daemon) void {
        const deadline = std.time.milliTimestamp() + shutdown_drain_ms;
        var fds: std.ArrayList(posix.pollfd) = .empty;
        defer fds.deinit(self.alloc);
        while (true) {
            fds.clearRetainingCapacity();
            for (self.conns.items) |c| {
                if (c.closed) continue;
                c.flush();
                if (!c.closed and c.out.items.len > 0) {
                    fds.append(self.alloc, .{
                        .fd = c.fd,
                        .events = posix.POLL.OUT,
                        .revents = 0,
                    }) catch {};
                }
            }
            if (fds.items.len == 0) break;
            const now = std.time.milliTimestamp();
            if (now >= deadline) break;
            _ = posix.poll(fds.items, @intCast(deadline - now)) catch break;
        }
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

test "Conn.send queues output without blocking and flushes in order" {
    const alloc = std.testing.allocator;

    // A non-blocking pipe stands in for the client socket: writing to a
    // full pipe yields WouldBlock just as a full socket send buffer
    // does, so this exercises the queue/flush path without a client.
    const fds = try posix.pipe2(.{ .NONBLOCK = true });
    defer posix.close(fds[0]);

    var conn: Conn = .{ .alloc = alloc, .fd = fds[1], .decoder = .init(alloc) };
    defer {
        posix.close(fds[1]);
        conn.deinit();
    }

    const payload = "x" ** 1024;
    const frame_count: usize = 1000;

    // Nothing reads during this loop, so the pipe fills and the surplus
    // must land in conn.out rather than block the caller. (A blocking
    // write here would hang the test, which is the regression.)
    for (0..frame_count) |_| conn.send(.output, payload);
    try std.testing.expect(!conn.closed);
    try std.testing.expect(conn.out.items.len > 0);

    // Drain: flush what the pipe will take, read it back, repeat. Every
    // frame must arrive intact and in order.
    var decoder: protocol.Decoder = .init(alloc);
    defer decoder.deinit();
    var rbuf: [8192]u8 = undefined;
    var got: usize = 0;
    var guard: usize = 0;
    while (got < frame_count) {
        conn.flush();
        const n = posix.read(fds[0], &rbuf) catch |err| switch (err) {
            error.WouldBlock => {
                guard += 1;
                try std.testing.expect(guard < 1_000_000);
                continue;
            },
            else => return err,
        };
        try std.testing.expect(n != 0);
        try decoder.feed(rbuf[0..n]);
        while (try decoder.next()) |msg| {
            try std.testing.expectEqual(protocol.MsgType.output, msg.type);
            try std.testing.expectEqualStrings(payload, msg.payload);
            got += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), conn.out.items.len);
}

test "Conn.send drops a client that exceeds its output cap" {
    const alloc = std.testing.allocator;

    const fds = try posix.pipe2(.{ .NONBLOCK = true });
    defer posix.close(fds[0]);

    var conn: Conn = .{
        .alloc = alloc,
        .fd = fds[1],
        .decoder = .init(alloc),
        .out_cap = 64 * 1024,
    };
    defer {
        posix.close(fds[1]);
        conn.deinit();
    }

    // Nothing reads, so once the pipe is full the queue grows until it
    // trips out_cap and the connection is dropped instead of buffering
    // without bound. The bound on the loop keeps a regression from
    // hanging the test.
    const payload = "y" ** 4096;
    var i: usize = 0;
    while (!conn.closed and i < 10_000) : (i += 1) conn.send(.output, payload);

    try std.testing.expect(conn.closed);
    try std.testing.expectEqual(@as(usize, 0), conn.out.items.len);
}
