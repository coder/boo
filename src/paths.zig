//! Session naming and socket directory resolution.

const std = @import("std");

pub const max_name_len = 64;

pub const NameError = error{InvalidSessionName};

/// Session names become file names, so restrict them to a safe set.
pub fn validateName(name: []const u8) NameError!void {
    if (name.len == 0 or name.len > max_name_len) return error.InvalidSessionName;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return error.InvalidSessionName,
    };
    // Avoid names that look like path traversal or hidden files.
    if (name[0] == '.' or name[0] == '-') return error.InvalidSessionName;
}

/// Resolve the runtime directory that holds session sockets:
/// $BOO_DIR, else $XDG_RUNTIME_DIR/boo, else /tmp/boo-<uid>.
/// The directory is created with mode 0700.
pub fn socketDir(alloc: std.mem.Allocator) ![]u8 {
    const dir = dir: {
        if (std.posix.getenv("BOO_DIR")) |d| {
            if (d.len > 0) break :dir try alloc.dupe(u8, d);
        }
        if (std.posix.getenv("XDG_RUNTIME_DIR")) |d| {
            if (d.len > 0) break :dir try std.fs.path.join(alloc, &.{ d, "boo" });
        }
        break :dir try std.fmt.allocPrint(
            alloc,
            "/tmp/boo-{d}",
            .{std.c.getuid()},
        );
    };
    errdefer alloc.free(dir);

    std.fs.cwd().makePath(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    // Best effort: sockets must not be reachable by other users.
    std.posix.fchmodat(std.posix.AT.FDCWD, dir, 0o700, 0) catch {};

    return dir;
}

pub fn socketPath(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.sock", .{name});
    defer alloc.free(file);
    return std.fs.path.join(alloc, &.{ dir, file });
}

/// Default session name for sessions created without -S: the creating
/// process id, like GNU screen's pid prefix.
pub fn defaultName(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{std.c.getpid()}) catch unreachable;
}

/// Iterate sessions in dir: every "*.sock" file. Returns names without
/// the extension; caller frees each name and the list.
pub fn listSessions(alloc: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names.toOwnedSlice(alloc),
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
        const name = entry.name[0 .. entry.name.len - ".sock".len];
        validateName(name) catch continue;
        try names.append(alloc, try alloc.dupe(u8, name));
    }

    return names.toOwnedSlice(alloc);
}

test "validateName" {
    try validateName("work");
    try validateName("a-b_c.d2");
    try std.testing.expectError(error.InvalidSessionName, validateName(""));
    try std.testing.expectError(error.InvalidSessionName, validateName("a/b"));
    try std.testing.expectError(error.InvalidSessionName, validateName(".hidden"));
    try std.testing.expectError(error.InvalidSessionName, validateName("-flag"));
    try std.testing.expectError(error.InvalidSessionName, validateName("a" ** 65));
    try std.testing.expectError(error.InvalidSessionName, validateName("sp ace"));
}

test "socketPath" {
    const alloc = std.testing.allocator;
    const p = try socketPath(alloc, "/run/gs", "work");
    defer alloc.free(p);
    try std.testing.expectEqualStrings("/run/gs/work.sock", p);
}
