//! Filtering of OSC 11 background-color *queries* out of a window's
//! output stream.
//!
//! Applications detect the terminal's light/dark theme by querying the
//! background color with OSC 11 (`ESC ] 11 ; ? BEL`). Inside a boo
//! session the real terminal is not reachable: a `boo attach` strips the
//! query along with the alternate-screen tail it rides behind, and a
//! `boo ui` view renders into a client-side terminal that never answers
//! it. The daemon therefore answers these queries itself from the
//! background a client reported (see `window.zig`).
//!
//! For that answer to be the only one, the query must not also reach the
//! real terminal, or an attached client would see a duplicate reply land
//! in its input. This filter removes the query from the passthrough
//! stream and reports each removal so the caller can produce exactly one
//! reply. Only the background query (OSC 11) is stripped; OSC 10/12 and
//! every other sequence pass through unchanged. Candidate sequences split
//! across feeds are carried over to the next call.

const std = @import("std");

/// The two encodings of an OSC 11 background query: BEL-terminated (what
/// nvim and most apps send) and ST-terminated (`ESC \`).
const query_bel = "\x1b]11;?\x07";
const query_st = "\x1b]11;?\x1b\\";

const Match = enum { no, partial, complete };

/// Classify `bytes` against a single target: a strict prefix is
/// `partial`, an exact match is `complete`, anything else is `no`.
fn matchTarget(target: []const u8, bytes: []const u8) Match {
    if (bytes.len > target.len) return .no;
    if (!std.mem.eql(u8, target[0..bytes.len], bytes)) return .no;
    return if (bytes.len == target.len) .complete else .partial;
}

/// Classify `bytes` against both query encodings, taking the strongest
/// result (a complete match of either, else a partial of either).
fn classify(bytes: []const u8) Match {
    const bel = matchTarget(query_bel, bytes);
    const st = matchTarget(query_st, bytes);
    if (bel == .complete or st == .complete) return .complete;
    if (bel == .partial or st == .partial) return .partial;
    return .no;
}

/// Incremental scanner that copies input to a writer, removing any OSC 11
/// background query. Held candidate bytes persist across feeds so a query
/// split over reads is still recognized.
pub const Filter = struct {
    /// Held candidate bytes: always a strict prefix of an OSC 11 query.
    /// Empty when not mid-candidate. The longest prefix is
    /// `ESC ] 1 1 ; ? ESC` (8 bytes, awaiting the ST `\`).
    buf: [16]u8 = undefined,
    len: usize = 0,

    pub const Result = struct {
        /// Number of OSC 11 background queries removed from the stream.
        background_queries: usize = 0,
    };

    /// Scan `input`, writing passthrough bytes to `writer` and removing
    /// OSC 11 background queries. Reports how many were removed.
    pub fn feed(
        self: *Filter,
        input: []const u8,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!Result {
        var result: Result = .{};
        var run_start: usize = 0;
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            const byte = input[i];
            if (self.len == 0) {
                // Ground: only ESC can begin a query candidate.
                if (byte == 0x1b) {
                    try writer.writeAll(input[run_start..i]);
                    self.hold(byte);
                }
                continue;
            }

            // Mid-candidate: try to extend the held prefix by one byte.
            self.buf[self.len] = byte;
            switch (classify(self.buf[0 .. self.len + 1])) {
                .partial => self.len += 1,
                .complete => {
                    // A full query: drop it. The daemon answers it.
                    self.len = 0;
                    result.background_queries += 1;
                    run_start = i + 1;
                },
                .no => {
                    // The held prefix was ordinary output after all;
                    // emit it verbatim, then reconsider the current byte.
                    try writer.writeAll(self.buf[0..self.len]);
                    self.len = 0;
                    if (byte == 0x1b) {
                        self.hold(byte);
                        run_start = i + 1;
                    } else {
                        run_start = i;
                    }
                },
            }
        }
        if (self.len == 0) {
            try writer.writeAll(input[run_start..]);
        }
        return result;
    }

    fn hold(self: *Filter, byte: u8) void {
        self.buf[self.len] = byte;
        self.len += 1;
    }
};

fn testFeed(filter: *Filter, input: []const u8, expected: []const u8, queries: usize) !void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const got = try filter.feed(input, &writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
    try std.testing.expectEqual(queries, got.background_queries);
}

test "plain text and ordinary sequences pass through" {
    var f: Filter = .{};
    try testFeed(&f, "hello \x1b[2J\x1b[1;5H\x1b[31mworld", "hello \x1b[2J\x1b[1;5H\x1b[31mworld", 0);
}

test "OSC 11 background query (BEL) is removed" {
    var f: Filter = .{};
    try testFeed(&f, "a\x1b]11;?\x07b", "ab", 1);
}

test "OSC 11 background query (ST) is removed" {
    var f: Filter = .{};
    try testFeed(&f, "a\x1b]11;?\x1b\\b", "ab", 1);
}

test "query right after an alt-screen switch is removed" {
    // The exact shape nvim/helix emit: enter alt screen, clear, query.
    var f: Filter = .{};
    try testFeed(
        &f,
        "\x1b[?1049h\x1b[H\x1b[2J\x1b]11;?\x07rest",
        "\x1b[?1049h\x1b[H\x1b[2Jrest",
        1,
    );
}

test "OSC 11 set (not a query) passes through" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b]11;rgb:1234/5678/9abc\x07", "\x1b]11;rgb:1234/5678/9abc\x07", 0);
}

test "OSC 10 and 12 queries pass through" {
    // Only the background query is stripped; foreground/cursor are left
    // for the real terminal to answer as before.
    var f: Filter = .{};
    try testFeed(&f, "\x1b]10;?\x07\x1b]12;?\x07", "\x1b]10;?\x07\x1b]12;?\x07", 0);
}

test "other OSC sequences pass through" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b]2;a title\x07text", "\x1b]2;a title\x07text", 0);
}

test "back-to-back queries are both removed" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b]11;?\x07\x1b]11;?\x07x", "x", 2);
}

test "query split across feeds is still removed" {
    var f: Filter = .{};
    try testFeed(&f, "before\x1b]11", "before", 0);
    try testFeed(&f, ";?\x07after", "after", 1);
}

test "ST query split before the backslash is still removed" {
    var f: Filter = .{};
    try testFeed(&f, "x\x1b]11;?\x1b", "x", 0);
    try testFeed(&f, "\\y", "y", 1);
}

test "near-miss prefix is emitted verbatim" {
    var f: Filter = .{};
    // ESC ] 1 1 ; X is not a query; nothing is dropped.
    try testFeed(&f, "\x1b]11;X\x07", "\x1b]11;X\x07", 0);
}

test "lone ESC then ordinary bytes pass through" {
    var f: Filter = .{};
    try testFeed(&f, "\x1bMtext", "\x1bMtext", 0);
}
