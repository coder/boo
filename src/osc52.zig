//! Forwarding of application OSC 52 clipboard *writes* to the real
//! terminal for `boo ui`.
//!
//! A `boo ui` view never passes session output through to the terminal
//! raw. The focused session feeds a client-side libghostty terminal and
//! the UI repaints the viewport from that terminal's state (see the
//! header of `ui.zig`). libghostty-vt parses OSC 52 but exposes no
//! clipboard effect, so an application that copies text itself (an
//! editor's yank, a pager's mouse selection, anything emitting
//! `ESC ] 52 ; c ; <base64> BEL`) has its clipboard write silently
//! dropped instead of reaching the user's terminal. A plain `boo attach`
//! does not have this problem: its output is written to the real
//! terminal byte for byte, OSC 52 included.
//!
//! This scanner recovers the `boo ui` case. It watches the same
//! passthrough bytes the view-canvas consumes and, on a complete OSC 52
//! clipboard write, hands the verbatim sequence to a sink that writes it
//! to the real terminal, exactly as the ui's own selection copy does
//! (`copySelection` in `ui.zig`). The clipboard write then works over
//! SSH and through nested multiplexers like any other OSC 52.
//!
//! Only writes are forwarded. A read request (`ESC ] 52 ; c ; ? ST`)
//! asks the terminal to send the clipboard *back* to the application; a
//! remote session must not be able to read the user's local clipboard,
//! so a `?` payload is recognized and ignored. Sequences split across
//! feeds are carried over to the next call.

const std = @import("std");

/// `ESC ] 5 2 ;`: the exact prefix of an OSC 52 sequence. The trailing
/// `;` keeps neighbours such as OSC 520 from matching.
const prefix = "\x1b]52;";

/// Cap on a single buffered clipboard write. The payload is base64, so
/// this still allows roughly 1.5 MiB of copied text. A larger write is
/// dropped rather than buffered without bound: its tail is base64 plus a
/// BEL or ST terminator, none of which can be mistaken for a new OSC 52
/// prefix, so abandoning it to the ground state never produces a false
/// match.
const max_seq = 2 * 1024 * 1024;

/// Incremental scanner over a session's output. It emits nothing of its
/// own; it only recognizes OSC 52 clipboard writes and forwards them.
/// Held candidate bytes persist across feeds so a write split over reads
/// is still recognized.
pub const Filter = struct {
    /// Bytes of an in-progress candidate, starting at ESC. Empty in the
    /// ground state.
    buf: std.ArrayList(u8) = .empty,
    /// The previous body byte was an ESC that may begin an ST terminator
    /// (`ESC \`).
    esc_pending: bool = false,

    pub fn deinit(self: *Filter, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }

    /// Scan `input`. On each complete OSC 52 clipboard write, call
    /// `sink.clipboard(seq)` with the verbatim sequence bytes, terminator
    /// included. `sink` is any value (or pointer) exposing that method.
    pub fn feed(
        self: *Filter,
        alloc: std.mem.Allocator,
        input: []const u8,
        sink: anytype,
    ) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < input.len) {
            const byte = input[i];
            var advance = true;

            if (self.buf.items.len == 0) {
                // Ground: only ESC can begin a candidate. Skip the run
                // of non-ESC bytes to the next ESC in one vectorized pass.
                if (byte != 0x1b) {
                    const rel = std.mem.indexOfScalar(u8, input[i..], 0x1b) orelse input.len - i;
                    i += rel;
                    continue;
                }
                try self.buf.append(alloc, byte);
            } else if (self.buf.items.len < prefix.len) {
                // Matching the fixed prefix one byte at a time.
                if (byte == prefix[self.buf.items.len]) {
                    try self.buf.append(alloc, byte);
                } else {
                    // Not OSC 52 after all. Drop the candidate and
                    // reconsider this byte from the ground state, so an
                    // ESC that starts a fresh candidate is not lost.
                    self.reset();
                    advance = false;
                }
            } else if (self.esc_pending) {
                self.esc_pending = false;
                if (byte == '\\') {
                    // ST terminator (`ESC \`) completes the sequence.
                    try self.buf.append(alloc, byte);
                    self.emit(sink);
                    self.reset();
                } else {
                    // The ESC did not form ST: a malformed OSC. Abandon
                    // it and reconsider this byte from the ground state.
                    self.reset();
                    advance = false;
                }
            } else if (byte == 0x07) {
                // BEL terminator completes the sequence.
                try self.buf.append(alloc, byte);
                self.emit(sink);
                self.reset();
            } else {
                // Body: base64 data up to a BEL or ST terminator. Neither
                // terminator byte occurs in base64, so accumulate the
                // whole run in one copy instead of byte by byte.
                const rest = input[i..];
                const run = std.mem.indexOfAny(u8, rest, &[_]u8{ 0x07, 0x1b }) orelse rest.len;
                if (run == 0) {
                    // The byte is ESC (BEL is handled above); it may open ST.
                    try self.buf.append(alloc, byte);
                    self.esc_pending = true;
                } else if (self.buf.items.len + run > max_seq) {
                    // Oversized: drop it. The skipped tail is base64 plus
                    // a terminator, never a new OSC 52 prefix (see max_seq).
                    self.reset();
                    i += run;
                    continue;
                } else {
                    try self.buf.appendSlice(alloc, rest[0..run]);
                    i += run;
                    continue;
                }
            }

            if (advance) i += 1;
        }
    }

    fn reset(self: *Filter) void {
        self.buf.clearRetainingCapacity();
        self.esc_pending = false;
    }

    /// Forward a completed candidate, unless it is a read request.
    fn emit(self: *Filter, sink: anytype) void {
        if (isWrite(self.buf.items)) sink.clipboard(self.buf.items);
    }
};

/// Whether a complete OSC 52 sequence is a clipboard *write* (data to
/// store) rather than a read request (`?`). The sequence is
/// `ESC ] 52 ; <Pc> ; <Pd> <terminator>`; a read request's `<Pd>` is `?`.
fn isWrite(seq: []const u8) bool {
    if (seq.len < prefix.len) return false;
    // After the prefix: `<Pc> ; <Pd> <terminator>`.
    const rest = seq[prefix.len..];
    const semi = std.mem.indexOfScalar(u8, rest, ';') orelse return false;
    var pd = rest[semi + 1 ..];
    // Strip the terminator (BEL, or the two-byte ST `ESC \`).
    if (pd.len >= 1 and pd[pd.len - 1] == 0x07) {
        pd = pd[0 .. pd.len - 1];
    } else if (pd.len >= 2 and pd[pd.len - 2] == 0x1b and pd[pd.len - 1] == '\\') {
        pd = pd[0 .. pd.len - 2];
    }
    // A read request is a literal `?`. Anything else (base64, or empty
    // to clear the clipboard) is a write.
    return !(pd.len > 0 and pd[0] == '?');
}

const Collector = struct {
    alloc: std.mem.Allocator,
    seqs: std.ArrayList([]u8) = .empty,

    fn clipboard(self: *Collector, seq: []const u8) void {
        const dup = self.alloc.dupe(u8, seq) catch return;
        self.seqs.append(self.alloc, dup) catch self.alloc.free(dup);
    }

    fn deinit(self: *Collector) void {
        for (self.seqs.items) |s| self.alloc.free(s);
        self.seqs.deinit(self.alloc);
    }
};

fn expectForwards(input: []const u8, expected: []const []const u8) !void {
    const alloc = std.testing.allocator;
    var f: Filter = .{};
    defer f.deinit(alloc);
    var c: Collector = .{ .alloc = alloc };
    defer c.deinit();
    try f.feed(alloc, input, &c);
    try std.testing.expectEqual(expected.len, c.seqs.items.len);
    for (expected, c.seqs.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "clipboard write with BEL terminator is forwarded verbatim" {
    try expectForwards(
        "before\x1b]52;c;SGVsbG8=\x07after",
        &.{"\x1b]52;c;SGVsbG8=\x07"},
    );
}

test "clipboard write with ST terminator is forwarded verbatim" {
    try expectForwards(
        "\x1b]52;c;SGVsbG8=\x1b\\",
        &.{"\x1b]52;c;SGVsbG8=\x1b\\"},
    );
}

test "a read request is not forwarded" {
    try expectForwards("\x1b]52;c;?\x07", &.{});
}

test "an empty payload (clear) is forwarded" {
    try expectForwards("\x1b]52;c;\x07", &.{"\x1b]52;c;\x07"});
}

test "an empty Pc field is forwarded" {
    try expectForwards("\x1b]52;;QQ==\x07", &.{"\x1b]52;;QQ==\x07"});
}

test "a write split across feeds is recognized" {
    const alloc = std.testing.allocator;
    var f: Filter = .{};
    defer f.deinit(alloc);
    var c: Collector = .{ .alloc = alloc };
    defer c.deinit();
    try f.feed(alloc, "x\x1b]52;c;SGVs", &c);
    try std.testing.expectEqual(@as(usize, 0), c.seqs.items.len);
    try f.feed(alloc, "bG8=\x07y", &c);
    try std.testing.expectEqual(@as(usize, 1), c.seqs.items.len);
    try std.testing.expectEqualStrings("\x1b]52;c;SGVsbG8=\x07", c.seqs.items[0]);
}

test "a read request split across feeds is still ignored" {
    const alloc = std.testing.allocator;
    var f: Filter = .{};
    defer f.deinit(alloc);
    var c: Collector = .{ .alloc = alloc };
    defer c.deinit();
    try f.feed(alloc, "\x1b]52;c;", &c);
    try f.feed(alloc, "?\x07", &c);
    try std.testing.expectEqual(@as(usize, 0), c.seqs.items.len);
}

test "back-to-back writes are both forwarded" {
    try expectForwards(
        "\x1b]52;c;QQ==\x07\x1b]52;p;Qg==\x1b\\",
        &.{ "\x1b]52;c;QQ==\x07", "\x1b]52;p;Qg==\x1b\\" },
    );
}

test "OSC 520 and other OSC sequences are not matched" {
    try expectForwards("\x1b]520;c;QQ==\x07", &.{});
    try expectForwards("\x1b]2;a title\x07", &.{});
    try expectForwards("\x1b]11;rgb:1234/5678/9abc\x07", &.{});
}

test "plain text and CSI sequences pass without a match" {
    try expectForwards("hello \x1b[2J\x1b[1;5H\x1b[31mworld", &.{});
}

test "a near-miss prefix then a real write still forwards the write" {
    // ESC ] 5 3 aborts the candidate; the following real write matches.
    try expectForwards(
        "\x1b]53;c;QQ==\x07\x1b]52;c;Qg==\x07",
        &.{"\x1b]52;c;Qg==\x07"},
    );
}

test "a long under-cap payload is buffered and forwarded" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    try input.appendSlice(alloc, "\x1b]52;c;");
    try input.appendSlice(alloc, "QQ==" ** 4096); // ~16 KiB of base64
    try input.append(alloc, 0x07);

    var f: Filter = .{};
    defer f.deinit(alloc);
    var c: Collector = .{ .alloc = alloc };
    defer c.deinit();
    try f.feed(alloc, input.items, &c);
    try std.testing.expectEqual(@as(usize, 1), c.seqs.items.len);
    try std.testing.expectEqualStrings(input.items, c.seqs.items[0]);
}
