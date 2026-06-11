//! Length-prefixed message framing for the client/daemon Unix socket.
//!
//! Wire format, little endian:
//!
//!   | type: u8 | payload_len: u32 | payload: [payload_len]u8 |
//!
//! Payloads are opaque bytes; structured payloads (sizes, command argv)
//! are encoded by the helpers below.

const std = @import("std");

/// Maximum payload size. Anything larger is a protocol error; this bounds
/// memory used by a malicious or corrupt peer.
pub const max_payload = 1 << 20;

pub const header_len = 5;

pub const MsgType = enum(u8) {
    // Client to daemon.
    attach = 1,
    input = 2,
    resize = 3,
    detach_req = 4,
    command = 5,

    // Daemon to client.
    output = 64,
    detached = 65,
    exit = 66,
    ok = 67,
    err = 68,
    /// Which screen the application is on ("alt" or "primary"),
    /// sent alongside every repaint. The passthrough strips screen
    /// toggles, so clients cannot tell on their own; the ui uses it
    /// to decide what a wheel over the viewport should do.
    screen = 69,
    _,
};

pub const Msg = struct {
    type: MsgType,
    payload: []const u8,
};

/// 2x u16 little endian: rows, cols. Used by attach and resize.
pub const SizePayload = struct {
    rows: u16,
    cols: u16,

    pub fn encode(self: SizePayload) [4]u8 {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], self.rows, .little);
        std.mem.writeInt(u16, buf[2..4], self.cols, .little);
        return buf;
    }

    pub fn decode(payload: []const u8) error{InvalidPayload}!SizePayload {
        if (payload.len != 4) return error.InvalidPayload;
        return .{
            .rows = std.mem.readInt(u16, payload[0..2], .little),
            .cols = std.mem.readInt(u16, payload[2..4], .little),
        };
    }
};

/// Write a full frame to a fd. Handles short writes.
pub fn writeMsg(fd: std.posix.fd_t, msg_type: MsgType, payload: []const u8) !void {
    std.debug.assert(payload.len <= max_payload);
    var header: [header_len]u8 = undefined;
    header[0] = @intFromEnum(msg_type);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    try writeAll(fd, &header);
    try writeAll(fd, payload);
}

pub fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) i += try std.posix.write(fd, bytes[i..]);
}

/// Incremental frame decoder. Feed bytes as they arrive from the socket,
/// pop complete messages out with next(). Payloads returned by next() are
/// valid until the following call to feed() or next().
pub const Decoder = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    consumed: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Decoder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Decoder) void {
        self.buf.deinit(self.alloc);
    }

    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        self.compact();
        try self.buf.appendSlice(self.alloc, bytes);
    }

    /// Returns the next complete message, or null if more bytes are needed.
    pub fn next(self: *Decoder) error{PayloadTooLarge}!?Msg {
        self.compact();
        const items = self.buf.items;
        if (items.len < header_len) return null;

        const len = std.mem.readInt(u32, items[1..5], .little);
        if (len > max_payload) return error.PayloadTooLarge;
        const total = header_len + @as(usize, len);
        if (items.len < total) return null;

        self.consumed = total;
        return .{
            .type = @enumFromInt(items[0]),
            .payload = items[header_len..total],
        };
    }

    fn compact(self: *Decoder) void {
        if (self.consumed == 0) return;
        self.buf.replaceRangeAssumeCapacity(0, self.consumed, &.{});
        self.consumed = 0;
    }
};

/// Encode argv as a NUL separated string for command payloads.
pub fn encodeArgv(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (argv, 0..) |arg, i| {
        if (i > 0) try out.append(alloc, 0);
        try out.appendSlice(alloc, arg);
    }
    return out.toOwnedSlice(alloc);
}

/// Decode a NUL separated argv. Caller frees the returned slice (the
/// strings point into payload).
pub fn decodeArgv(alloc: std.mem.Allocator, payload: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);
    var it = std.mem.splitScalar(u8, payload, 0);
    while (it.next()) |part| try list.append(alloc, part);
    return list.toOwnedSlice(alloc);
}

test "size payload roundtrip" {
    const size: SizePayload = .{ .rows = 51, .cols = 213 };
    const enc = size.encode();
    const dec = try SizePayload.decode(&enc);
    try std.testing.expectEqual(size, dec);
    try std.testing.expectError(error.InvalidPayload, SizePayload.decode("abc"));
}

test "argv roundtrip" {
    const alloc = std.testing.allocator;
    const argv = [_][]const u8{ "stuff", "hello world\n" };
    const enc = try encodeArgv(alloc, &argv);
    defer alloc.free(enc);
    const dec = try decodeArgv(alloc, enc);
    defer alloc.free(dec);
    try std.testing.expectEqual(@as(usize, 2), dec.len);
    try std.testing.expectEqualStrings("stuff", dec[0]);
    try std.testing.expectEqualStrings("hello world\n", dec[1]);
}

test "decoder handles fragmented and coalesced frames" {
    const alloc = std.testing.allocator;
    var dec: Decoder = .init(alloc);
    defer dec.deinit();

    // Build two frames back to back.
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(alloc);
    const payload1 = "hello";
    const payload2 = "";
    try frame.append(alloc, @intFromEnum(MsgType.output));
    try frame.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, payload1.len)));
    try frame.appendSlice(alloc, payload1);
    try frame.append(alloc, @intFromEnum(MsgType.detach_req));
    try frame.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, payload2.len)));

    // Feed a single byte at a time; messages appear exactly when complete.
    var seen: usize = 0;
    for (frame.items) |byte| {
        try dec.feed(&.{byte});
        while (try dec.next()) |msg| {
            switch (seen) {
                0 => {
                    try std.testing.expectEqual(MsgType.output, msg.type);
                    try std.testing.expectEqualStrings(payload1, msg.payload);
                },
                1 => {
                    try std.testing.expectEqual(MsgType.detach_req, msg.type);
                    try std.testing.expectEqual(@as(usize, 0), msg.payload.len);
                },
                else => return error.TestUnexpectedResult,
            }
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "decoder rejects oversized payloads" {
    const alloc = std.testing.allocator;
    var dec: Decoder = .init(alloc);
    defer dec.deinit();

    var header: [header_len]u8 = undefined;
    header[0] = @intFromEnum(MsgType.input);
    std.mem.writeInt(u32, header[1..5], max_payload + 1, .little);
    try dec.feed(&header);
    try std.testing.expectError(error.PayloadTooLarge, dec.next());
}
