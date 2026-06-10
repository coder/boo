//! Filtering of alternate-screen switches out of passthrough output.
//!
//! The attached client's view lives inside the user terminal's own
//! alternate screen, so raw mode toggles for the alternate screen
//! (47, 1047, 1049) coming from a window must never reach the client:
//! the terminal cannot nest alternate screens, and a raw `1049l` would
//! dump the client onto the user's shell view. Like screen and tmux,
//! the daemon tracks screen state in the terminal emulator, strips the
//! toggles from the byte stream, and repaints the client from terminal
//! state whenever the active screen changes.

const std = @import("std");

/// Modes that switch between the primary and alternate screen.
fn isAltScreenMode(param: u16) bool {
    return param == 47 or param == 1047 or param == 1049;
}

/// Incremental scanner that copies input to a writer, removing any CSI
/// private mode set/reset (`ESC [ ? Pm h|l`) whose parameter list
/// contains an alternate-screen mode. Other escape sequences and all
/// text pass through unchanged. Candidate sequences split across feeds
/// are carried over to the next call.
pub const Filter = struct {
    /// When true, everything after a removed toggle is consumed
    /// without being emitted until `reset` is called. The caller is
    /// expected to follow up with a full repaint that covers the
    /// discarded bytes and to reset the filter at that point.
    discard_after_switch: bool = false,

    state: State = .ground,
    discarding: bool = false,
    /// Candidate sequence bytes held across feeds. Alt-screen toggles
    /// are short; anything that outgrows the buffer is flushed
    /// verbatim and ignored.
    buf: [24]u8 = undefined,
    len: usize = 0,

    const State = enum { ground, esc, csi, params };

    /// Scan `input`, writing passthrough bytes to `writer`. Returns
    /// true if at least one alternate-screen toggle was removed (the
    /// active screen changed and the client needs a repaint).
    pub fn feed(
        self: *Filter,
        input: []const u8,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!bool {
        var switched = false;
        var run_start: usize = 0;
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            const byte = input[i];
            switch (self.state) {
                .ground => {
                    if (byte == 0x1b) {
                        try self.emit(writer, input[run_start..i]);
                        self.hold(byte);
                        self.state = .esc;
                    }
                },
                .esc => switch (byte) {
                    '[' => {
                        self.hold(byte);
                        self.state = .csi;
                    },
                    0x1b => {
                        // New escape; flush the previous lone ESC.
                        try self.flush(writer);
                        self.hold(byte);
                        run_start = i + 1;
                    },
                    else => {
                        try self.flush(writer);
                        self.state = .ground;
                        run_start = i;
                    },
                },
                .csi => switch (byte) {
                    '?' => {
                        self.hold(byte);
                        self.state = .params;
                    },
                    0x1b => {
                        try self.flush(writer);
                        self.hold(byte);
                        self.state = .esc;
                        run_start = i + 1;
                    },
                    else => {
                        try self.flush(writer);
                        self.state = .ground;
                        run_start = i;
                    },
                },
                .params => switch (byte) {
                    '0'...'9', ';' => {
                        if (self.len == self.buf.len) {
                            // Too long to be an alt-screen toggle.
                            try self.flush(writer);
                            self.state = .ground;
                            run_start = i;
                        } else {
                            self.hold(byte);
                        }
                    },
                    'h', 'l' => {
                        self.state = .ground;
                        if (self.paramsSwitchScreen()) {
                            // Drop the toggle entirely. Mixed
                            // parameter lists are dropped too; the
                            // follow-up repaint re-emits the other
                            // modes from terminal state.
                            self.len = 0;
                            switched = true;
                            if (self.discard_after_switch) self.discarding = true;
                        } else {
                            try self.flush(writer);
                            try self.emit(writer, &.{byte});
                        }
                        run_start = i + 1;
                    },
                    0x1b => {
                        try self.flush(writer);
                        self.hold(byte);
                        self.state = .esc;
                        run_start = i + 1;
                    },
                    else => {
                        // Intermediate or unexpected final byte
                        // (e.g. DECRQM's `$`); not a toggle.
                        try self.flush(writer);
                        self.state = .ground;
                        run_start = i;
                    },
                },
            }
        }
        if (self.state == .ground) {
            try self.emit(writer, input[run_start..]);
        }
        return switched;
    }

    /// Forget held bytes and scanning state, and resume emitting. Used
    /// when a repaint replaces the passthrough stream.
    pub fn reset(self: *Filter) void {
        self.state = .ground;
        self.len = 0;
        self.discarding = false;
    }

    fn hold(self: *Filter, byte: u8) void {
        self.buf[self.len] = byte;
        self.len += 1;
    }

    fn emit(self: *Filter, writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
        if (self.discarding or bytes.len == 0) return;
        try writer.writeAll(bytes);
    }

    fn flush(self: *Filter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.emit(writer, self.buf[0..self.len]);
        self.len = 0;
    }

    /// Whether the held `ESC [ ? params` contain an alt-screen mode.
    fn paramsSwitchScreen(self: *const Filter) bool {
        var it = std.mem.splitScalar(u8, self.buf[3..self.len], ';');
        while (it.next()) |param| {
            const value = std.fmt.parseInt(u16, param, 10) catch continue;
            if (isAltScreenMode(value)) return true;
        }
        return false;
    }
};

fn testFeed(filter: *Filter, input: []const u8, expected: []const u8, switched: bool) !void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const got = try filter.feed(input, &writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
    try std.testing.expectEqual(switched, got);
}

test "plain text and ordinary sequences pass through" {
    var f: Filter = .{};
    try testFeed(&f, "hello \x1b[2J\x1b[1;5H\x1b[31mworld", "hello \x1b[2J\x1b[1;5H\x1b[31mworld", false);
}

test "non-screen private modes pass through" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b[?25l\x1b[?2004h\x1b[?1000h", "\x1b[?25l\x1b[?2004h\x1b[?1000h", false);
}

test "alt screen toggles are removed" {
    var f: Filter = .{};
    try testFeed(&f, "a\x1b[?1049hb", "ab", true);
    try testFeed(&f, "c\x1b[?1049ld", "cd", true);
    try testFeed(&f, "\x1b[?47h\x1b[?1047l", "", true);
}

test "mixed parameter list containing alt mode is removed" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b[?25;1049h", "", true);
}

test "sequence split across feeds" {
    var f: Filter = .{};
    try testFeed(&f, "x\x1b[?10", "x", false);
    try testFeed(&f, "49h y", " y", true);
    try testFeed(&f, "\x1b", "", false);
    try testFeed(&f, "[?25h", "\x1b[?25h", false);
}

test "discard after switch suppresses the rest of the feed" {
    var f: Filter = .{ .discard_after_switch = true };
    try testFeed(&f, "before\x1b[?1049hafter\x1b[2J", "before", true);
    // The next feed resumes normal emission.
    f.reset();
    try testFeed(&f, "next", "next", false);
}

test "overlong parameter list is flushed verbatim" {
    var f: Filter = .{};
    const long = "\x1b[?1;2;3;4;5;6;7;8;9;10;11;12h";
    try testFeed(&f, long, long, false);
}

test "DECRQM style sequences pass through" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b[?1049$p", "\x1b[?1049$p", false);
}
