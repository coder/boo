//! Prefix-key (C-a) input processing, GNU screen style.
//!
//! Raw client input is scanned for the escape byte. Bytes that are not
//! part of a command pass through to the active window unchanged.
//!
//! When the active window has the kitty keyboard protocol enabled, the
//! attached client's real terminal mirrors that state (the repaint
//! replays it), so the terminal sends Ctrl+A as `ESC [ 97 ; mods u`
//! instead of 0x01. In that mode the parser also recognizes the CSI-u
//! encodings of the prefix and of the command key that follows it;
//! every other CSI-u sequence passes through to the window unchanged.

const std = @import("std");

pub const escape_byte: u8 = 0x01; // C-a

pub const Command = union(enum) {
    /// Bytes to forward to the window.
    forward: []const u8,
    /// The command key that triggered the detach; C-d (0x04) marks
    /// the detach as EOF-dangerous for the client's input drain.
    detach: u8,
    redraw,
    unknown: u8,
};

pub const Parser = struct {
    /// Whether the previous byte ended inside a prefix sequence.
    pending: bool = false,
    /// CSI-u candidate bytes held until the sequence either completes
    /// or diverges (it can split across reads).
    held: [held_max]u8 = undefined,
    held_len: u8 = 0,

    const held_max = 48;

    /// Process a chunk of input. Calls handler.command(cmd) for every
    /// command, including .forward runs of passthrough bytes. The handler
    /// must consume forwarded slices immediately (they alias `input` or
    /// the parser's internal hold buffer).
    ///
    /// `kitty` enables recognition of kitty-keyboard CSI-u encodings;
    /// pass the active window's protocol state. The raw escape byte is
    /// always recognized in either mode.
    ///
    /// Bindings mirror GNU screen's defaults, including the C-x
    /// variants (`C-a C-d` detaches like `C-a d`).
    pub fn feed(self: *Parser, input: []const u8, kitty: bool, handler: anytype) !void {
        // The terminal left kitty mode while a candidate was held:
        // the bytes belong to the window after all.
        if (!kitty and self.held_len > 0) try self.flushHeld(handler);

        var start: usize = 0;
        var i: usize = 0;
        while (i < input.len) {
            const byte = input[i];

            if (self.held_len > 0) {
                if (self.heldAccepts(byte)) {
                    self.held[self.held_len] = byte;
                    self.held_len += 1;
                    i += 1;
                    start = i;
                    if (byte == 'u') {
                        try self.finishCsiU(handler);
                    } else if (self.held_len == held_max) {
                        try self.flushHeld(handler);
                    }
                } else {
                    // Diverged: not a sequence we intercept. Replay the
                    // held bytes, then re-examine this byte normally.
                    try self.flushHeld(handler);
                }
                continue;
            }

            if (self.pending) {
                if (kitty and byte == 0x1b) {
                    // The command key may arrive kitty-encoded.
                    self.held[0] = byte;
                    self.held_len = 1;
                    i += 1;
                    start = i;
                    continue;
                }
                if (byte == escape_byte) {
                    // The prefix key repeating (held a beat too long)
                    // or pressed again: stay armed instead of
                    // consuming the repeat as a command key, so
                    // C-a .. C-d still detaches.
                    i += 1;
                    start = i;
                    continue;
                }
                self.pending = false;
                i += 1;
                start = i;
                try dispatch(byte, handler);
                continue;
            }

            if (byte == escape_byte) {
                if (i > start) try handler.command(.{ .forward = input[start..i] });
                self.pending = true;
                i += 1;
                start = i;
                continue;
            }

            if (kitty and byte == 0x1b) {
                if (i > start) try handler.command(.{ .forward = input[start..i] });
                self.held[0] = byte;
                self.held_len = 1;
                i += 1;
                start = i;
                continue;
            }

            i += 1;
        }

        if (i > start and !self.pending) {
            try handler.command(.{ .forward = input[start..i] });
        }
    }

    /// Whether `byte` keeps the held bytes a viable candidate for a
    /// CSI-u sequence this parser may intercept. While not pending,
    /// only the prefix key (codepoint 97) is interceptable, so the
    /// codepoint digits are matched strictly; while pending, any
    /// codepoint may decode to a command key.
    fn heldAccepts(self: *const Parser, byte: u8) bool {
        const len = self.held_len;
        if (len == 1) return byte == '[';
        if (self.pending) {
            // ESC [ <digits...> [;:] ... u
            if (len == 2) return byte >= '0' and byte <= '9';
            return switch (byte) {
                '0'...'9', ';', ':' => true,
                'u' => true,
                else => false,
            };
        }
        // ESC [ 9 7 then a section terminator: anything else is some
        // other key or a different control sequence entirely.
        return switch (len) {
            2 => byte == '9',
            3 => byte == '7',
            else => switch (byte) {
                '0'...'9', ';', ':' => true,
                'u' => true,
                else => false,
            },
        };
    }

    /// A complete `ESC [ ... u` sequence is in the hold buffer.
    fn finishCsiU(self: *Parser, handler: anytype) !void {
        const seq = self.held[2 .. self.held_len - 1];
        const key = parseKitty(seq) orelse return self.flushHeld(handler);

        // Modifier bitmask with the lock bits ignored: caps lock or
        // num lock must not hide the prefix.
        const mods = (key.mods -| 1) & 0x3f;
        const ctrl_only = mods == 0x4;
        const plain = mods == 0;
        const release = key.event == 3;

        if (self.pending) {
            self.held_len = 0;
            // A release while a command key is awaited is the prefix
            // key itself being let go; ignore it.
            if (release) return;
            // The prefix key repeating while held (or pressed again)
            // is not a command key; stay armed.
            if (key.cp == 'a' and ctrl_only) return;
            // Modifier and lock keys are reported as keys of their
            // own under the kitty "report all keys" flag; holding or
            // tapping one while armed must not eat the command key.
            if (isModifierKey(key.cp)) return;
            self.pending = false;
            if (ctrl_only and key.cp >= 'a' and key.cp <= 'z') {
                return dispatch(@intCast(key.cp & 0x1f), handler);
            }
            if (plain and key.cp >= 0x20 and key.cp <= 0x7f) {
                return dispatch(@intCast(key.cp), handler);
            }
            return handler.command(.{
                .unknown = if (key.cp <= 0x7f) @intCast(key.cp) else '?',
            });
        }

        if (key.cp == 'a' and ctrl_only) {
            self.held_len = 0;
            // Releases are swallowed: the window never saw the press.
            if (!release) self.pending = true;
            return;
        }

        // Some other key (e.g. Ctrl+Shift+A): the window's input.
        try self.flushHeld(handler);
    }

    /// Replay held bytes as window input. The first held byte while
    /// pending is consumed as the (unrecognized) command key, exactly
    /// as it would have been without the hold.
    fn flushHeld(self: *Parser, handler: anytype) !void {
        const held = self.held[0..self.held_len];
        self.held_len = 0;
        var rest = held;
        if (self.pending) {
            self.pending = false;
            try dispatch(held[0], handler);
            rest = held[1..];
        }
        if (rest.len > 0) try handler.command(.{ .forward = rest });
    }

    fn dispatch(byte: u8, handler: anytype) !void {
        switch (byte) {
            'd', 0x04 => try handler.command(.{ .detach = byte }),
            'l', 0x0c => try handler.command(.redraw),
            'a' => try handler.command(.{ .forward = &.{escape_byte} }),
            else => try handler.command(.{ .unknown = byte }),
        }
    }
};

const KittyKey = struct {
    cp: u32,
    mods: u32,
    event: u32,
};

/// Kitty functional codepoints for keys that never act as command
/// keys: CAPS_LOCK, NUM_LOCK, and LEFT_SHIFT through
/// ISO_LEVEL5_SHIFT (modifiers).
fn isModifierKey(cp: u32) bool {
    return cp == 57358 or cp == 57360 or (cp >= 57441 and cp <= 57454);
}

/// Parse the parameter body of a kitty CSI-u key: sections separated
/// by ';' (codepoint, modifiers, text), subfields by ':'. Returns null
/// when the body is not a well-formed key encoding.
fn parseKitty(body: []const u8) ?KittyKey {
    var key: KittyKey = .{ .cp = 0, .mods = 1, .event = 1 };
    var sections = std.mem.splitScalar(u8, body, ';');

    const cp_section = sections.next() orelse return null;
    var cp_fields = std.mem.splitScalar(u8, cp_section, ':');
    const cp_text = cp_fields.next() orelse return null;
    key.cp = std.fmt.parseInt(u32, cp_text, 10) catch return null;

    if (sections.next()) |mods_section| {
        var mod_fields = std.mem.splitScalar(u8, mods_section, ':');
        if (mod_fields.next()) |mods_text| {
            if (mods_text.len > 0) {
                key.mods = std.fmt.parseInt(u32, mods_text, 10) catch return null;
            }
        }
        if (mod_fields.next()) |event_text| {
            key.event = std.fmt.parseInt(u32, event_text, 10) catch return null;
        }
    }
    // The optional third section (associated text) is irrelevant here.
    return key;
}

const TestHandler = struct {
    alloc: std.mem.Allocator,
    cmds: std.ArrayList(Command) = .empty,
    forwarded: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestHandler) void {
        self.cmds.deinit(self.alloc);
        self.forwarded.deinit(self.alloc);
    }

    fn command(self: *TestHandler, cmd: Command) !void {
        switch (cmd) {
            .forward => |bytes| try self.forwarded.appendSlice(self.alloc, bytes),
            else => try self.cmds.append(self.alloc, cmd),
        }
    }
};

test "plain bytes pass through" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("hello world", false, &h);
    try std.testing.expectEqualStrings("hello world", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "prefix commands" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("ab\x01lde\x01df", false, &h);
    try std.testing.expectEqualStrings("abdef", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 2), h.cmds.items.len);
    try std.testing.expectEqual(Command.redraw, h.cmds.items[0]);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[1]);
}

test "literal escape via C-a a" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x01a", false, &h);
    try std.testing.expectEqualStrings("\x01", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "prefix split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("xy\x01", false, &h);
    try std.testing.expectEqualStrings("xy", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
    try p.feed("d", false, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
}

test "control variants match screen defaults" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x01\x04\x01\x0c", false, &h);
    try std.testing.expectEqual(@as(usize, 2), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(Command.redraw, h.cmds.items[1]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "holding the prefix key stays armed until a command key" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // Auto-repeat of C-a then C-d: one detach, nothing typed into
    // the window (an unconsumed 0x04 would EOF a shell).
    try p.feed("\x01\x01\x01\x04", false, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "unknown command reported" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x01z", false, &h);
    try std.testing.expectEqual(Command{ .unknown = 'z' }, h.cmds.items[0]);
}

test "kitty: encoded Ctrl+A starts the prefix, plain d detaches" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97;5ud", true, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "kitty: encoded Ctrl+A then encoded Ctrl+D detaches" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97;5u\x1b[100;5u", true, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "kitty: report-all plain d arrives as CSI-u and detaches" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97;5u\x1b[100u", true, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
}

test "kitty: sequence split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97;5", true, &h);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try p.feed("ud", true, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
}

test "kitty: press and release events" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // Press (explicit event), release while pending, then the command.
    try p.feed("\x1b[97;5:1u\x1b[97;5:3ud", true, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    // A stray prefix release outside a pending sequence is swallowed.
    try p.feed("\x1b[97;5:3u", true, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "kitty: prefix auto-repeat stays armed" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // With event types: press, repeat, then encoded Ctrl+D.
    try p.feed("\x1b[97;5u\x1b[97;5:2u\x1b[100;5u", true, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "kitty: prefix repeat without event types stays armed" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // Without the event-types flag a repeat looks like a second press.
    try p.feed("\x1b[97;5u\x1b[97;5u\x1b[100;5u", true, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "kitty: modifier key events while armed do not eat the command" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // A reported left-ctrl press between the prefix and the command
    // (kitty report-all-keys flag) is not the command key.
    try p.feed("\x1b[97;5u\x1b[57442;5u\x1b[100;5u", true, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "kitty: lock modifiers do not hide the prefix" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // mods 69 = 1 + ctrl(4) + caps lock(64).
    try p.feed("\x1b[97;69ud", true, &h);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
}

test "kitty: other CSI-u keys pass through verbatim" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // Ctrl+B, Ctrl+Shift+A, and a bare 97 with no ctrl: all window input.
    try p.feed("\x1b[98;5u", true, &h);
    try std.testing.expectEqualStrings("\x1b[98;5u", h.forwarded.items);
    h.forwarded.clearRetainingCapacity();
    try p.feed("\x1b[97;6u", true, &h);
    try std.testing.expectEqualStrings("\x1b[97;6u", h.forwarded.items);
    h.forwarded.clearRetainingCapacity();
    try p.feed("\x1b[97u", true, &h);
    try std.testing.expectEqualStrings("\x1b[97u", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "kitty: diverging sequences replay their held bytes" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // An arrow key (CSI A) and a longer codepoint (979) are not held
    // hostage; raw ESC alone in kitty mode is held until disambiguated.
    try p.feed("\x1b[Ax", true, &h);
    try std.testing.expectEqualStrings("\x1b[Ax", h.forwarded.items);
    h.forwarded.clearRetainingCapacity();
    try p.feed("\x1b[979u", true, &h);
    try std.testing.expectEqualStrings("\x1b[979u", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "kitty: raw 0x01 still works" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x01d", true, &h);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
}

test "kitty: CSI-u encodings pass through when kitty mode is off" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97;5ud", false, &h);
    try std.testing.expectEqualStrings("\x1b[97;5ud", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "kitty: hold flushed when kitty mode turns off mid-sequence" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97", true, &h);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try p.feed(";5ud", false, &h);
    try std.testing.expectEqualStrings("\x1b[97;5ud", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "kitty: pending command key in CSI-u form split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97;5u\x1b[100;", true, &h);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
    try p.feed("5u", true, &h);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
}
