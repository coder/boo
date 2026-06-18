//! Resolve a process's current working directory from the operating
//! system, so a session created from `boo ui` can be born where the
//! focused session currently is.
//!
//! This reads the live directory of the session's child process rather
//! than relying on OSC 7 shell integration (which boo does not inject and
//! which can report a remote directory over ssh). The child of a session
//! is a local process, so its cwd is always a valid local path to hand to
//! `chdir`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Write the absolute working directory of `pid` into `buf` and return
/// the slice. Returns null when it cannot be determined: the process is
/// gone, the path does not fit, or the platform is unsupported.
pub fn ofPid(buf: []u8, pid: posix.pid_t) ?[]const u8 {
    // Reference the macOS layout on every target so its comptime size
    // asserts run for all builds, not only when darwinCwd is analyzed.
    // This touches a type only, so it does not pull proc_pidinfo into a
    // non-macOS link.
    comptime {
        _ = darwin.proc_vnodepathinfo;
    }
    return switch (builtin.os.tag) {
        .linux => linuxCwd(buf, pid),
        .macos, .ios, .tvos, .watchos, .visionos => darwinCwd(buf, pid),
        else => null,
    };
}

/// Linux exposes a process's cwd as the `/proc/<pid>/cwd` symlink.
fn linuxCwd(buf: []u8, pid: posix.pid_t) ?[]const u8 {
    var link_buf: [32]u8 = undefined;
    const link = std.fmt.bufPrint(&link_buf, "/proc/{d}/cwd", .{pid}) catch return null;
    const path = posix.readlink(link, buf) catch return null;
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return null;
    return path;
}

/// macOS has no /proc; the kernel reports the current directory through
/// proc_pidinfo's PROC_PIDVNODEPATHINFO flavor.
fn darwinCwd(buf: []u8, pid: posix.pid_t) ?[]const u8 {
    var info: darwin.proc_vnodepathinfo = undefined;
    const size: c_int = @sizeOf(darwin.proc_vnodepathinfo);
    // proc_pidinfo fills the buffer only when its size matches the
    // struct exactly; a short read means failure.
    if (darwin.proc_pidinfo(pid, darwin.PROC_PIDVNODEPATHINFO, 0, &info, size) != size) {
        return null;
    }
    const path = std.mem.sliceTo(&info.pvi_cdir.vip_path, 0);
    if (path.len == 0 or path.len > buf.len or !std.fs.path.isAbsolute(path)) return null;
    @memcpy(buf[0..path.len], path);
    return buf[0..path.len];
}

/// Minimal mirror of the `<sys/proc_info.h>` layout that proc_pidinfo
/// fills. Only `pvi_cdir.vip_path` is read, but the kernel rejects any
/// buffer whose size differs from `struct proc_vnodepathinfo`, so the
/// whole layout is reproduced and its size locked at comptime.
const darwin = struct {
    const PROC_PIDVNODEPATHINFO: c_int = 9;
    const MAXPATHLEN = 1024;

    const vinfo_stat = extern struct {
        vst_dev: u32,
        vst_mode: u16,
        vst_nlink: u16,
        vst_ino: u64,
        vst_uid: u32,
        vst_gid: u32,
        vst_atime: i64,
        vst_atimensec: i64,
        vst_mtime: i64,
        vst_mtimensec: i64,
        vst_ctime: i64,
        vst_ctimensec: i64,
        vst_birthtime: i64,
        vst_birthtimensec: i64,
        vst_size: i64,
        vst_blocks: i64,
        vst_blksize: i32,
        vst_flags: u32,
        vst_gen: u32,
        vst_rdev: u32,
        vst_qspare: [2]i64,
    };
    const fsid_t = extern struct { val: [2]i32 };
    const vnode_info = extern struct {
        vi_stat: vinfo_stat,
        vi_type: i32,
        vi_pad: i32,
        vi_fsid: fsid_t,
    };
    const vnode_info_path = extern struct {
        vip_vi: vnode_info,
        vip_path: [MAXPATHLEN]u8,
    };
    const proc_vnodepathinfo = extern struct {
        pvi_cdir: vnode_info_path,
        pvi_rdir: vnode_info_path,
    };

    comptime {
        // Verified against macOS <sys/proc_info.h>; the syscall rejects
        // any other size, so a layout drift must fail the build loudly.
        std.debug.assert(@sizeOf(proc_vnodepathinfo) == 2352);
        std.debug.assert(@offsetOf(proc_vnodepathinfo, "pvi_cdir") +
            @offsetOf(vnode_info_path, "vip_path") == 152);
    }

    extern "c" fn proc_pidinfo(
        pid: c_int,
        flavor: c_int,
        arg: u64,
        buffer: ?*anyopaque,
        buffersize: c_int,
    ) c_int;
};

test "ofPid reports a child's working directory" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    // A child that simply parks in `dir` so its cwd can be inspected
    // while it is alive.
    var child = std.process.Child.init(&.{ "sleep", "30" }, alloc);
    child.cwd = dir;
    try child.spawn();
    defer _ = child.kill() catch {};

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // Child.spawn returns once the child is forked, which can be before
    // it has chdir'd and exec'd, so the cwd is briefly the inherited
    // one. Poll until it settles on `dir` (or give up).
    var matched = false;
    var tries: usize = 0;
    while (tries < 300) : (tries += 1) {
        if (ofPid(&buf, child.id)) |p| {
            if (std.mem.eql(u8, p, dir)) {
                matched = true;
                break;
            }
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(matched);
}
