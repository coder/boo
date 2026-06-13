//! Prefix-key (C-a) input processing, GNU screen style.
//!
//! Raw client input is scanned for the escape byte. Bytes that are not
//! part of a command pass through to the active window unchanged.
//!
//! When the active window has the kitty keyboard protocol or xterm
//! modifyOtherKeys (mode 2) enabled, the attached client's real
//! terminal mirrors that state (the repaint replays it), so the
//! terminal may send Ctrl+A as `ESC [ 97 ; mods u` or
//! `ESC [ 27 ; mods ; 97 ~` instead of 0x01. With the matching
//! protocol active the parser also recognizes those encodings of the
//! prefix and of the command key that follows it; every other encoded
//! key passes through to the window unchanged.

const std = @import("std");

pub const escape_byte: u8 = 0x01; // C-a

/// Which keyboard protocols the client's real terminal currently has
/// active, mirrored from the focused window or view. Gates which
/// input encodings the parsers decode; everything else is held only
/// long enough to know it is not an encoded prefix, then replayed
/// verbatim.
pub const Protocols = struct {
    /// Kitty keyboard protocol: CSI-u keys decode.
    kitty: bool = false,
    /// xterm modifyOtherKeys mode 2: CSI 27;mods;cp~ keys decode.
    modify: bool = false,

    pub fn any(self: Protocols) bool {
        return self.kitty or self.modify;
    }
};

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
    /// Encoded-key candidate bytes held until the sequence either
    /// completes or diverges (it can split across reads).
    held: [held_max]u8 = undefined,
    held_len: u8 = 0,
    /// Protocol state of the most recent feed; gates which finals the
    /// hold grammar accepts and which sequences decode.
    prot: Protocols = .{},

    const held_max = 48;

    /// Process a chunk of input. Calls handler.command(cmd) for every
    /// command, including .forward runs of passthrough bytes. The handler
    /// must consume forwarded slices immediately (they alias `input` or
    /// the parser's internal hold buffer).
    ///
    /// `prot` enables recognition of kitty-keyboard CSI-u and
    /// modifyOtherKeys encodings; pass the active window's protocol
    /// state. The raw escape byte is always recognized in any mode.
    ///
    /// Bindings mirror GNU screen's defaults, including the C-x
    /// variants (`C-a C-d` detaches like `C-a d`).
    pub fn feed(self: *Parser, input: []const u8, prot: Protocols, handler: anytype) !void {
        self.prot = prot;
        // The terminal left every keyboard protocol while a candidate
        // was held: the bytes belong to the window after all.
        if (!prot.any() and self.held_len > 0) try self.flushHeld(handler);

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
                    } else if (byte == '~') {
                        try self.finishModify(handler);
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
                if (prot.any() and byte == 0x1b) {
                    // The command key may arrive encoded.
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

            if (prot.any() and byte == 0x1b) {
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

    /// Whether `byte` keeps the held bytes a viable candidate for an
    /// encoded key this parser may intercept:
    /// `ESC [ <digits...> [;:] ... u` (kitty CSI-u) or
    /// `ESC [ 27 ; mods ; cp ~` (modifyOtherKeys). The finals are
    /// gated on the matching protocol being active; the digit body is
    /// shared. Codepoints are not matched structurally here because a
    /// non-Latin layout's prefix key reports the layout codepoint
    /// first and the standard-layout key in a subfield, so any
    /// complete key may turn out to be the prefix.
    fn heldAccepts(self: *const Parser, byte: u8) bool {
        const len = self.held_len;
        if (len == 1) return byte == '[';
        if (len == 2) return byte >= '0' and byte <= '9';
        return switch (byte) {
            '0'...'9', ';', ':' => true,
            'u' => self.prot.kitty,
            '~' => self.prot.modify,
            else => false,
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
        const cp = effectiveCp(key);

        if (self.pending) {
            self.held_len = 0;
            // A release while a command key is awaited is the prefix
            // key itself being let go; ignore it.
            if (release) return;
            // The prefix key repeating while held (or pressed again)
            // is not a command key; stay armed.
            if (cp == 'a' and ctrl_only) return;
            // Modifier and lock keys are reported as keys of their
            // own under the kitty "report all keys" flag; holding or
            // tapping one while armed must not eat the command key.
            if (isModifierKey(key.cp)) return;
            self.pending = false;
            if (ctrl_only and cp >= 'a' and cp <= 'z') {
                return dispatch(@intCast(cp & 0x1f), handler);
            }
            if (plain and cp >= 0x20 and cp <= 0x7f) {
                return dispatch(@intCast(cp), handler);
            }
            return handler.command(.{
                .unknown = if (cp <= 0x7f) @intCast(cp) else '?',
            });
        }

        if (cp == 'a' and ctrl_only) {
            self.held_len = 0;
            // Releases are swallowed: the window never saw the press.
            if (!release) self.pending = true;
            return;
        }

        // Some other key (e.g. Ctrl+Shift+A): the window's input.
        try self.flushHeld(handler);
    }

    /// A complete `ESC [ ... ~` sequence is in the hold buffer: an
    /// xterm modifyOtherKeys (mode 2) candidate. The protocol has no
    /// event types (every sequence is a press or auto-repeat) and no
    /// alternate keys, so the prefix logic is simpler than CSI-u.
    fn finishModify(self: *Parser, handler: anytype) !void {
        const seq = self.held[2 .. self.held_len - 1];
        const key = parseModify(seq) orelse return self.flushHeld(handler);

        const mods = (key.mods -| 1) & 0x3f;
        const ctrl_only = mods == 0x4;
        const plain = mods == 0;

        if (self.pending) {
            self.held_len = 0;
            // The prefix key repeating (or pressed again) is not a
            // command key; stay armed, like the raw byte.
            if (key.cp == 'a' and ctrl_only) return;
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
            self.pending = true;
            return;
        }

        // Some other key (e.g. Ctrl+Shift+H): the window's input.
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

/// A decoded kitty CSI-u key. `cp` is the unshifted unicode
/// codepoint, `mods` the raw kitty modifier value (1 means none; the
/// bitmask is `mods - 1`), `event` the kind of event (1 press,
/// 2 repeat, 3 release), and `base` the key at the same position in
/// the standard PC-101 layout, reported (under the alternate-keys
/// flag) when the active layout differs.
pub const KittyKey = struct {
    cp: u32,
    mods: u32,
    event: u32,
    base: ?u32 = null,
};

/// A decoded xterm modifyOtherKeys (mode 2) key: `CSI 27;mods;cp~`.
/// `mods` uses the same encoding as kitty (1 means none).
pub const ModifyKey = struct {
    cp: u32,
    mods: u32,
};

/// The codepoint used for prefix and command-key matching. A
/// non-Latin layout (Cyrillic and friends) reports its own codepoint
/// first and the standard-layout key in the base subfield; matching
/// the base makes C-a layout-independent, the way kitty recommends
/// shortcuts match. ASCII primaries always win, so Latin layouts
/// that merely move keys around (AZERTY) keep their typed-character
/// semantics, exactly like the legacy byte encodings.
pub fn effectiveCp(key: KittyKey) u32 {
    if (key.cp < 0x80) return key.cp;
    return key.base orelse key.cp;
}

/// Kitty functional codepoints for keys that never act as command
/// keys: CAPS_LOCK, SCROLL_LOCK, NUM_LOCK, and LEFT_SHIFT through
/// ISO_LEVEL5_SHIFT (modifiers).
pub fn isModifierKey(cp: u32) bool {
    return (cp >= 57358 and cp <= 57360) or (cp >= 57441 and cp <= 57454);
}

/// Parse the parameter body of a kitty CSI-u key: sections separated
/// by ';' (codepoint, modifiers, text), subfields by ':' (codepoint,
/// shifted key, base layout key). Returns null when the body is not
/// a well-formed key encoding.
pub fn parseKitty(body: []const u8) ?KittyKey {
    var key: KittyKey = .{ .cp = 0, .mods = 1, .event = 1 };
    var sections = std.mem.splitScalar(u8, body, ';');

    const cp_section = sections.next() orelse return null;
    var cp_fields = std.mem.splitScalar(u8, cp_section, ':');
    const cp_text = cp_fields.next() orelse return null;
    key.cp = std.fmt.parseInt(u32, cp_text, 10) catch return null;
    // The shifted key (irrelevant here: the prefix and command keys
    // are unshifted) may be empty when only the base key is reported.
    if (cp_fields.next()) |shifted_text| {
        if (shifted_text.len > 0) {
            _ = std.fmt.parseInt(u32, shifted_text, 10) catch return null;
        }
    }
    if (cp_fields.next()) |base_text| {
        if (base_text.len > 0) {
            key.base = std.fmt.parseInt(u32, base_text, 10) catch return null;
        }
    }

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

/// Parse the parameter body of an xterm modifyOtherKeys (mode 2)
/// sequence: `27 ; modifiers ; codepoint`. Returns null when the
/// body is not exactly that shape (paste markers and function keys
/// share the '~' final but never the 27 marker).
pub fn parseModify(body: []const u8) ?ModifyKey {
    var sections = std.mem.splitScalar(u8, body, ';');
    const marker = sections.next() orelse return null;
    if (!std.mem.eql(u8, marker, "27")) return null;
    const mods_text = sections.next() orelse return null;
    const cp_text = sections.next() orelse return null;
    if (sections.next() != null) return null;
    return .{
        .cp = std.fmt.parseInt(u32, cp_text, 10) catch return null,
        .mods = std.fmt.parseInt(u32, mods_text, 10) catch return null,
    };
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
    try p.feed("hello world", .{}, &h);
    try std.testing.expectEqualStrings("hello world", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "prefix commands" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("ab\x01lde\x01df", .{}, &h);
    try std.testing.expectEqualStrings("abdef", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 2), h.cmds.items.len);
    try std.testing.expectEqual(Command.redraw, h.cmds.items[0]);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[1]);
}

test "literal escape via C-a a" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x01a", .{}, &h);
    try std.testing.expectEqualStrings("\x01", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "prefix split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("xy\x01", .{}, &h);
    try std.testing.expectEqualStrings("xy", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
    try p.feed("d", .{}, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
}

test "control variants match screen defaults" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x01\x04\x01\x0c", .{}, &h);
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
    try p.feed("\x01\x01\x01\x04", .{}, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "unknown command reported" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x01z", .{}, &h);
    try std.testing.expectEqual(Command{ .unknown = 'z' }, h.cmds.items[0]);
}

test "kitty: encoded Ctrl+A starts the prefix, plain d detaches" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97;5ud", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "kitty: encoded Ctrl+A then encoded Ctrl+D detaches" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97;5u\x1b[100;5u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "kitty: report-all plain d arrives as CSI-u and detaches" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97;5u\x1b[100u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
}

test "kitty: sequence split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97;5", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try p.feed("ud", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
}

test "kitty: press and release events" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // Press (explicit event), release while pending, then the command.
    try p.feed("\x1b[97;5:1u\x1b[97;5:3ud", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    // A stray prefix release outside a pending sequence is swallowed.
    try p.feed("\x1b[97;5:3u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "kitty: prefix auto-repeat stays armed" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // With event types: press, repeat, then encoded Ctrl+D.
    try p.feed("\x1b[97;5u\x1b[97;5:2u\x1b[100;5u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "kitty: prefix repeat without event types stays armed" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // Without the event-types flag a repeat looks like a second press.
    try p.feed("\x1b[97;5u\x1b[97;5u\x1b[100;5u", .{ .kitty = true }, &h);
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
    try p.feed("\x1b[97;5u\x1b[57442;5u\x1b[100;5u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "kitty: lock modifiers do not hide the prefix" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // mods 69 = 1 + ctrl(4) + caps lock(64).
    try p.feed("\x1b[97;69ud", .{ .kitty = true }, &h);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
}

test "kitty: other CSI-u keys pass through verbatim" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // Ctrl+B, Ctrl+Shift+A, and a bare 97 with no ctrl: all window input.
    try p.feed("\x1b[98;5u", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[98;5u", h.forwarded.items);
    h.forwarded.clearRetainingCapacity();
    try p.feed("\x1b[97;6u", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[97;6u", h.forwarded.items);
    h.forwarded.clearRetainingCapacity();
    try p.feed("\x1b[97u", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[97u", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "kitty: diverging sequences replay their held bytes" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // An arrow key (CSI A) and a longer codepoint (979) are not held
    // hostage; raw ESC alone in kitty mode is held until disambiguated.
    try p.feed("\x1b[Ax", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[Ax", h.forwarded.items);
    h.forwarded.clearRetainingCapacity();
    try p.feed("\x1b[979u", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[979u", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "kitty: raw 0x01 still works" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x01d", .{ .kitty = true }, &h);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
}

test "kitty: CSI-u encodings pass through when kitty mode is off" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97;5ud", .{}, &h);
    try std.testing.expectEqualStrings("\x1b[97;5ud", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "kitty: hold flushed when kitty mode turns off mid-sequence" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try p.feed(";5ud", .{}, &h);
    try std.testing.expectEqualStrings("\x1b[97;5ud", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "kitty: pending command key in CSI-u form split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[97;5u\x1b[100;", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
    try p.feed("5u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
}

test "kitty: non-latin layout prefix and command match the base key" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // Russian layout: Ctrl+(A position) reports cyrillic ef (1092),
    // shifted EF (1060), base 'a'; Ctrl+(D position) reports cyrillic
    // de (1076), no shifted subfield, base 'd'. The alternate-keys
    // flag is what makes the base subfield available.
    try p.feed("\x1b[1092:1060:97;5u\x1b[1076::100;5u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    // A plain command key matches through its base as well: C-a then
    // the unmodified D-position key still detaches.
    try p.feed("\x1b[1092:1060:97;5u\x1b[1076::100u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 2), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[1]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "kitty: ascii primaries win over the base key" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // AZERTY: the key at the PC-101 'a' position types 'q' (cp 113,
    // base 97). The typed character wins, exactly like the legacy
    // 0x11 byte it sends without the protocol: not the prefix.
    try p.feed("\x1b[113:81:97;5u", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[113:81:97;5u", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "modify: encoded Ctrl+A starts the prefix, plain d detaches" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[27;5;97~d", .{ .modify = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "modify: encoded Ctrl+A then encoded Ctrl+D detaches" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[27;5;97~\x1b[27;5;100~", .{ .modify = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "modify: prefix auto-repeat stays armed" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // modifyOtherKeys has no event types: a held prefix repeats the
    // same press sequence, which must not eat the command key.
    try p.feed("\x1b[27;5;97~\x1b[27;5;97~\x1b[27;5;100~", .{ .modify = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "modify: other encoded keys pass through verbatim" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // Ctrl+Shift+H (mods 6) and an F-key sharing the '~' final: all
    // window input, replayed whole.
    try p.feed("\x1b[27;6;72~", .{ .modify = true }, &h);
    try std.testing.expectEqualStrings("\x1b[27;6;72~", h.forwarded.items);
    h.forwarded.clearRetainingCapacity();
    try p.feed("\x1b[15;5~", .{ .modify = true }, &h);
    try std.testing.expectEqualStrings("\x1b[15;5~", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "modify: encodings pass through when the mode is off" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[27;5;97~d", .{}, &h);
    try std.testing.expectEqualStrings("\x1b[27;5;97~d", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
    // With only kitty active the '~' final diverges and replays.
    try p.feed("\x1b[27;5;97~", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[27;5;97~d\x1b[27;5;97~", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "modify: sequence split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x1b[27;5", .{ .modify = true }, &h);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try p.feed(";97~d", .{ .modify = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command{ .detach = 'd' }, h.cmds.items[0]);
}

test "modify: kitty and modify decode side by side" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    // Both protocols active: either prefix encoding arms, either
    // command encoding dispatches.
    const both: Protocols = .{ .kitty = true, .modify = true };
    try p.feed("\x1b[27;5;97~\x1b[100;5u", both, &h);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[0]);
    try p.feed("\x1b[97;5u\x1b[27;5;100~", both, &h);
    try std.testing.expectEqual(Command{ .detach = 0x04 }, h.cmds.items[1]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}
