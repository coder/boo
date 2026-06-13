//! Microbenchmark for the `boo ui` viewport render hot path.
//!
//! Compares serialization strategies for one repaint frame:
//!   A_full  status quo: a fresh Allocating writer per row, all rows.
//!   B_full  reused buffer, all rows (full-repaint frame, e.g. scroll).
//!   C_local reused buffer, re-serialize one changed row + reuse the
//!           rest from cache (localized-update frame: typing, progress).
//!
//! Build/run: `zig build bench`. Reports ns/frame and the allocation
//! count for A vs B.
const std = @import("std");
const vt = @import("ghostty-vt");

const rows: u16 = 50;
const cols: u16 = 200;
const frames: usize = 2000;

/// Allocator that counts allocations, delegating to a backing one.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    count: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.backing.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(m, a, ra);
    }
};

/// Status-quo serialization: a fresh Allocating writer per row.
fn rowStatusQuo(alloc: std.mem.Allocator, term: *vt.Terminal, y: u16, out: *std.ArrayList(u8)) !void {
    const screen = term.screens.active;
    if (term.cols == 0) return;
    const start = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = y } }) orelse return;
    const end = screen.pages.pin(.{ .viewport = .{ .x = term.cols - 1, .y = y } }) orelse return;
    var formatter: vt.formatter.ScreenFormatter = .init(screen, .vt);
    formatter.content = .{ .selection = vt.Selection.init(start, end, true) };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    aw.writer.print("{f}", .{formatter}) catch return error.OutOfMemory;
    const bytes = aw.writer.buffered();
    try out.appendSlice(alloc, bytes);
    if (std.mem.indexOf(u8, bytes, "\x1b]8;") != null) {
        try out.appendSlice(alloc, "\x1b]8;;\x1b\\");
    }
}

/// Optimized serialization: format directly into the caller's buffer
/// (reused across rows/frames), no per-row allocation.
fn rowReused(alloc: std.mem.Allocator, term: *vt.Terminal, y: u16, out: *std.ArrayList(u8)) !void {
    const screen = term.screens.active;
    if (term.cols == 0) return;
    const start = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = y } }) orelse return;
    const end = screen.pages.pin(.{ .viewport = .{ .x = term.cols - 1, .y = y } }) orelse return;
    var formatter: vt.formatter.ScreenFormatter = .init(screen, .vt);
    formatter.content = .{ .selection = vt.Selection.init(start, end, true) };
    const at = out.items.len;
    {
        var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, out);
        defer out.* = aw.toArrayList();
        aw.writer.print("{f}", .{formatter}) catch return error.OutOfMemory;
    }
    if (std.mem.indexOf(u8, out.items[at..], "\x1b]8;") != null) {
        try out.appendSlice(alloc, "\x1b]8;;\x1b\\");
    }
}

fn fillScreen(alloc: std.mem.Allocator, term: *vt.Terminal) !void {
    var stream = vt.TerminalStream.initAlloc(alloc, vt.TerminalStream.Handler.init(term));
    defer stream.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "\x1b[H");
    for (0..rows) |y| {
        // A mix of default and 256-color SGR segments per row.
        var x: usize = 0;
        while (x < cols - 12) : (x += 12) {
            const color: usize = (y * 7 + x) % 231 + 16;
            try buf.print(alloc, "\x1b[38;5;{d}mword{d:0>2} ", .{ color, (x / 12) % 100 });
        }
        try buf.appendSlice(alloc, "\x1b[0m");
        if (y + 1 < rows) try buf.appendSlice(alloc, "\r\n");
    }
    stream.nextSlice(buf.items);
}

pub fn main() !void {
    // boo runs on the C allocator at runtime (src/main.zig); benchmark
    // with the same one so per-row allocation cost is realistic.
    const base = std.heap.c_allocator;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const out = &stdout_w.interface;

    try out.print("boo ui render bench: {d} rows x {d} cols, {d} frames\n\n", .{ rows, cols, frames });

    // --- A_full: status quo, all rows, per-row Allocating ---
    {
        var ca: CountingAllocator = .{ .backing = base };
        const alloc = ca.allocator();
        var term = try vt.Terminal.init(alloc, .{ .cols = cols, .rows = rows, .max_scrollback = 512 * 1024 });
        defer term.deinit(alloc);
        try fillScreen(alloc, &term);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        const alloc_before = ca.count;
        var timer = try std.time.Timer.start();
        for (0..frames) |_| {
            body.clearRetainingCapacity();
            for (0..rows) |y| try rowStatusQuo(alloc, &term, @intCast(y), &body);
        }
        const ns = timer.read();
        try out.print("A_full   (status quo, all rows): {d:>7} ns/frame, {d:>7} allocs/frame\n", .{
            ns / frames, (ca.count - alloc_before) / frames,
        });
    }

    // --- B_full: reused buffer, all rows ---
    {
        var ca: CountingAllocator = .{ .backing = base };
        const alloc = ca.allocator();
        var term = try vt.Terminal.init(alloc, .{ .cols = cols, .rows = rows, .max_scrollback = 512 * 1024 });
        defer term.deinit(alloc);
        try fillScreen(alloc, &term);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        const alloc_before = ca.count;
        var timer = try std.time.Timer.start();
        for (0..frames) |_| {
            body.clearRetainingCapacity();
            for (0..rows) |y| try rowReused(alloc, &term, @intCast(y), &body);
        }
        const ns = timer.read();
        try out.print("B_full   (reused buf, all rows): {d:>7} ns/frame, {d:>7} allocs/frame\n", .{
            ns / frames, (ca.count - alloc_before) / frames,
        });
    }

    // --- C_local: one changed row re-serialized, rest reused from cache ---
    {
        const alloc = base;
        var term = try vt.Terminal.init(alloc, .{ .cols = cols, .rows = rows, .max_scrollback = 512 * 1024 });
        defer term.deinit(alloc);
        try fillScreen(alloc, &term);

        // Per-row cache buffers, primed once.
        var cache: [rows]std.ArrayList(u8) = undefined;
        for (&cache) |*c| c.* = .empty;
        defer for (&cache) |*c| c.deinit(alloc);
        for (0..rows) |y| try rowReused(alloc, &term, @intCast(y), &cache[y]);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        var timer = try std.time.Timer.start();
        for (0..frames) |i| {
            body.clearRetainingCapacity();
            // One row is "dirty" this frame; re-serialize it, reuse rest.
            const dirty: u16 = @intCast(i % rows);
            for (0..rows) |y| {
                if (y == dirty) {
                    cache[y].clearRetainingCapacity();
                    try rowReused(alloc, &term, @intCast(y), &cache[y]);
                }
                try body.appendSlice(alloc, cache[y].items);
            }
        }
        const ns = timer.read();
        try out.print("C_local  (1 dirty row, rest cached): {d:>7} ns/frame\n", .{ns / frames});
    }

    try out.flush();
}
