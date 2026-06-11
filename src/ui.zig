//! boo ui: a full-screen session manager. Sessions are listed in a
//! left sidebar; the focused session renders in a viewport on the
//! right. Sessions can be created, focused, and killed with the mouse
//! or with C-a key bindings.
//!
//! Unlike `boo attach`, session output is never passed through to the
//! terminal raw: absolute cursor addressing, scrolling, and clears
//! from the session would trample the sidebar. Instead the UI is a
//! client-side compositor. Output of the focused session feeds a
//! local libghostty terminal sized to the viewport, and the UI
//! repaints changed viewport rows (offset by the sidebar width) from
//! that terminal state, the same way the daemon rehydrates a plain
//! attach from its own terminal state.
//!
//! The local terminal also stands in for a real terminal in both
//! directions: it answers terminal queries (DSR, DA, ...) by sending
//! the reply back to the session as input, and its mode state decides
//! whether mouse, focus, and bracketed-paste events are forwarded to
//! the application (with mouse coordinates translated into viewport
//! space).

const std = @import("std");
const posix = std.posix;
const vt = @import("ghostty-vt");

const client = @import("client.zig");
const keys = @import("keys.zig");
const paths = @import("paths.zig");
const protocol = @import("protocol.zig");
const ptypkg = @import("pty.zig");
const windowpkg = @import("window.zig");

const log = std.log.scoped(.ui);

/// Refresh cadence for the sidebar's session list.
const refresh_interval_ms: i64 = 1000;
/// Transient status messages stay visible this long.
const message_ttl_ms: i64 = 4000;
/// Render coalescing: at most one repaint per interval while output
/// is streaming.
const render_interval_ms: i64 = 15;
/// A lone ESC held by the input parser is delivered as session input
/// after this long without a follow-up byte. Escape sequences arrive
/// as one chunk, so only a human pressing the ESC key waits this long.
const esc_flush_ms: i64 = 50;
/// Rows per mouse wheel tick, both for paging local scrollback and
/// for the arrow keys sent to alternate-screen applications.
const wheel_lines = 3;

// -- Layout -----------------------------------------------------------------

/// Screen geometry: a sidebar on the left, a one-column separator,
/// and the session viewport filling the rest of every row, including
/// the last. The bottom sidebar row shows the keybind hint; transient
/// status content (prompts, the keybind list, messages) overlays the
/// last row full-width and the row repaints from session state when
/// it clears. The viewport always reaches the right edge, so
/// erase-to-end-of-line stays inside it.
pub const Layout = struct {
    rows: u16,
    cols: u16,
    /// Sidebar text columns, excluding the separator column.
    sidebar_w: u16,

    /// Each session occupies two sidebar rows: name and title.
    pub const entry_rows: u16 = 2;

    /// Sidebar rows above the session list: the new-session button
    /// and a separating blank row.
    pub const list_top: u16 = 2;

    pub fn init(rows: u16, cols: u16) Layout {
        // Narrow terminals get a proportionally smaller sidebar; the
        // viewport keeps at least a sliver so the focused session
        // stays usable.
        const sw: u16 = if (cols >= 72) 24 else @max(8, cols / 3);
        return .{ .rows = rows, .cols = cols, .sidebar_w = sw };
    }

    pub fn viewportCols(self: Layout) u16 {
        return self.cols -| (self.sidebar_w + 1);
    }

    /// Viewport rows: the full terminal height. The status overlay
    /// borrows the last row only while it has something to show.
    pub fn viewportRows(self: Layout) u16 {
        return self.rows;
    }

    /// First viewport column, 0-based.
    pub fn viewportX(self: Layout) u16 {
        return self.sidebar_w + 1;
    }

    /// Sidebar rows available for session entries between the
    /// new-session button (plus its gap row) and the keybind hint
    /// on the bottom row.
    pub fn listRows(self: Layout) u16 {
        return self.rows -| (list_top + 1);
    }

    /// Whole session entries that fit in the list area.
    pub fn visibleEntries(self: Layout) usize {
        return @max(1, self.listRows() / entry_rows);
    }

    pub const Hit = union(enum) {
        /// Display row within the visible session list (entry_rows
        /// rows per session; scroll applied by the caller).
        session: struct { row: u16, kill: bool },
        new_button,
        viewport: struct { x: u16, y: u16 },
        none,
    };

    /// Map a 0-based screen coordinate to a UI region. Session rows
    /// report whether the kill target ('x' in the last column) was hit.
    pub fn hit(self: Layout, x: u16, y: u16) Hit {
        if (y >= self.rows or x >= self.cols) return .none;
        if (x >= self.viewportX()) {
            return .{ .viewport = .{ .x = x - self.viewportX(), .y = y } };
        }
        if (x >= self.sidebar_w) return .none; // separator column
        if (y == self.rows -| 1) return .none; // keybind hint row
        if (y == 0) return .new_button;
        if (y < list_top) return .none; // gap under the button
        return .{ .session = .{
            .row = y - list_top,
            .kill = self.sidebar_w >= 12 and x == self.sidebar_w - 2,
        } };
    }
};

// -- Input parsing ----------------------------------------------------------

/// A mouse report from the terminal (SGR 1006 encoding).
pub const Mouse = struct {
    /// Raw SGR button code: low bits select the button, bit 2..4 are
    /// modifiers, bit 5 marks motion, bit 6 marks wheel buttons.
    code: u16,
    /// 1-based terminal column.
    x: u16,
    /// 1-based terminal row.
    y: u16,
    release: bool,

    pub fn isWheel(self: Mouse) bool {
        return self.code & 64 != 0;
    }

    pub fn isMotion(self: Mouse) bool {
        return self.code & 32 != 0;
    }
};

pub const InputEvent = union(enum) {
    /// Bytes destined for the focused session.
    forward: []const u8,
    /// Command key following the C-a prefix.
    prefix: u8,
    /// Plain arrow key (ESC [ A/B/C/D). `prefixed` marks an arrow
    /// that followed the C-a prefix.
    arrow: Arrow,
    mouse: Mouse,
    /// Bracketed paste begin (true) / end (false).
    paste: bool,
    /// Focus in (true) / out (false).
    focus: bool,

    pub const Arrow = struct {
        dir: Dir,
        prefixed: bool,

        pub const Dir = enum { up, down, left, right };
    };
};

/// Splits raw terminal input into session bytes and UI events: the
/// C-a prefix, SGR mouse reports, focus reports, and bracketed paste
/// markers. Everything else passes through untouched. While a paste
/// is open the prefix byte is NOT special, so pasted 0x01 bytes reach
/// the application (unlike a plain attach).
pub const InputParser = struct {
    /// A C-a was seen; the next byte is a command key.
    pending_prefix: bool = false,
    /// Held bytes of a possible CSI sequence that may need to be
    /// intercepted (arrows and mouse/focus/paste reports). Replayed
    /// verbatim the moment the sequence diverges.
    held: [hold_max]u8 = undefined,
    held_len: u8 = 0,
    /// The held sequence followed an armed prefix: an arrow binds to
    /// it (C-a Up/Down), anything else cancels the prefix as before.
    prefix_held: bool = false,
    in_paste: bool = false,

    const hold_max = 40;

    pub fn feed(self: *InputParser, input: []const u8, handler: anytype) !void {
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
                    if (isCsiFinal(byte)) try self.finishCsi(handler);
                    if (self.held_len == hold_max) try self.flushHeld(handler);
                } else {
                    try self.flushHeld(handler);
                }
                continue;
            }

            if (self.pending_prefix) {
                self.pending_prefix = false;
                if (byte == 0x1b) {
                    // Esc backs out of the armed prefix. A lone Esc
                    // is the cancel key and is consumed; when more
                    // bytes follow immediately it starts a key or
                    // mouse sequence, which must be reprocessed so
                    // its tail is not typed into the application. An
                    // arrow sequence binds back to the prefix
                    // (C-a Up/Down) via prefix_held.
                    if (i + 1 == input.len) {
                        i += 1;
                    } else {
                        self.prefix_held = true;
                    }
                    start = i;
                    continue;
                }
                i += 1;
                start = i;
                try handler.event(.{ .prefix = byte });
                continue;
            }

            if (byte == 0x1b) {
                if (i > start) try handler.event(.{ .forward = input[start..i] });
                self.held[0] = byte;
                self.held_len = 1;
                i += 1;
                start = i;
                continue;
            }

            if (byte == keys.escape_byte and !self.in_paste) {
                if (i > start) try handler.event(.{ .forward = input[start..i] });
                self.pending_prefix = true;
                i += 1;
                start = i;
                continue;
            }

            i += 1;
        }

        if (i > start) try handler.event(.{ .forward = input[start..i] });
    }

    /// Whether `byte` keeps the held bytes a candidate for a sequence
    /// this parser intercepts: plain arrows (ESC [ A/B/C/D), CSI
    /// mouse (ESC [ < ... M/m), focus (ESC [ I, ESC [ O), or paste
    /// markers (ESC [ 200~, ESC [ 201~).
    fn heldAccepts(self: *const InputParser, byte: u8) bool {
        const len = self.held_len;
        if (len == 1) return byte == '[';
        if (len == 2) return switch (byte) {
            '<', 'I', 'O', '2', 'A', 'B', 'C', 'D' => true,
            else => false,
        };
        return switch (self.held[2]) {
            '<' => switch (byte) {
                '0'...'9', ';', 'M', 'm' => true,
                else => false,
            },
            '2' => switch (byte) {
                '0'...'9', '~' => true,
                else => false,
            },
            else => false,
        };
    }

    fn isCsiFinal(byte: u8) bool {
        return switch (byte) {
            'M', 'm', '~', 'I', 'O', 'A', 'B', 'C', 'D' => true,
            else => false,
        };
    }

    fn finishCsi(self: *InputParser, handler: anytype) !void {
        const seq = self.held[0..self.held_len];
        const body = seq[2 .. seq.len - 1];
        const final = seq[seq.len - 1];
        const prefixed = self.prefix_held;
        self.prefix_held = false;

        // Plain arrows. heldAccepts admits the final only directly
        // after the bracket, so the body is always empty; modified
        // arrows (ESC [ 1;5 A) diverge earlier and are replayed.
        switch (final) {
            'A', 'B', 'C', 'D' => {
                self.held_len = 0;
                return handler.event(.{ .arrow = .{
                    .dir = switch (final) {
                        'A' => .up,
                        'B' => .down,
                        'C' => .right,
                        else => .left,
                    },
                    .prefixed = prefixed,
                } });
            },
            else => {},
        }

        // Focus reports arrive as a bare final byte.
        if (final == 'I' or final == 'O') {
            if (body.len != 0) return self.flushHeld(handler);
            self.held_len = 0;
            return handler.event(.{ .focus = final == 'I' });
        }

        if (final == '~') {
            if (std.mem.eql(u8, body, "200")) {
                self.held_len = 0;
                self.in_paste = true;
                return handler.event(.{ .paste = true });
            }
            if (std.mem.eql(u8, body, "201")) {
                self.held_len = 0;
                self.in_paste = false;
                return handler.event(.{ .paste = false });
            }
            return self.flushHeld(handler);
        }

        // SGR mouse: ESC [ < code ; x ; y (M|m).
        if (body.len == 0 or body[0] != '<') return self.flushHeld(handler);
        var it = std.mem.splitScalar(u8, body[1..], ';');
        const code = parseField(it.next()) orelse return self.flushHeld(handler);
        const x = parseField(it.next()) orelse return self.flushHeld(handler);
        const y = parseField(it.next()) orelse return self.flushHeld(handler);
        if (it.next() != null) return self.flushHeld(handler);
        self.held_len = 0;
        return handler.event(.{ .mouse = .{
            .code = code,
            .x = x,
            .y = y,
            .release = final == 'm',
        } });
    }

    fn parseField(field: ?[]const u8) ?u16 {
        const text = field orelse return null;
        return std.fmt.parseInt(u16, text, 10) catch null;
    }

    /// Replay held bytes as session input: the sequence is some other
    /// key encoding (function keys, modified arrows, ...) that belongs
    /// to the application.
    fn flushHeld(self: *InputParser, handler: anytype) !void {
        const held = self.held[0..self.held_len];
        self.held_len = 0;
        self.prefix_held = false;
        if (held.len > 0) try handler.event(.{ .forward = held });
    }
};

// -- Focused session view ----------------------------------------------------

/// The attach connection and local terminal state of the focused
/// session. Heap-allocated and pinned: the stream handler keeps a
/// pointer to `term`, and effects callbacks recover the View with
/// @fieldParentPtr (the same shape as window.Window).
pub const View = struct {
    alloc: std.mem.Allocator,
    sock: posix.fd_t,
    decoder: protocol.Decoder,
    term: vt.Terminal,
    stream: Stream,
    state: State = .live,
    /// The application set the window title; the sidebar refresh
    /// picks it up.
    title_changed: bool = false,
    /// The application rang the bell; the UI forwards it.
    bell: bool = false,
    /// The application is on the alternate screen, per the daemon's
    /// `.screen` messages. Decides whether a wheel over the viewport
    /// pages local scrollback or sends arrow keys.
    app_alt: bool = false,

    pub const State = enum { live, ended, stolen, lost };
    pub const Stream = vt.TerminalStream;

    pub fn create(
        alloc: std.mem.Allocator,
        socket_path: []const u8,
        rows: u16,
        cols: u16,
    ) !*View {
        const self = try alloc.create(View);
        errdefer alloc.destroy(self);

        const sock = try client.connect(alloc, socket_path);
        errdefer posix.close(sock);

        self.* = .{
            .alloc = alloc,
            .sock = sock,
            .decoder = .init(alloc),
            .term = undefined,
            .stream = undefined,
        };
        errdefer self.decoder.deinit();

        self.term = try vt.Terminal.init(alloc, .{
            .cols = @max(cols, 1),
            .rows = @max(rows, 1),
            // Output that scrolls off while attached accumulates
            // here; the wheel pages through it for primary-screen
            // applications.
            .max_scrollback = 512 * 1024,
        });
        errdefer self.term.deinit(alloc);

        var handler: Stream.Handler = .init(&self.term);
        handler.effects = .{
            .write_pty = effectWritePty,
            .bell = effectBell,
            .color_scheme = null,
            .device_attributes = effectDeviceAttributes,
            .enquiry = null,
            .size = effectSize,
            .title_changed = effectTitleChanged,
            .pwd_changed = null,
            .xtversion = effectXtversion,
        };
        self.stream = .initAlloc(alloc, handler);
        errdefer self.stream.deinit();

        try protocol.writeMsg(sock, .attach, &(protocol.SizePayload{
            .rows = @max(rows, 1),
            .cols = @max(cols, 1),
        }).encode());

        return self;
    }

    pub fn destroy(self: *View) void {
        // Ask for an orderly detach; the daemon also detaches on EOF
        // if the request is lost.
        if (self.state == .live) {
            protocol.writeMsg(self.sock, .detach_req, "") catch {};
        }
        posix.close(self.sock);
        self.stream.deinit();
        self.term.deinit(self.alloc);
        self.decoder.deinit();
        self.alloc.destroy(self);
    }

    fn fromHandler(handler: *Stream.Handler) *View {
        const stream: *Stream = @alignCast(@fieldParentPtr("handler", handler));
        return @alignCast(@fieldParentPtr("stream", stream));
    }

    /// Query replies (DSR, DA, OSC color queries, ...) generated by
    /// the local terminal go back to the session as input, exactly as
    /// a real terminal would answer them.
    fn effectWritePty(handler: *Stream.Handler, data: [:0]const u8) void {
        const self = fromHandler(handler);
        self.sendInput(data) catch |err| {
            log.warn("query reply failed: {}", .{err});
        };
    }

    fn effectBell(handler: *Stream.Handler) void {
        fromHandler(handler).bell = true;
    }

    const DeviceAttributes = EffectReturn("device_attributes");

    fn EffectReturn(comptime field_name: []const u8) type {
        const Effects = Stream.Handler.Effects;
        const field = std.meta.fieldInfo(
            Effects,
            @field(std.meta.FieldEnum(Effects), field_name),
        );
        const Fn = @typeInfo(field.type).optional.child;
        return @typeInfo(@typeInfo(Fn).pointer.child).@"fn".return_type.?;
    }

    fn effectDeviceAttributes(handler: *Stream.Handler) DeviceAttributes {
        _ = handler;
        return .{};
    }

    fn effectSize(handler: *Stream.Handler) ?vt.size_report.Size {
        const self = fromHandler(handler);
        return .{
            .rows = self.term.rows,
            .columns = self.term.cols,
            .cell_width = cell_px_w,
            .cell_height = cell_px_h,
        };
    }

    fn effectTitleChanged(handler: *Stream.Handler) void {
        fromHandler(handler).title_changed = true;
    }

    fn effectXtversion(handler: *Stream.Handler) []const u8 {
        _ = handler;
        return "boo " ++ @import("main.zig").version;
    }

    pub fn feedOutput(self: *View, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    pub fn sendInput(self: *View, bytes: []const u8) !void {
        if (self.state != .live) return;
        try protocol.writeMsg(self.sock, .input, bytes);
    }

    pub fn resize(self: *View, rows: u16, cols: u16) !void {
        try self.term.resize(self.alloc, @max(cols, 1), @max(rows, 1));
        if (self.state != .live) return;
        try protocol.writeMsg(self.sock, .resize, &(protocol.SizePayload{
            .rows = @max(rows, 1),
            .cols = @max(cols, 1),
        }).encode());
    }
};

// Nominal cell metrics reported to applications that ask for pixel
// sizes (XTWINOPS, kitty); the same values the daemon reports.
const cell_px_w = 8;
const cell_px_h = 16;

// -- Session list -------------------------------------------------------------

pub const Entry = struct {
    /// Owned by the list.
    name: []u8,
    attached: bool,
    idle_ms: i64,
    /// Owned by the list; sanitized to printable ASCII.
    title: []u8,
};

fn freeEntries(alloc: std.mem.Allocator, entries: *std.ArrayList(Entry)) void {
    for (entries.items) |entry| {
        alloc.free(entry.name);
        alloc.free(entry.title);
    }
    entries.deinit(alloc);
}

// -- Sidebar rendering --------------------------------------------------------

const sgr_reset = "\x1b[0m";
const style_selected = "\x1b[7m";
const style_dim = "\x1b[2m";

/// Append `text` clipped to `width` columns, then pad with spaces to
/// exactly `width`. Only printable ASCII reaches the writer, so byte
/// count equals column count.
fn appendClipped(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    width: usize,
) !void {
    var used: usize = 0;
    for (text) |byte| {
        if (used >= width) break;
        try out.append(alloc, if (byte >= 0x20 and byte < 0x7f) byte else '?');
        used += 1;
    }
    while (used < width) : (used += 1) try out.append(alloc, ' ');
}

/// One sidebar session name row: attached marker, name, and a kill
/// target in the last column. Exactly `width` display columns plus
/// SGR codes; the inverse-video highlight alone marks the selected
/// session.
pub fn appendSessionRow(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    entry: Entry,
    width: u16,
    selected: bool,
) !void {
    if (width == 0) return;
    if (selected) try out.appendSlice(alloc, style_selected);

    // '*': attached by another client. The selected session is
    // attached by this UI itself, which is not worth a marker.
    const marker: u8 = if (!selected and entry.attached) '*' else ' ';
    try out.append(alloc, marker);

    if (width >= 12) {
        // "<m><name...> x ": kill target in the last columns.
        const name_w = width - 1 - 3;
        try appendClipped(alloc, out, entry.name, name_w);
        try out.appendSlice(alloc, " x ");
    } else {
        try appendClipped(alloc, out, entry.name, width - 1);
    }
    try out.appendSlice(alloc, sgr_reset);
}

/// The second sidebar row of a session entry: the window title, dim,
/// indented under the name. Blank when the session has no title.
pub fn appendSessionTitleRow(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    entry: Entry,
    width: u16,
    selected: bool,
) !void {
    if (width == 0) return;
    if (selected) try out.appendSlice(alloc, style_selected);
    try out.appendSlice(alloc, style_dim);

    if (entry.title.len > 0 and width > 2) {
        try out.appendSlice(alloc, "  ");
        try appendClipped(alloc, out, entry.title, width - 2);
    } else {
        try appendClipped(alloc, out, "", width);
    }
    try out.appendSlice(alloc, sgr_reset);
}

// -- The UI -------------------------------------------------------------------

var signal_pipe: posix.fd_t = -1;

fn handleSignal(sig: c_int) callconv(.c) void {
    if (signal_pipe >= 0) {
        const byte: [1]u8 = .{@intCast(sig & 0xff)};
        _ = posix.write(signal_pipe, &byte) catch {};
    }
}

const enter_sequence =
    "\x1b[?1049h" ++ // alternate screen, saving the cursor
    "\x1b[?1002h\x1b[?1006h" ++ // mouse: button events, SGR encoding
    "\x1b[?1004h" ++ // focus reporting
    "\x1b[?2004h" ++ // bracketed paste
    "\x1b]2;boo ui\x07"; // window title

/// reset_state_sequence turns every mode above back off.
const restore_sequence = windowpkg.reset_state_sequence ++ "\x1b[?1049l";

pub fn run(alloc: std.mem.Allocator, dir: []const u8) !void {
    const tty: posix.fd_t = 0;
    if (!posix.isatty(tty)) return error.NotATty;

    var ui: Ui = .{ .alloc = alloc, .dir = dir, .tty = tty };
    defer ui.deinit();

    // Signal plumbing mirrors client.attach: WINCH relayouts,
    // TERM/HUP quit cleanly.
    const pipe_fds = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);
    signal_pipe = pipe_fds[1];
    defer signal_pipe = -1;
    const sigact: posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sigact, null);
    posix.sigaction(posix.SIG.TERM, &sigact, null);
    posix.sigaction(posix.SIG.HUP, &sigact, null);
    posix.sigaction(posix.SIG.PIPE, &.{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    const saved = try posix.tcgetattr(tty);
    var raw = saved;
    client.rawMode(&raw);
    try posix.tcsetattr(tty, .FLUSH, raw);
    defer posix.tcsetattr(tty, .FLUSH, saved) catch {};
    try protocol.writeAll(1, enter_sequence);
    defer protocol.writeAll(1, restore_sequence) catch {};

    const ws = ptypkg.getSize(tty) catch ptypkg.makeWinsize(24, 80);
    ui.layout = .init(ws.row, ws.col);
    // Running inside a boo session: never attach the session hosting
    // this UI, or its output would feed back into itself forever.
    ui.host_name = posix.getenv("BOO");

    try ui.refreshSessions();
    if (ui.selected == null) ui.selectInitial();

    try ui.loop(pipe_fds[0]);
}

const Ui = struct {
    alloc: std.mem.Allocator,
    dir: []const u8,
    tty: posix.fd_t,

    layout: Layout = .{ .rows = 24, .cols = 80, .sidebar_w = 24 },
    sessions: std.ArrayList(Entry) = .empty,
    /// Selected (and focused) session index, when any session exists.
    selected: ?usize = null,
    /// The session this UI itself runs inside, when nested in boo.
    host_name: ?[]const u8 = null,
    /// Name of the previously focused session for C-a C-a toggling.
    last_name: ?[]u8 = null,
    /// Session name the current view is attached to; outlives a
    /// transient disappearance from the listing, unlike `selected`.
    view_name: ?[]u8 = null,
    /// First visible session row when the list overflows.
    scroll: usize = 0,
    view: ?*View = null,

    parser: InputParser = .{},
    /// When nonzero, the parser holds a lone ESC that is flushed as
    /// input once this deadline passes without follow-up bytes.
    esc_deadline: i64 = 0,
    /// Pending kill confirmation: index into sessions.
    confirm_kill: ?usize = null,
    /// Rename input buffer; non-null while the rename prompt is open.
    rename_input: ?std.ArrayList(u8) = null,
    /// Session index being renamed while the prompt is open.
    rename_target: usize = 0,
    /// Search input buffer; non-null while the search prompt is open.
    search_input: ?std.ArrayList(u8) = null,
    /// Selection to restore when the search prompt is cancelled.
    search_origin: ?usize = null,
    /// Sidebar browse: armed by C-a Up/Down (or plain arrows when
    /// nothing live is focused). The selection moves without
    /// attaching; Enter attaches it, Esc snaps it back to the
    /// focused session.
    browsing: bool = false,
    /// Sidebar resize: armed by C-a Left/Right. Arrows adjust the
    /// width live; Enter keeps it, Esc restores the original.
    resizing: bool = false,
    /// Width to restore when the resize is cancelled.
    resize_origin: u16 = 0,
    /// Width kept by a completed resize, reapplied (clamped) when
    /// the terminal itself resizes. Null until the first resize.
    sidebar_pref: ?u16 = null,
    /// Transient status message and its expiry time.
    message: std.ArrayList(u8) = .empty,
    message_deadline: i64 = 0,

    /// Per-screen-row cache of the last emitted bytes; rows that did
    /// not change are not re-sent.
    row_cache: std.ArrayList(std.ArrayList(u8)) = .empty,
    need_render: bool = true,
    /// Force every row out on the next render (resize, C-a l).
    full_render: bool = true,
    last_render_ms: i64 = 0,
    next_refresh_ms: i64 = 0,

    /// Mouse forwarding state for the focused application.
    mouse_pressed: bool = false,
    mouse_last_cell: ?vt.Coordinate = null,

    /// Viewport text selection in viewport cell coordinates, used
    /// when the focused application has not requested mouse
    /// reporting. Anchor is where the drag started; head follows the
    /// pointer. Both ends are inclusive.
    select_anchor: ?CellPos = null,
    select_head: CellPos = .{ .x = 0, .y = 0 },

    /// Incremented on every attach; detects view switches that happen
    /// between poll() and the socket read.
    view_gen: u64 = 0,

    quitting: bool = false,

    const CellPos = struct { x: u16, y: u16 };

    fn deinit(self: *Ui) void {
        if (self.view) |v| v.destroy();
        freeEntries(self.alloc, &self.sessions);
        if (self.last_name) |n| self.alloc.free(n);
        if (self.view_name) |n| self.alloc.free(n);
        if (self.rename_input) |*input| input.deinit(self.alloc);
        if (self.search_input) |*input| input.deinit(self.alloc);
        self.message.deinit(self.alloc);
        for (self.row_cache.items) |*row| row.deinit(self.alloc);
        self.row_cache.deinit(self.alloc);
    }

    // -- Main loop ---------------------------------------------------------

    fn loop(self: *Ui, sig_read: posix.fd_t) !void {
        var buf: [32 * 1024]u8 = undefined;

        while (!self.quitting) {
            try self.renderIfNeeded();

            var fds = [_]posix.pollfd{
                .{ .fd = self.tty, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = sig_read, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 },
            };
            // Only a live view's socket is polled: a dead one stays
            // readable (EOF) forever and would spin the loop.
            if (self.liveView()) |v| fds[2].fd = v.sock;
            const polled_gen = self.view_gen;

            _ = try posix.poll(&fds, self.pollTimeout());

            if (fds[1].revents != 0) self.drainSignals(sig_read, &buf);
            if (self.quitting) break;

            if (fds[0].revents != 0) try self.readTty(&buf);
            if (self.quitting) break;
            try self.flushPendingEsc();

            // Input handling may have switched the focused session;
            // the poll result then describes the old socket, and
            // reading the new (still quiet) one would block the UI.
            if (fds[2].revents != 0 and self.view_gen == polled_gen) {
                try self.readView(&buf);
            }

            const now = std.time.milliTimestamp();
            if (now >= self.next_refresh_ms) {
                self.refreshSessions() catch |err| {
                    log.warn("session refresh failed: {}", .{err});
                };
            }
            if (self.message_deadline != 0 and now >= self.message_deadline) {
                self.message.clearRetainingCapacity();
                self.message_deadline = 0;
                self.need_render = true;
            }
            if (self.view) |v| {
                if (v.bell) {
                    v.bell = false;
                    protocol.writeAll(1, "\x07") catch {};
                }
                // Last: refreshSessions can destroy the view, so `v`
                // must not be touched after it runs.
                if (v.title_changed) {
                    v.title_changed = false;
                    self.refreshSessions() catch {};
                }
            }
        }
    }

    fn pollTimeout(self: *Ui) i32 {
        const now = std.time.milliTimestamp();
        var deadline = self.next_refresh_ms;
        if (self.need_render) {
            deadline = @min(deadline, self.last_render_ms + render_interval_ms);
        }
        if (self.message_deadline != 0) {
            deadline = @min(deadline, self.message_deadline);
        }
        if (self.esc_deadline != 0) {
            deadline = @min(deadline, self.esc_deadline);
        }
        return @intCast(std.math.clamp(deadline - now, 0, 1000));
    }

    fn drainSignals(self: *Ui, sig_read: posix.fd_t, buf: []u8) void {
        while (true) {
            const n = posix.read(sig_read, buf) catch 0;
            if (n == 0) break;
            for (buf[0..n]) |sig| switch (sig) {
                posix.SIG.WINCH => self.relayout(),
                else => self.quitting = true,
            };
            if (n < buf.len) break;
        }
    }

    fn relayout(self: *Ui) void {
        const ws = ptypkg.getSize(self.tty) catch return;
        self.layout = .init(ws.row, ws.col);
        if (self.sidebar_pref) |w| {
            self.layout.sidebar_w = self.clampSidebarWidth(w);
        }
        if (self.view) |v| {
            v.resize(self.layout.viewportRows(), self.layout.viewportCols()) catch |err| {
                log.warn("viewport resize failed: {}", .{err});
            };
        }
        // Cell coordinates shift with the layout, so any in-progress
        // selection no longer points at the text the user dragged over.
        self.select_anchor = null;
        self.full_render = true;
        self.need_render = true;
    }

    // -- Terminal input ------------------------------------------------------

    fn readTty(self: *Ui, buf: []u8) !void {
        const n = posix.read(self.tty, buf) catch 0;
        if (n == 0) {
            self.quitting = true;
            return;
        }
        const Handler = struct {
            ui: *Ui,
            pub fn event(h: @This(), ev: InputEvent) !void {
                try h.ui.handleEvent(ev);
            }
        };
        // The status bar shows the keybind list while the prefix is
        // armed, so arming and disarming both need a repaint.
        const was_pending = self.parser.pending_prefix;
        try self.parser.feed(buf[0..n], Handler{ .ui = self });
        if (self.parser.pending_prefix != was_pending) self.need_render = true;
        // A read that ends in a bare ESC is ambiguous: the ESC key,
        // or a split escape sequence. Deliver it on a short timeout
        // instead of waiting for the next keypress.
        self.esc_deadline = if (self.parser.held_len == 1)
            std.time.milliTimestamp() + esc_flush_ms
        else
            0;
    }

    /// Deliver a lone held ESC once the flush deadline passes: the
    /// user pressed the ESC key and no sequence followed.
    fn flushPendingEsc(self: *Ui) !void {
        if (self.esc_deadline == 0) return;
        if (std.time.milliTimestamp() < self.esc_deadline) return;
        self.esc_deadline = 0;
        const Handler = struct {
            ui: *Ui,
            pub fn event(h: @This(), ev: InputEvent) !void {
                try h.ui.handleEvent(ev);
            }
        };
        try self.parser.flushHeld(Handler{ .ui = self });
    }

    fn handleEvent(self: *Ui, ev: InputEvent) !void {
        // An open rename prompt captures keyboard input.
        if (self.rename_input != null) {
            if (self.handleRenameEvent(ev)) return;
        }

        // An open search prompt captures keyboard input.
        if (self.search_input != null) {
            if (self.handleSearchEvent(ev)) return;
        }

        // A pending kill confirmation swallows the next key.
        if (self.confirm_kill) |idx| {
            switch (ev) {
                .forward => |bytes| {
                    self.confirm_kill = null;
                    if (bytes.len > 0 and (bytes[0] == 'y' or bytes[0] == 'Y')) {
                        self.killSession(idx);
                    } else {
                        self.setMessage("kill cancelled", .{});
                    }
                    return;
                },
                .prefix, .arrow => {
                    self.confirm_kill = null;
                    self.setMessage("kill cancelled", .{});
                    return;
                },
                else => {},
            }
        }

        switch (ev) {
            .forward => |bytes| {
                if (self.resizeConsumes(bytes)) return;
                if (self.browseConsumes(bytes)) return;
                if (self.scrollConsumes(bytes)) return;
                const v = self.liveView() orelse return;
                self.snapViewBottom();
                v.sendInput(bytes) catch self.markViewLost();
            },
            .prefix => |byte| {
                // A prefix command keeps the adjusted width, like
                // any other key.
                if (self.resizing) self.commitResize();
                try self.handlePrefix(byte);
            },
            .arrow => |a| switch (a.dir) {
                .left, .right => {
                    // A prefixed side arrow always resizes the
                    // sidebar; a bare one resizes only while the
                    // resize is active, and belongs to the
                    // application otherwise.
                    if (a.prefixed or self.resizing) {
                        self.resizeMove(if (a.dir == .left) -1 else 1);
                        return;
                    }
                    if (self.browsing) {
                        // Like any other key, a bare side arrow
                        // ends the browse and flows onward.
                        self.browsing = false;
                        self.need_render = true;
                    }
                    const v = self.liveView() orelse return;
                    self.snapViewBottom();
                    v.sendInput(if (a.dir == .left) "\x1b[D" else "\x1b[C") catch
                        self.markViewLost();
                },
                .up, .down => {
                    // An active resize keeps its width before the
                    // arrow browses or forwards.
                    if (self.resizing) self.commitResize();
                    // A prefixed arrow always browses; a bare one browses
                    // only while the browse is active or nothing live is
                    // focused, and belongs to the application otherwise.
                    if (a.prefixed or self.browsing or self.liveView() == null) {
                        self.browseMove(if (a.dir == .up) -1 else 1);
                        return;
                    }
                    const v = self.liveView() orelse return;
                    self.snapViewBottom();
                    v.sendInput(if (a.dir == .up) "\x1b[A" else "\x1b[B") catch
                        self.markViewLost();
                },
            },
            .mouse => |m| {
                // Mouse actions may refocus or reorder everything
                // underneath the resize; keep the adjusted width.
                if (self.resizing) self.commitResize();
                try self.handleMouse(m);
            },
            .paste => |begin| {
                const v = self.liveView() orelse return;
                if (!v.term.modes.get(.bracketed_paste)) return;
                self.snapViewBottom();
                const marker: []const u8 = if (begin) "\x1b[200~" else "\x1b[201~";
                v.sendInput(marker) catch self.markViewLost();
            },
            .focus => |in| {
                const v = self.liveView() orelse return;
                if (!v.term.modes.get(.focus_event)) return;
                const marker: []const u8 = if (in) "\x1b[I" else "\x1b[O";
                v.sendInput(marker) catch self.markViewLost();
            },
        }
    }

    /// Input while the rename prompt is open edits the new name.
    /// Returns true when the event was consumed.
    fn handleRenameEvent(self: *Ui, ev: InputEvent) bool {
        const input = &(self.rename_input.?);
        switch (ev) {
            .forward => |bytes| {
                // A bare escape cancels; longer escape sequences
                // (arrow keys and friends) are ignored.
                if (bytes.len > 0 and bytes[0] == 0x1b) {
                    if (bytes.len == 1) self.cancelRename();
                    return true;
                }
                for (bytes) |byte| switch (byte) {
                    '\r', '\n' => {
                        self.commitRename();
                        return true;
                    },
                    0x7f, 0x08 => _ = input.pop(),
                    0x03 => {
                        self.cancelRename();
                        return true;
                    },
                    else => {
                        if (byte >= 0x20 and byte < 0x7f and
                            input.items.len < paths.max_name_len)
                        {
                            input.append(self.alloc, byte) catch {};
                        }
                    },
                };
                self.need_render = true;
                return true;
            },
            .prefix => {
                self.cancelRename();
                return true;
            },
            .mouse => |m| {
                if (!m.release and !m.isMotion() and !m.isWheel()) {
                    self.cancelRename();
                }
                return true;
            },
            .arrow, .paste, .focus => return true,
        }
    }

    /// Input while the search prompt is open edits the query; the
    /// sidebar selection follows the best match live. Returns true
    /// when the event was consumed.
    fn handleSearchEvent(self: *Ui, ev: InputEvent) bool {
        const input = &(self.search_input.?);
        switch (ev) {
            .forward => |bytes| {
                // A bare escape cancels; longer escape sequences
                // (arrow keys and friends) are ignored.
                if (bytes.len > 0 and bytes[0] == 0x1b) {
                    if (bytes.len == 1) self.cancelSearch();
                    return true;
                }
                for (bytes) |byte| switch (byte) {
                    '\r', '\n' => {
                        self.commitSearch();
                        return true;
                    },
                    0x7f, 0x08 => _ = input.pop(),
                    0x03 => {
                        self.cancelSearch();
                        return true;
                    },
                    else => {
                        if (byte >= 0x20 and byte < 0x7f and
                            input.items.len < paths.max_name_len)
                        {
                            input.append(self.alloc, byte) catch {};
                        }
                    },
                };
                if (self.searchMatch(input.items)) |idx| {
                    self.selected = idx;
                    self.scrollSelectedIntoView();
                }
                self.need_render = true;
                return true;
            },
            .prefix => {
                self.cancelSearch();
                return true;
            },
            .mouse => |m| {
                if (!m.release and !m.isMotion() and !m.isWheel()) {
                    self.cancelSearch();
                }
                return true;
            },
            .arrow, .paste, .focus => return true,
        }
    }

    fn handlePrefix(self: *Ui, byte: u8) !void {
        switch (byte) {
            'c', 0x03 => self.createSession(),
            'k', 0x0b => self.confirmKill(),
            'r', 0x12 => self.startRename(),
            's', 0x13 => self.startSearch(),
            'd', 0x04, 'q' => self.quitting = true,
            'n', 0x0e => self.focusOffset(1),
            'p', 0x10 => self.focusOffset(-1),
            keys.escape_byte => self.focusLast(),
            'l', 0x0c => {
                // Re-seed the local terminal from daemon state and
                // repaint everything.
                if (self.liveView()) |v| {
                    v.sendInput(&.{ keys.escape_byte, 'l' }) catch self.markViewLost();
                }
                self.full_render = true;
                self.need_render = true;
            },
            'a' => {
                // Literal C-a: the daemon's own prefix parser turns
                // C-a a into a raw 0x01 for the application.
                if (self.liveView()) |v| {
                    v.sendInput(&.{ keys.escape_byte, 'a' }) catch self.markViewLost();
                }
            },
            else => {
                if (std.ascii.isPrint(byte)) {
                    self.setMessage("^A {c} is not bound (press Ctrl+A alone for keybinds)", .{byte});
                } else {
                    self.setMessage("^A ^{c} is not bound (press Ctrl+A alone for keybinds)", .{byte ^ 0x40});
                }
            },
        }
    }

    fn handleMouse(self: *Ui, m: Mouse) !void {
        if (m.x == 0 or m.y == 0) return;
        const x: u16 = m.x - 1;
        const y: u16 = m.y - 1;

        // A click anywhere answers a pending kill confirmation with
        // "no"; a click on a kill target re-arms it below.
        if (self.confirm_kill != null and !m.release and !m.isMotion() and !m.isWheel()) {
            self.confirm_kill = null;
            self.need_render = true;
        }

        // An in-progress viewport selection captures the drag and the
        // release wherever the pointer wanders.
        if (self.select_anchor != null and !m.isWheel() and (m.isMotion() or m.release)) {
            return self.dragSelection(m, x -| self.layout.viewportX(), y);
        }

        if (m.isWheel() and !m.release) {
            switch (self.layout.hit(x, y)) {
                .viewport => return self.wheelViewport(m),
                else => {
                    // Wheel over the sidebar scrolls the session list.
                    const down = m.code & 1 != 0;
                    if (down) {
                        self.scroll += 1;
                    } else {
                        self.scroll -|= 1;
                    }
                    self.clampScroll();
                    self.need_render = true;
                    return;
                },
            }
        }

        switch (self.layout.hit(x, y)) {
            .viewport => |cell| {
                // Applications that asked for mouse reporting get the
                // events; otherwise a left press starts a selection.
                const v = self.liveView() orelse return;
                if (v.term.flags.mouse_event != .none) return self.forwardMouse(m);
                if (m.release or m.isMotion() or m.code & 3 != 0) return;
                self.select_anchor = .{
                    .x = @min(cell.x, v.term.cols -| 1),
                    .y = @min(cell.y, v.term.rows -| 1),
                };
                self.select_head = self.select_anchor.?;
                self.need_render = true;
            },
            .session => |s| {
                if (m.release or m.isMotion()) return;
                const idx = self.scroll + s.row / Layout.entry_rows;
                if (idx >= self.sessions.items.len) return;
                if (s.kill and s.row % Layout.entry_rows == 0) {
                    self.armKillConfirm(idx);
                    return;
                }
                self.focusIndex(idx);
            },
            .new_button => {
                if (m.release or m.isMotion()) return;
                self.createSession();
            },
            else => {},
        }
    }

    /// Wheel over the viewport. Applications that asked for mouse
    /// reporting get the event. Alternate-screen applications get
    /// arrow keys per tick, like terminals' alternate-scroll mode,
    /// so pagers scroll without mouse support. Otherwise the wheel
    /// pages the view's local scrollback.
    fn wheelViewport(self: *Ui, m: Mouse) !void {
        const v = self.liveView() orelse return;
        if (v.term.flags.mouse_event != .none) return self.forwardMouse(m);
        const down = m.code & 1 != 0;
        if (v.app_alt) {
            const seq: []const u8 = if (v.term.modes.get(.cursor_keys))
                (if (down) "\x1bOB" else "\x1bOA")
            else
                (if (down) "\x1b[B" else "\x1b[A");
            for (0..wheel_lines) |_| {
                v.sendInput(seq) catch return self.markViewLost();
            }
            return;
        }
        self.scrollView(if (down) wheel_lines else -@as(isize, wheel_lines));
    }

    /// Page the focused view's scrollback by delta rows (up is
    /// negative). A scrolled viewport pins to its content, so
    /// streaming output does not move it; the bottom row hints how
    /// to get back.
    fn scrollView(self: *Ui, delta: isize) void {
        const v = self.liveView() orelse return;
        if (!self.viewScrolled()) {
            // The scrollback hint renders on the bottom row; a stale
            // transient message would cover it up.
            self.message.clearRetainingCapacity();
            self.message_deadline = 0;
        }
        v.term.scrollViewport(.{ .delta = delta });
        self.full_render = true;
        self.need_render = true;
    }

    /// Whether the focused view's viewport is scrolled into history.
    fn viewScrolled(self: *Ui) bool {
        const v = self.view orelse return false;
        if (v.state != .live) return false;
        return !v.term.screens.active.viewportIsBottom();
    }

    /// Return the viewport to the live bottom, so input lands where
    /// the user can see it.
    fn snapViewBottom(self: *Ui) void {
        if (!self.viewScrolled()) return;
        if (self.view) |v| v.term.scrollViewport(.{ .bottom = {} });
        self.full_render = true;
        self.need_render = true;
    }

    /// A lone Esc while the view is scrolled returns it to the
    /// bottom instead of reaching the application.
    fn scrollConsumes(self: *Ui, bytes: []const u8) bool {
        if (!self.viewScrolled()) return false;
        if (bytes.len == 1 and bytes[0] == 0x1b) {
            self.snapViewBottom();
            return true;
        }
        return false;
    }

    /// Track press state and forward the event to the application
    /// when it asked for mouse reporting, with coordinates translated
    /// into viewport space.
    fn forwardMouse(self: *Ui, m: Mouse) !void {
        const v = self.liveView() orelse return;

        if (!m.isWheel() and !m.isMotion()) {
            if (m.release) {
                self.mouse_pressed = false;
            } else {
                self.mouse_pressed = true;
            }
        }

        if (v.term.flags.mouse_event == .none) return;

        const cell_x: u16 = (m.x - 1) -| self.layout.viewportX();
        const cell_y: u16 = m.y - 1;

        const SizeType = @FieldType(vt.input.MouseEncodeOptions, "size");
        const size: SizeType = .{
            .screen = .{
                .width = @as(u32, v.term.cols) * cell_px_w,
                .height = @as(u32, v.term.rows) * cell_px_h,
            },
            .cell = .{ .width = cell_px_w, .height = cell_px_h },
            .padding = .{},
        };
        var opts: vt.input.MouseEncodeOptions = .fromTerminal(&v.term, size);
        opts.any_button_pressed = self.mouse_pressed;
        opts.last_cell = &self.mouse_last_cell;

        const event: vt.input.MouseEncodeEvent = .{
            .action = if (m.release)
                .release
            else if (m.isMotion())
                .motion
            else
                .press,
            .button = sgrButton(m),
            .mods = .{
                .shift = m.code & 4 != 0,
                .alt = m.code & 8 != 0,
                .ctrl = m.code & 16 != 0,
            },
            .pos = .{
                .x = (@as(f32, @floatFromInt(cell_x)) + 0.5) * cell_px_w,
                .y = (@as(f32, @floatFromInt(cell_y)) + 0.5) * cell_px_h,
            },
        };

        var enc_buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&enc_buf);
        vt.input.encodeMouse(&writer, event, opts) catch return;
        const encoded = writer.buffered();
        if (encoded.len > 0) v.sendInput(encoded) catch self.markViewLost();
    }

    /// Update an in-progress selection from a drag or release. On
    /// release the selected text is copied to the clipboard.
    fn dragSelection(self: *Ui, m: Mouse, x: u16, y: u16) void {
        const v = self.liveView() orelse {
            self.select_anchor = null;
            return;
        };
        const head: CellPos = .{
            .x = @min(x, v.term.cols -| 1),
            .y = @min(y, v.term.rows -| 1),
        };
        if (head.x != self.select_head.x or head.y != self.select_head.y) {
            self.select_head = head;
            self.need_render = true;
        }
        if (!m.release) return;

        const anchor = self.select_anchor.?;
        if (anchor.x != self.select_head.x or anchor.y != self.select_head.y) {
            self.copySelection(v);
        }
        self.select_anchor = null;
        self.need_render = true;
    }

    /// The selection's inclusive span on viewport row `y`, or null
    /// when the row is outside the selection.
    fn selectionSpan(self: *Ui, y: u16, cols: u16) ?struct { x0: u16, x1: u16 } {
        const anchor = self.select_anchor orelse return null;
        if (cols == 0) return null;
        var s = anchor;
        var e = self.select_head;
        if (e.y < s.y or (e.y == s.y and e.x < s.x)) std.mem.swap(CellPos, &s, &e);
        if (y < s.y or y > e.y) return null;
        const x0: u16 = if (y == s.y) @min(s.x, cols - 1) else 0;
        const x1: u16 = if (y == e.y) @min(e.x, cols - 1) else cols - 1;
        if (x0 > x1) return null;
        return .{ .x0 = x0, .x1 = x1 };
    }

    /// Copy the selected viewport text to the clipboard via OSC 52,
    /// which works over SSH and through nested multiplexers.
    fn copySelection(self: *Ui, v: *View) void {
        const alloc = self.alloc;

        var s = self.select_anchor.?;
        var e = self.select_head;
        if (e.y < s.y or (e.y == s.y and e.x < s.x)) std.mem.swap(CellPos, &s, &e);

        const screen = v.term.screens.active;
        const start = screen.pages.pin(.{ .viewport = .{ .x = s.x, .y = s.y } }) orelse return;
        const end = screen.pages.pin(.{ .viewport = .{ .x = e.x, .y = e.y } }) orelse return;

        var formatter: vt.formatter.ScreenFormatter = .init(screen, .plain);
        formatter.content = .{ .selection = vt.Selection.init(start, end, false) };

        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        aw.writer.print("{f}", .{formatter}) catch return;
        const text = aw.writer.buffered();
        if (text.len == 0) return;

        const encoder = std.base64.standard.Encoder;
        var seq: std.ArrayList(u8) = .empty;
        defer seq.deinit(alloc);
        seq.appendSlice(alloc, "\x1b]52;c;") catch return;
        const b64 = seq.addManyAsSlice(alloc, encoder.calcSize(text.len)) catch return;
        _ = encoder.encode(b64, text);
        seq.appendSlice(alloc, "\x07") catch return;
        protocol.writeAll(1, seq.items) catch {};

        self.setMessage("copied {d} characters", .{text.len});
    }

    fn sgrButton(m: Mouse) ?vt.input.MouseButton {
        if (m.isWheel()) {
            return if (m.code & 1 != 0) .five else .four;
        }
        return switch (m.code & 3) {
            0 => .left,
            1 => .middle,
            2 => .right,
            else => null,
        };
    }

    // -- Daemon output -------------------------------------------------------

    fn readView(self: *Ui, buf: []u8) !void {
        const v = self.view orelse return;
        if (v.state != .live) return;
        const n = posix.read(v.sock, buf) catch 0;
        if (n == 0) {
            self.markViewLost();
            return;
        }
        v.decoder.feed(buf[0..n]) catch {
            self.markViewLost();
            return;
        };
        // refreshSessions can destroy the view (it collects dead
        // views and attaches replacement sessions), which would leave
        // `v` dangling, so an exit defers the refresh until the
        // message loop is done with the pointer.
        var ended = false;
        while (true) {
            const msg = v.decoder.next() catch {
                self.markViewLost();
                return;
            } orelse break;
            switch (msg.type) {
                .output => {
                    v.feedOutput(msg.payload);
                    self.need_render = true;
                },
                .detached => {
                    v.state = .stolen;
                    self.setMessage("session attached elsewhere", .{});
                    self.need_render = true;
                },
                .screen => {
                    v.app_alt = std.mem.eql(u8, msg.payload, "alt");
                },
                .exit => {
                    v.state = .ended;
                    ended = true;
                    self.setMessage("session ended", .{});
                    self.need_render = true;
                },
                else => {},
            }
            if (v.state != .live) break;
        }
        if (ended) self.refreshSessions() catch {};
    }

    fn liveView(self: *Ui) ?*View {
        const v = self.view orelse return null;
        if (v.state != .live) return null;
        return v;
    }

    fn markViewLost(self: *Ui) void {
        if (self.view) |v| {
            if (v.state == .live) v.state = .lost;
        }
        self.refreshSessions() catch {};
        self.need_render = true;
    }

    // -- Session management ----------------------------------------------------

    /// Re-query every session socket. Selection is kept by name and
    /// automatic focus never steals: when nothing is focused the most
    /// recently active free session is attached, and a focused session
    /// whose attachment broke is reclaimed once it frees up. A live
    /// view always outlives a transient listing failure; its own
    /// socket decides when the attachment is over.
    fn refreshSessions(self: *Ui) !void {
        self.next_refresh_ms = std.time.milliTimestamp() + refresh_interval_ms;

        const selected_name: ?[]u8 = if (self.selected) |i|
            try self.alloc.dupe(u8, self.sessions.items[i].name)
        else
            null;
        defer if (selected_name) |n| self.alloc.free(n);

        var fresh: std.ArrayList(Entry) = .empty;
        errdefer freeEntries(self.alloc, &fresh);

        const names = try paths.listSessions(self.alloc, self.dir);
        defer {
            for (names) |n| self.alloc.free(n);
            self.alloc.free(names);
        }
        std.mem.sort([]u8, names, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);

        const main = @import("main.zig");
        for (names) |name| {
            const info = main.sessionInfo(self.alloc, self.dir, name) catch continue orelse continue;
            defer self.alloc.free(info.text);
            try fresh.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, name),
                .attached = info.attached,
                .idle_ms = info.idle_ms,
                .title = try self.alloc.dupe(u8, info.title),
            });
        }

        freeEntries(self.alloc, &self.sessions);
        self.sessions = fresh;

        // Restore selection by name; the focused view's session counts
        // even when the sidebar selection was already empty.
        const want_name: ?[]const u8 = selected_name orelse self.view_name;
        self.selected = null;
        if (want_name) |want| {
            for (self.sessions.items, 0..) |entry, i| {
                if (std.mem.eql(u8, entry.name, want)) {
                    self.selected = i;
                    break;
                }
            }
        }

        if (self.selected) |i| {
            self.maybeReclaim(i);
        } else if (self.liveView() != null) {
            // The focused session vanished from the listing while its
            // socket stays healthy: a transient failure. Keep the view;
            // selection returns when the listing recovers.
        } else if (self.autoFocusable()) |i| {
            self.selected = i;
            self.attachSelected();
        } else if (self.view) |v| {
            // No automatic candidate. A live view keeps running, but a
            // dead one makes room for the empty state.
            if (v.state != .live) {
                v.destroy();
                self.view = null;
                if (self.view_name) |n| self.alloc.free(n);
                self.view_name = null;
            }
        }
        self.clampScroll();
        self.need_render = true;
    }

    fn isHost(self: *Ui, idx: usize) bool {
        const host = self.host_name orelse return false;
        return std.mem.eql(u8, self.sessions.items[idx].name, host);
    }

    /// Re-attach the focused session after our attachment broke, once
    /// no other client holds it: stolen views recover when the thief
    /// lets go, lost sockets when the daemon answers again, and a
    /// selection that never attached (no-steal startup) binds as soon
    /// as the session frees up. An active browse suppresses the
    /// reclaim: the selection is a candidate, not a commitment.
    fn maybeReclaim(self: *Ui, idx: usize) void {
        if (self.browsing) return;
        if (self.sessions.items[idx].attached) return;
        const broken = if (self.view) |v|
            v.state == .stolen or v.state == .lost
        else
            true;
        if (broken) self.attachSelected();
    }

    /// The most recently active session eligible for automatic
    /// attachment: never this UI's host, and never a session some
    /// other client holds. Automatic focus must not steal; only a
    /// deliberate click or keypress may. An active browse also
    /// suppresses it, so the highlight is not yanked mid-decision.
    fn autoFocusable(self: *Ui) ?usize {
        if (self.browsing) return null;
        var best: ?usize = null;
        for (self.sessions.items, 0..) |entry, i| {
            if (self.isHost(i)) continue;
            if (entry.attached) continue;
            if (best == null or entry.idle_ms < self.sessions.items[best.?].idle_ms) {
                best = i;
            }
        }
        return best;
    }

    /// Startup fallback when every session is attached elsewhere:
    /// select the most recently active one without attaching, so the
    /// sidebar has a focus target but nothing is stolen.
    fn selectInitial(self: *Ui) void {
        var best: ?usize = null;
        for (self.sessions.items, 0..) |entry, i| {
            if (self.isHost(i)) continue;
            if (best == null or entry.idle_ms < self.sessions.items[best.?].idle_ms) {
                best = i;
            }
        }
        self.selected = best;
    }

    fn attachSelected(self: *Ui) void {
        const idx = self.selected orelse return;
        const name = self.sessions.items[idx].name;

        if (self.view) |v| {
            v.destroy();
            self.view = null;
        }
        if (self.view_name) |n| self.alloc.free(n);
        self.view_name = null;

        const sock = paths.socketPath(self.alloc, self.dir, name) catch return;
        defer self.alloc.free(sock);
        self.view = View.create(
            self.alloc,
            sock,
            self.layout.viewportRows(),
            self.layout.viewportCols(),
        ) catch |err| {
            self.setMessage("attach {s} failed: {s}", .{ name, @errorName(err) });
            return;
        };
        self.view_name = self.alloc.dupe(u8, name) catch null;
        self.select_anchor = null;
        // Any attach ends an in-progress browse: the selection and
        // the focused session are one again.
        self.browsing = false;
        self.view_gen += 1;
        self.full_render = true;
        self.need_render = true;
    }

    fn rememberLast(self: *Ui, idx: usize) void {
        const name = self.sessions.items[idx].name;
        if (self.last_name) |old| self.alloc.free(old);
        self.last_name = self.alloc.dupe(u8, name) catch null;
    }

    fn focusIndex(self: *Ui, idx: usize) void {
        if (idx >= self.sessions.items.len) return;
        if (self.isHost(idx)) {
            self.setMessage("{s} hosts this ui", .{self.sessions.items[idx].name});
            return;
        }
        if (self.selected) |cur| {
            if (cur != idx) self.rememberLast(cur);
        }
        self.selected = idx;
        self.scrollSelectedIntoView();
        self.attachSelected();
    }

    fn focusOffset(self: *Ui, dir: i2) void {
        const len = self.sessions.items.len;
        if (len == 0) return;
        const cur = self.selected orelse len - 1;
        // Step past the session hosting this UI, when nested.
        var idx = cur;
        for (0..len) |_| {
            idx = if (dir > 0)
                (idx + 1) % len
            else
                (idx + len - 1) % len;
            if (!self.isHost(idx)) break;
        }
        if (self.isHost(idx)) return;
        self.focusIndex(idx);
    }

    fn focusLast(self: *Ui) void {
        const want = self.last_name orelse return;
        for (self.sessions.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, want)) {
                self.focusIndex(i);
                return;
            }
        }
        self.setMessage("no previous session", .{});
    }

    /// Move the sidebar selection one row without attaching: arrow
    /// browsing. Wraps and steps past the host session like
    /// focusOffset.
    fn browseMove(self: *Ui, dir: i2) void {
        const len = self.sessions.items.len;
        if (len == 0) return;
        self.browsing = true;
        // The browse hint renders on the bottom row; a stale
        // transient message would cover it up.
        self.message.clearRetainingCapacity();
        self.message_deadline = 0;
        const cur = self.selected orelse len - 1;
        var idx = cur;
        for (0..len) |_| {
            idx = if (dir > 0)
                (idx + 1) % len
            else
                (idx + len - 1) % len;
            if (!self.isHost(idx)) break;
        }
        if (!self.isHost(idx)) self.selected = idx;
        self.scrollSelectedIntoView();
        self.need_render = true;
    }

    /// Enter/Esc handling while the browse is active, or while
    /// nothing live is focused and key forwarding has no target:
    /// Enter attaches the selection, a lone Esc cancels the browse,
    /// and any other key ends it and flows onward.
    fn browseConsumes(self: *Ui, bytes: []const u8) bool {
        if (!self.browsing and self.liveView() != null) return false;
        if (bytes.len == 0) return false;
        switch (bytes[0]) {
            '\r', '\n' => {
                self.commitBrowse();
                return true;
            },
            0x1b => {
                // A lone Esc cancels; longer escape sequences were
                // already split off as arrow/mouse events upstream.
                if (bytes.len == 1 and self.browsing) {
                    self.cancelBrowse();
                    return true;
                }
                return false;
            },
            else => {
                self.browsing = false;
                return false;
            },
        }
    }

    /// Attach the browsed selection. Enter on the already-focused
    /// session just ends the browse instead of re-attaching it.
    fn commitBrowse(self: *Ui) void {
        self.browsing = false;
        self.need_render = true;
        const idx = self.selected orelse return;
        if (self.liveView() != null and idx < self.sessions.items.len) {
            if (self.view_name) |focused| {
                if (std.mem.eql(u8, self.sessions.items[idx].name, focused)) return;
            }
        }
        self.focusIndex(idx);
    }

    /// Drop the browse and snap the selection back to the focused
    /// session, mirroring how a cancelled search restores its origin.
    fn cancelBrowse(self: *Ui) void {
        self.browsing = false;
        if (self.view_name) |want| {
            for (self.sessions.items, 0..) |entry, i| {
                if (std.mem.eql(u8, entry.name, want)) {
                    self.selected = i;
                    self.scrollSelectedIntoView();
                    break;
                }
            }
        }
        self.need_render = true;
    }

    /// Adjust the sidebar width by one column: arrow resizing, armed
    /// by C-a Left/Right. The first move records the width to restore
    /// on Esc. An active browse is cancelled, since the arrows now
    /// resize instead of selecting.
    fn resizeMove(self: *Ui, dir: i2) void {
        if (self.browsing) self.cancelBrowse();
        if (!self.resizing) {
            self.resizing = true;
            self.resize_origin = self.layout.sidebar_w;
            // The resize hint renders on the bottom row; a stale
            // transient message would cover it up.
            self.message.clearRetainingCapacity();
            self.message_deadline = 0;
        }
        self.applySidebarWidth(@as(i32, self.layout.sidebar_w) + dir);
    }

    /// Enter/Esc handling while the sidebar resize is active: Enter
    /// keeps the width, a lone Esc restores the original, and any
    /// other key keeps it and flows onward.
    fn resizeConsumes(self: *Ui, bytes: []const u8) bool {
        if (!self.resizing) return false;
        if (bytes.len == 0) return false;
        switch (bytes[0]) {
            '\r', '\n' => {
                self.commitResize();
                return true;
            },
            0x1b => {
                // A lone Esc cancels; longer escape sequences were
                // already split off as arrow/mouse events upstream.
                if (bytes.len == 1) {
                    self.cancelResize();
                    return true;
                }
                return false;
            },
            else => {
                self.commitResize();
                return false;
            },
        }
    }

    /// End the resize keeping the current width, and reapply it
    /// (clamped) when the terminal itself resizes later.
    fn commitResize(self: *Ui) void {
        self.resizing = false;
        self.sidebar_pref = self.layout.sidebar_w;
        self.need_render = true;
    }

    /// Drop the resize and restore the width from before the first
    /// arrow, mirroring how a cancelled browse restores its origin.
    fn cancelResize(self: *Ui) void {
        self.resizing = false;
        self.applySidebarWidth(self.resize_origin);
    }

    /// Clamp and apply a sidebar width. The viewport shifts with it,
    /// so the live view (and the session pty behind it) resizes and
    /// every row repaints.
    fn applySidebarWidth(self: *Ui, want: i32) void {
        const w = self.clampSidebarWidth(want);
        self.need_render = true;
        if (w == self.layout.sidebar_w) return;
        self.layout.sidebar_w = w;
        if (self.view) |v| {
            v.resize(self.layout.viewportRows(), self.layout.viewportCols()) catch |err| {
                log.warn("viewport resize failed: {}", .{err});
            };
        }
        // Cell coordinates shift with the layout, so any in-progress
        // selection no longer points at the text the user dragged over.
        self.select_anchor = null;
        self.full_render = true;
    }

    /// Keep the sidebar between a usable minimum and a width that
    /// leaves the viewport at least a sliver, like Layout.init does
    /// for narrow terminals.
    fn clampSidebarWidth(self: *Ui, want: i32) u16 {
        const lo: i32 = 8;
        const hi: i32 = @max(lo, @as(i32, self.layout.cols) - 12);
        return @intCast(std.math.clamp(want, lo, hi));
    }

    /// Create a session by re-running our own binary with `new -d`.
    /// The exec drops every inherited descriptor (they are all
    /// CLOEXEC), so the daemon cannot pin the UI's sockets open, and
    /// naming falls back exactly like the CLI.
    fn createSession(self: *Ui) void {
        const exe = std.fs.selfExePathAlloc(self.alloc) catch {
            self.setMessage("create failed", .{});
            return;
        };
        defer self.alloc.free(exe);

        const result = std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = &.{ exe, "new", "-d" },
        }) catch {
            self.setMessage("create failed", .{});
            return;
        };
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            const reason = std.mem.trim(u8, result.stderr, " \n");
            self.setMessage("create failed: {s}", .{reason});
            return;
        }
        const name = std.mem.trimRight(u8, result.stdout, "\n");
        self.setMessage("created {s}", .{name});

        self.refreshSessions() catch return;
        for (self.sessions.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                self.focusIndex(i);
                break;
            }
        }
    }

    fn confirmKill(self: *Ui) void {
        const idx = self.selected orelse {
            self.setMessage("no session to kill", .{});
            return;
        };
        self.armKillConfirm(idx);
    }

    fn armKillConfirm(self: *Ui, idx: usize) void {
        self.confirm_kill = idx;
        // The prompt renders from confirm_kill; a stale transient
        // message would cover it up.
        self.message.clearRetainingCapacity();
        self.message_deadline = 0;
        self.need_render = true;
    }

    fn startRename(self: *Ui) void {
        const idx = self.selected orelse {
            self.setMessage("no session to rename", .{});
            return;
        };
        self.confirm_kill = null;
        self.rename_target = idx;
        var input: std.ArrayList(u8) = .empty;
        // Pre-fill with the current name for quick edits.
        input.appendSlice(self.alloc, self.sessions.items[idx].name) catch {};
        if (self.rename_input) |*old| old.deinit(self.alloc);
        self.rename_input = input;
        // The prompt renders from rename_input; a stale transient
        // message would cover it up.
        self.message.clearRetainingCapacity();
        self.message_deadline = 0;
        self.need_render = true;
    }

    fn cancelRename(self: *Ui) void {
        if (self.rename_input) |*input| input.deinit(self.alloc);
        self.rename_input = null;
        self.setMessage("rename cancelled", .{});
    }

    /// Ask the daemon to rename the prompt's target session. On
    /// success the local entry is patched in place: selection is
    /// restored by name on refresh, and the attached view's socket
    /// stays connected across the rename.
    fn commitRename(self: *Ui) void {
        var input = self.rename_input.?;
        self.rename_input = null;
        defer input.deinit(self.alloc);
        const new_name = input.items;

        const idx = self.rename_target;
        if (idx >= self.sessions.items.len) return;
        const entry = &self.sessions.items[idx];
        if (std.mem.eql(u8, entry.name, new_name)) {
            self.need_render = true;
            return;
        }
        paths.validateName(new_name) catch {
            self.setMessage("invalid session name '{s}'", .{new_name});
            return;
        };

        const sock = paths.socketPath(self.alloc, self.dir, entry.name) catch return;
        defer self.alloc.free(sock);
        const result = client.control(self.alloc, sock, &.{ "rename", new_name }) catch {
            self.setMessage("rename failed", .{});
            return;
        };
        defer self.alloc.free(result.text);
        if (!result.ok) {
            self.setMessage("{s}", .{result.text});
            return;
        }

        self.setMessage("renamed {s} to {s}", .{ entry.name, new_name });
        const owned = self.alloc.dupe(u8, new_name) catch return;
        self.alloc.free(entry.name);
        entry.name = owned;
        self.refreshSessions() catch {};
    }

    fn killSession(self: *Ui, idx: usize) void {
        if (idx >= self.sessions.items.len) return;
        const name = self.sessions.items[idx].name;

        const sock = paths.socketPath(self.alloc, self.dir, name) catch return;
        defer self.alloc.free(sock);
        const result = client.control(self.alloc, sock, &.{"quit"}) catch {
            // The daemon is already gone; remove the stale socket.
            std.fs.cwd().deleteFile(sock) catch {};
            self.refreshSessions() catch {};
            return;
        };
        self.alloc.free(result.text);
        self.setMessage("killed {s}", .{name});
        self.refreshSessions() catch {};
    }

    /// First session whose name starts with `query`, else the first
    /// whose name contains it; case-insensitive. Null for an empty
    /// query or no match.
    fn searchMatch(self: *Ui, query: []const u8) ?usize {
        if (query.len == 0) return null;
        var contains: ?usize = null;
        for (self.sessions.items, 0..) |entry, idx| {
            if (std.ascii.startsWithIgnoreCase(entry.name, query)) return idx;
            if (contains == null and
                std.ascii.indexOfIgnoreCase(entry.name, query) != null)
            {
                contains = idx;
            }
        }
        return contains;
    }

    fn startSearch(self: *Ui) void {
        if (self.sessions.items.len == 0) {
            self.setMessage("no sessions to search", .{});
            return;
        }
        self.confirm_kill = null;
        self.search_origin = self.selected;
        if (self.search_input) |*old| old.deinit(self.alloc);
        self.search_input = .empty;
        // The prompt renders from search_input; a stale transient
        // message would cover it up.
        self.message.clearRetainingCapacity();
        self.message_deadline = 0;
        self.need_render = true;
    }

    fn cancelSearch(self: *Ui) void {
        if (self.search_input) |*input| input.deinit(self.alloc);
        self.search_input = null;
        // Put the selection back where it was before the live
        // matching moved it.
        if (self.search_origin) |idx| {
            if (idx < self.sessions.items.len) {
                self.selected = idx;
                self.scrollSelectedIntoView();
            }
        }
        self.search_origin = null;
        self.setMessage("search cancelled", .{});
    }

    /// Focus the best match for the typed query and close the prompt.
    fn commitSearch(self: *Ui) void {
        var input = self.search_input.?;
        self.search_input = null;
        defer input.deinit(self.alloc);
        self.search_origin = null;
        self.need_render = true;
        if (input.items.len == 0) return;
        const idx = self.searchMatch(input.items) orelse {
            self.setMessage("no session matches '{s}'", .{input.items});
            return;
        };
        self.focusIndex(idx);
    }

    fn setMessage(self: *Ui, comptime fmt: []const u8, args: anytype) void {
        self.message.clearRetainingCapacity();
        self.message.print(self.alloc, fmt, args) catch {};
        self.message_deadline = std.time.milliTimestamp() + message_ttl_ms;
        self.need_render = true;
    }

    fn clampScroll(self: *Ui) void {
        const max_scroll = self.sessions.items.len -| self.layout.visibleEntries();
        if (self.scroll > max_scroll) self.scroll = max_scroll;
    }

    /// Scroll just enough that the selected session is on screen.
    /// Only focus changes call this, so wheel scrolling can move the
    /// list freely without snapping back to the selection.
    fn scrollSelectedIntoView(self: *Ui) void {
        self.clampScroll();
        const visible = self.layout.visibleEntries();
        const idx = self.selected orelse return;
        if (idx < self.scroll) self.scroll = idx;
        if (idx >= self.scroll + visible) {
            self.scroll = idx + 1 - visible;
        }
    }

    // -- Rendering -----------------------------------------------------------

    fn renderIfNeeded(self: *Ui) !void {
        if (!self.need_render) return;
        const now = std.time.milliTimestamp();
        if (now - self.last_render_ms < render_interval_ms) return;
        self.last_render_ms = now;
        self.need_render = false;

        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.alloc);
        try self.composeFrame(&frame);
        self.full_render = false;
        if (frame.items.len > 0) try protocol.writeAll(1, frame.items);
    }

    /// Build the bytes for one repaint: changed rows only, wrapped in
    /// a synchronized update so terminals that support it repaint
    /// atomically.
    fn composeFrame(self: *Ui, frame: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;
        const l = self.layout;

        // Grow/shrink the row cache to the current height.
        while (self.row_cache.items.len < l.rows) {
            try self.row_cache.append(alloc, .empty);
        }
        while (self.row_cache.items.len > l.rows) {
            var row = self.row_cache.pop() orelse break;
            row.deinit(alloc);
        }

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);

        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(alloc);

        for (0..l.rows) |y| {
            scratch.clearRetainingCapacity();
            try self.composeRow(@intCast(y), &scratch);
            const cache = &self.row_cache.items[y];
            if (!self.full_render and std.mem.eql(u8, cache.items, scratch.items)) {
                continue;
            }
            cache.clearRetainingCapacity();
            try cache.appendSlice(alloc, scratch.items);
            try body.print(alloc, "\x1b[{d};1H", .{y + 1});
            try body.appendSlice(alloc, scratch.items);
        }

        const cursor = self.cursorSequence();

        if (body.items.len == 0 and !self.full_render) {
            // Row content unchanged; the cursor may still have moved.
            try frame.appendSlice(alloc, "\x1b[?25l");
            try frame.appendSlice(alloc, cursor.pos[0..cursor.pos_len]);
            try frame.appendSlice(alloc, if (cursor.visible) "\x1b[?25h" else "\x1b[?25l");
            return;
        }

        try frame.appendSlice(alloc, "\x1b[?2026h\x1b[?25l");
        try frame.appendSlice(alloc, body.items);
        try frame.appendSlice(alloc, cursor.pos[0..cursor.pos_len]);
        try frame.appendSlice(alloc, if (cursor.visible) "\x1b[?25h" else "\x1b[?25l");
        try frame.appendSlice(alloc, "\x1b[?2026l");
    }

    const CursorState = struct {
        pos: [32]u8 = undefined,
        pos_len: usize = 0,
        visible: bool = false,
    };

    fn cursorSequence(self: *Ui) CursorState {
        var state: CursorState = .{};
        if (self.renameCursor()) |s| return s;
        if (self.searchCursor()) |s| return s;
        const v = self.liveView() orelse return state;
        // While scrolled back the cursor coordinates belong to the
        // bottom of the screen, not the history rows on display, so
        // keep the cursor hidden until the viewport snaps back.
        if (self.viewScrolled()) return state;
        const cursor = &v.term.screens.active.cursor;
        const row: usize = @min(cursor.y, self.layout.viewportRows() -| 1);
        const col: usize = @min(
            @as(usize, cursor.x) + self.layout.viewportX(),
            self.layout.cols -| 1,
        );
        const text = std.fmt.bufPrint(&state.pos, "\x1b[{d};{d}H", .{
            row + 1,
            col + 1,
        }) catch return state;
        state.pos_len = text.len;
        state.visible = v.term.modes.get(.cursor_visible);
        // A session cursor on the last row would blink over the
        // status overlay while it shows; keep it hidden until the
        // overlay clears.
        if (self.statusActive() and row == self.layout.rows -| 1) {
            state.visible = false;
        }
        return state;
    }

    /// While the rename prompt is open, the cursor sits at the end
    /// of the typed name in the status bar.
    fn renameCursor(self: *Ui) ?CursorState {
        const input = self.rename_input orelse return null;
        if (self.rename_target >= self.sessions.items.len) return null;
        var state: CursorState = .{};
        const prompt_len = " rename ".len +
            self.sessions.items[self.rename_target].name.len + ": ".len;
        const col = @min(prompt_len + input.items.len + 1, self.layout.cols);
        const text = std.fmt.bufPrint(&state.pos, "\x1b[{d};{d}H", .{
            self.layout.rows,
            col,
        }) catch return state;
        state.pos_len = text.len;
        state.visible = true;
        return state;
    }

    /// While the search prompt is open, the cursor sits at the end
    /// of the typed query in the status bar.
    fn searchCursor(self: *Ui) ?CursorState {
        const input = self.search_input orelse return null;
        var state: CursorState = .{};
        const prompt_len = " search: ".len;
        const col = @min(prompt_len + input.items.len + 1, self.layout.cols);
        const text = std.fmt.bufPrint(&state.pos, "\x1b[{d};{d}H", .{
            self.layout.rows,
            col,
        }) catch return state;
        state.pos_len = text.len;
        state.visible = true;
        return state;
    }

    /// Whether the bottom-row status overlay has content to show: an
    /// open prompt, the armed-prefix keybind list, an active browse,
    /// resize, or scrollback, or a live message.
    fn statusActive(self: *Ui) bool {
        return self.rename_input != null or self.search_input != null or
            self.confirm_kill != null or self.parser.pending_prefix or
            self.browsing or self.resizing or self.viewScrolled() or
            self.message.items.len > 0;
    }

    /// One full screen row: sidebar columns, separator, then the
    /// viewport slice. The sidebar segment is always exactly
    /// sidebar_w columns so the row never bleeds into the viewport.
    /// While status content is active it overlays the last row full
    /// width; the row repaints from cached state when it clears.
    fn composeRow(self: *Ui, y: u16, out: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;

        try out.appendSlice(alloc, sgr_reset);
        if (y == self.layout.rows -| 1 and self.statusActive()) {
            try self.composeStatusRow(out);
            return;
        }
        try self.composeSidebarCell(y, out);
        try out.appendSlice(alloc, style_dim);
        try out.appendSlice(alloc, "\u{2502}");
        try out.appendSlice(alloc, sgr_reset);
        try self.composeViewportCell(y, out);
    }

    const keybind_bar =
        " c new  k kill  r rename  s search  n/p switch  up/dn browse  lt/rt resize  d quit  C-a last  a literal  l redraw  esc cancel";

    /// Status content overlaid full-width on the last screen row
    /// while present: rename prompt, kill confirmation, the keybind
    /// list while the prefix is armed, or a transient message.
    fn composeStatusRow(self: *Ui, out: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;
        const w = self.layout.cols;

        try out.appendSlice(alloc, style_dim);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(alloc);

        // Prompts outlive transient messages, so they are regenerated
        // from their state rather than stored.
        if (self.rename_input) |input| {
            if (self.rename_target < self.sessions.items.len) {
                try text.print(alloc, " rename {s}: {s}", .{
                    self.sessions.items[self.rename_target].name,
                    input.items,
                });
            }
        } else if (self.search_input) |input| {
            try text.print(alloc, " search: {s}", .{input.items});
        } else if (self.confirm_kill) |idx| {
            if (idx < self.sessions.items.len) {
                try text.print(alloc, " kill {s}? y/n", .{self.sessions.items[idx].name});
            }
        } else if (self.parser.pending_prefix) {
            try text.appendSlice(alloc, keybind_bar);
        } else if (self.message.items.len > 0) {
            try text.print(alloc, " {s}", .{self.message.items});
        } else if (self.resizing) {
            try text.appendSlice(alloc, " left/right resize  enter done  esc cancel");
        } else if (self.browsing) {
            try text.appendSlice(alloc, " up/down select  enter attach  esc cancel");
        } else if (self.viewScrolled()) {
            try text.appendSlice(alloc, " scrollback  wheel down or esc to return");
        }
        try appendClipped(alloc, out, text.items, w);
        try out.appendSlice(alloc, sgr_reset);
    }

    fn composeSidebarCell(self: *Ui, y: u16, out: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;
        const l = self.layout;
        const w = l.sidebar_w;

        if (y == l.rows -| 1) {
            // The bottom sidebar row always shows how to reach the
            // keybinds; the status overlay covers it while active.
            try out.appendSlice(alloc, style_dim);
            try appendClipped(alloc, out, " Keybinds: Ctrl+A", w);
            try out.appendSlice(alloc, sgr_reset);
            return;
        }
        if (y == 0) {
            try out.appendSlice(alloc, style_dim);
            try appendClipped(alloc, out, " + new session", w);
            try out.appendSlice(alloc, sgr_reset);
            return;
        }
        if (y < Layout.list_top) {
            // Blank gap between the button and the session list.
            try appendClipped(alloc, out, "", w);
            return;
        }

        const row = y - Layout.list_top;
        const idx = self.scroll + row / Layout.entry_rows;
        if (idx < self.sessions.items.len) {
            const entry = self.sessions.items[idx];
            const selected = self.selected != null and self.selected.? == idx;
            if (row % Layout.entry_rows == 0) {
                try appendSessionRow(alloc, out, entry, w, selected);
            } else {
                try appendSessionTitleRow(alloc, out, entry, w, selected);
            }
            return;
        }

        try appendClipped(alloc, out, "", w);
    }

    fn composeViewportCell(self: *Ui, y: u16, out: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;

        // Erase before drawing. Erasing afterwards would eat the last
        // cell of a row that touches the terminal's right edge: the
        // cursor rests on that cell in the pending-wrap state, and EL
        // erases from the cursor inclusive.
        try out.appendSlice(alloc, "\x1b[K");

        const v = self.view orelse {
            if (self.sessions.items.len == 0) {
                try self.composeNoSessions(y, out);
            } else if (self.selected != null and self.sessions.items[self.selected.?].attached) {
                try self.composeEmptyRow(y, "attached elsewhere", "click the session to take it over", out);
            } else {
                try self.composeEmptyRow(y, "no session focused", "pick a session on the left", out);
            }
            return;
        };

        switch (v.state) {
            .live => {},
            .stolen => {
                try self.composeEmptyRow(y, "attached elsewhere", "click the session to steal it back", out);
                return;
            },
            .ended, .lost => {
                try self.composeEmptyRow(y, "session ended", "pick another session on the left", out);
                return;
            },
        }

        if (y < v.term.rows) {
            try appendTermRow(alloc, &v.term, y, out);
        }
        try out.appendSlice(alloc, sgr_reset);

        // An in-progress mouse selection is highlighted by repainting
        // the selected cells in reverse video over the row content.
        if (self.selectionSpan(y, v.term.cols)) |span| {
            try out.print(alloc, "\x1b[{d};{d}H", .{
                y + 1,
                self.layout.viewportX() + span.x0 + 1,
            });
            try out.appendSlice(alloc, style_selected);
            try appendPlainSpan(alloc, &v.term, y, span.x0, span.x1, out);
            try out.appendSlice(alloc, sgr_reset);
        }
    }

    fn composeEmptyRow(
        self: *Ui,
        y: u16,
        comptime line1: []const u8,
        comptime line2: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        const l = self.layout;
        const mid = l.viewportRows() / 2;
        const text: []const u8 = if (y == mid)
            line1
        else if (y == mid + 1)
            line2
        else
            return;
        const vw = l.viewportCols();
        if (text.len >= vw) return;
        const pad = (vw - text.len) / 2;
        try out.appendSlice(self.alloc, style_dim);
        for (0..pad) |_| try out.append(self.alloc, ' ');
        try out.appendSlice(self.alloc, text);
        try out.appendSlice(self.alloc, sgr_reset);
    }

    /// The boo wordmark and its ghost, shown when no sessions exist.
    const ghost_art = [_][]const u8{
        " _                     .-.",
        "| |__   ___   ___     (o o)",
        "| '_ \\ / _ \\ / _ \\    | O \\",
        "| |_) | (_) | (_) |    \\   \\",
        "|_.__/ \\___/ \\___/      `~~~'",
    };

    /// Empty state for a boo with no sessions at all: the wordmark
    /// art centered as a block, then a hint underneath.
    fn composeNoSessions(self: *Ui, y: u16, out: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;
        const l = self.layout;
        const vw = l.viewportCols();

        const art_h: u16 = ghost_art.len;
        const total: u16 = art_h + 3; // art, blank, two hint lines
        const top = (l.viewportRows() -| total) / 2;
        if (y < top) return;
        const line = y - top;

        if (line < art_h) {
            var art_w: usize = 0;
            for (ghost_art) |a| art_w = @max(art_w, a.len);
            if (art_w >= vw) return;
            const pad = (vw - art_w) / 2;
            for (0..pad) |_| try out.append(alloc, ' ');
            try out.appendSlice(alloc, ghost_art[line]);
            return;
        }

        const text: []const u8 = switch (line) {
            art_h + 1 => "no sessions",
            art_h + 2 => "Press Ctrl+A for Keybinds",
            else => return,
        };
        if (text.len >= vw) return;
        const pad = (vw - text.len) / 2;
        try out.appendSlice(alloc, style_dim);
        for (0..pad) |_| try out.append(alloc, ' ');
        try out.appendSlice(alloc, text);
        try out.appendSlice(alloc, sgr_reset);
    }
};

/// Append one row of the terminal's active screen as styled VT bytes.
/// Rendered through libghostty's own formatter, so styles, wide
/// characters, and blank runs come out exactly as the daemon would
/// replay them, just one row at a time.
pub fn appendTermRow(
    alloc: std.mem.Allocator,
    term: *vt.Terminal,
    y: u16,
    out: *std.ArrayList(u8),
) !void {
    const screen = term.screens.active;
    if (term.cols == 0) return;
    // Viewport pins follow scrollback paging; at the bottom the
    // viewport and the active screen are the same rows.
    const start = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = y } }) orelse return;
    const end = screen.pages.pin(.{ .viewport = .{ .x = term.cols - 1, .y = y } }) orelse return;

    var formatter: vt.formatter.ScreenFormatter = .init(screen, .vt);
    formatter.content = .{ .selection = vt.Selection.init(start, end, true) };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    aw.writer.print("{f}", .{formatter}) catch return error.OutOfMemory;

    const bytes = aw.writer.buffered();
    try out.appendSlice(alloc, bytes);
    // A row that opened a hyperlink must not leak it into the next
    // row or the sidebar.
    if (std.mem.indexOf(u8, bytes, "\x1b]8;") != null) {
        try out.appendSlice(alloc, "\x1b]8;;\x1b\\");
    }
}

/// Append one row's cells in [x0, x1] inclusive as plain text, with
/// trailing blanks trimmed. Used to repaint the selection highlight
/// over already-rendered row content.
fn appendPlainSpan(
    alloc: std.mem.Allocator,
    term: *vt.Terminal,
    y: u16,
    x0: u16,
    x1: u16,
    out: *std.ArrayList(u8),
) !void {
    const screen = term.screens.active;
    const start = screen.pages.pin(.{ .viewport = .{ .x = x0, .y = y } }) orelse return;
    const end = screen.pages.pin(.{ .viewport = .{ .x = x1, .y = y } }) orelse return;

    var formatter: vt.formatter.ScreenFormatter = .init(screen, .plain);
    formatter.content = .{ .selection = vt.Selection.init(start, end, false) };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    aw.writer.print("{f}", .{formatter}) catch return error.OutOfMemory;
    try out.appendSlice(alloc, aw.writer.buffered());
}

// -- Tests --------------------------------------------------------------------

const TestHandler = struct {
    alloc: std.mem.Allocator,
    events: std.ArrayList(InputEvent) = .empty,
    forwarded: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestHandler) void {
        self.events.deinit(self.alloc);
        self.forwarded.deinit(self.alloc);
    }

    fn event(self: *TestHandler, ev: InputEvent) !void {
        switch (ev) {
            .forward => |bytes| try self.forwarded.appendSlice(self.alloc, bytes),
            else => try self.events.append(self.alloc, ev),
        }
    }
};

test "parser: plain bytes pass through" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("hello", &h);
    try std.testing.expectEqualStrings("hello", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: prefix commands" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("ab\x01cde", &h);
    try std.testing.expectEqualStrings("abde", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 'c' }, h.events.items[0]);
}

test "parser: prefix split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x01", &h);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
    try p.feed("k", &h);
    try std.testing.expectEqual(InputEvent{ .prefix = 'k' }, h.events.items[0]);
}

test "parser: esc backs out of an armed prefix" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x01\x1b", &h);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try std.testing.expect(!p.pending_prefix);
    // The prefix is disarmed: the next byte is plain input again.
    try p.feed("x", &h);
    try std.testing.expectEqualStrings("x", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: a mouse click while the prefix is armed cancels it cleanly" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // Esc with trailing bytes is the start of a sequence, not a lone
    // cancel: the sequence must parse instead of leaking into the pty.
    try p.feed("\x01\x1b[<0;5;7M", &h);
    try std.testing.expect(!p.pending_prefix);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    const m = h.events.items[0].mouse;
    try std.testing.expectEqual(@as(u16, 0), m.code);
    try std.testing.expectEqual(@as(u16, 5), m.x);
    try std.testing.expectEqual(@as(u16, 7), m.y);
    try std.testing.expect(!m.release);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: sgr mouse press and release" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[<0;5;7M\x1b[<0;5;7m", &h);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    const press = h.events.items[0].mouse;
    try std.testing.expectEqual(@as(u16, 0), press.code);
    try std.testing.expectEqual(@as(u16, 5), press.x);
    try std.testing.expectEqual(@as(u16, 7), press.y);
    try std.testing.expect(!press.release);
    try std.testing.expect(h.events.items[1].mouse.release);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: mouse sequence split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[<6", &h);
    try p.feed("5;10;2M", &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    const m = h.events.items[0].mouse;
    try std.testing.expectEqual(@as(u16, 65), m.code);
    try std.testing.expect(m.isWheel());
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: non-intercepted CSI passes through" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[1;5A\x1b[1;5C", &h);
    try std.testing.expectEqualStrings("\x1b[1;5A\x1b[1;5C", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: plain arrows become arrow events" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[A\x1b[B", &h);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .up, .prefixed = false } },
        h.events.items[0],
    );
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .down, .prefixed = false } },
        h.events.items[1],
    );
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: side arrows become arrow events" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[D\x1b[C", &h);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .left, .prefixed = false } },
        h.events.items[0],
    );
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .right, .prefixed = false } },
        h.events.items[1],
    );
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    // A side arrow binds to an armed prefix like up/down do.
    try p.feed("\x01\x1b[C", &h);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .right, .prefixed = true } },
        h.events.items[2],
    );
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: arrows bind to an armed prefix" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x01\x1b[B", &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .down, .prefixed = true } },
        h.events.items[0],
    );
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    // The prefix was consumed: the next bytes are plain input, and a
    // later bare arrow is not marked prefixed.
    try p.feed("x\x1b[A", &h);
    try std.testing.expectEqualStrings("x", h.forwarded.items);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .up, .prefixed = false } },
        h.events.items[1],
    );
}

test "parser: arrow split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[", &h);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
    try p.feed("A", &h);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .up, .prefixed = false } },
        h.events.items[0],
    );
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: bracketed paste protects the prefix byte" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[200~a\x01b\x1b[201~", &h);
    try std.testing.expectEqualStrings("a\x01b", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .paste = true }, h.events.items[0]);
    try std.testing.expectEqual(InputEvent{ .paste = false }, h.events.items[1]);
}

test "parser: focus reports" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[I\x1b[O", &h);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .focus = true }, h.events.items[0]);
    try std.testing.expectEqual(InputEvent{ .focus = false }, h.events.items[1]);
}

test "ui: automatic focus skips attached sessions and prefers recent ones" {
    const alloc = std.testing.allocator;
    var ui: Ui = .{ .alloc = alloc, .dir = "", .tty = -1 };
    defer ui.sessions.deinit(alloc);

    var aa = "aa".*;
    var bb = "bb".*;
    var cc = "cc".*;
    var no_title: [0]u8 = .{};
    try ui.sessions.append(alloc, .{ .name = &aa, .attached = false, .idle_ms = 50, .title = &no_title });
    try ui.sessions.append(alloc, .{ .name = &bb, .attached = true, .idle_ms = 10, .title = &no_title });
    try ui.sessions.append(alloc, .{ .name = &cc, .attached = false, .idle_ms = 90, .title = &no_title });

    // bb is the most recent but held elsewhere; aa wins among the free.
    try std.testing.expectEqual(@as(?usize, 0), ui.autoFocusable());

    // The session hosting this UI is never an automatic candidate.
    ui.host_name = "aa";
    try std.testing.expectEqual(@as(?usize, 2), ui.autoFocusable());

    // Every session held elsewhere: nothing to attach automatically.
    ui.host_name = null;
    ui.sessions.items[0].attached = true;
    ui.sessions.items[2].attached = true;
    try std.testing.expectEqual(@as(?usize, null), ui.autoFocusable());
}

test "ui: search matches prefer name prefixes over substrings" {
    const alloc = std.testing.allocator;
    var ui: Ui = .{ .alloc = alloc, .dir = "", .tty = -1 };
    defer ui.sessions.deinit(alloc);

    var build = "build".*;
    var debug = "debug".*;
    var ugly = "ugly".*;
    var no_title: [0]u8 = .{};
    try ui.sessions.append(alloc, .{ .name = &build, .attached = false, .idle_ms = 0, .title = &no_title });
    try ui.sessions.append(alloc, .{ .name = &debug, .attached = false, .idle_ms = 0, .title = &no_title });
    try ui.sessions.append(alloc, .{ .name = &ugly, .attached = false, .idle_ms = 0, .title = &no_title });

    // A prefix match wins even when an earlier name contains the query.
    try std.testing.expectEqual(@as(?usize, 2), ui.searchMatch("ug"));
    // Substring fallback, case-insensitive.
    try std.testing.expectEqual(@as(?usize, 0), ui.searchMatch("UILD"));
    try std.testing.expectEqual(@as(?usize, 1), ui.searchMatch("deb"));
    // No match and empty queries select nothing.
    try std.testing.expectEqual(@as(?usize, null), ui.searchMatch("zzz"));
    try std.testing.expectEqual(@as(?usize, null), ui.searchMatch(""));
}

test "layout: geometry and hit testing" {
    const l = Layout.init(24, 100);
    try std.testing.expectEqual(@as(u16, 24), l.sidebar_w);
    try std.testing.expectEqual(@as(u16, 75), l.viewportCols());
    try std.testing.expectEqual(@as(u16, 25), l.viewportX());
    try std.testing.expectEqual(@as(u16, 24), l.viewportRows());
    try std.testing.expectEqual(@as(usize, 10), l.visibleEntries());

    // The new-session button is the top row and a blank gap sits
    // under it. The bottom sidebar row holds the keybind hint, and
    // the viewport extends through the last row.
    try std.testing.expectEqual(Layout.Hit.new_button, l.hit(3, 0));
    try std.testing.expectEqual(Layout.Hit.none, l.hit(3, 1));
    try std.testing.expectEqual(Layout.Hit.none, l.hit(3, 23));
    const bottom = l.hit(80, 23);
    try std.testing.expectEqual(@as(u16, 55), bottom.viewport.x);
    try std.testing.expectEqual(@as(u16, 23), bottom.viewport.y);
    try std.testing.expectEqual(Layout.Hit.none, l.hit(24, 5)); // separator
    try std.testing.expectEqual(Layout.Hit.none, l.hit(24, 23)); // separator, last row

    // Sessions take two display rows: name, then title.
    const s = l.hit(3, 5);
    try std.testing.expectEqual(@as(u16, 3), s.session.row);
    try std.testing.expect(!s.session.kill);
    const k = l.hit(22, 4);
    try std.testing.expectEqual(@as(u16, 2), k.session.row);
    try std.testing.expect(k.session.kill);

    const v = l.hit(30, 7);
    try std.testing.expectEqual(@as(u16, 5), v.viewport.x);
    try std.testing.expectEqual(@as(u16, 7), v.viewport.y);

    try std.testing.expectEqual(Layout.Hit.none, l.hit(100, 5));
}

test "ui: sidebar resize clamps to the layout bounds" {
    var ui: Ui = .{
        .alloc = std.testing.allocator,
        .dir = "",
        .tty = -1,
    };
    ui.layout = .{ .rows = 24, .cols = 100, .sidebar_w = 24 };

    // The width stays between the narrow-terminal floor and a cap
    // that keeps the viewport usable.
    try std.testing.expectEqual(@as(u16, 8), ui.clampSidebarWidth(0));
    try std.testing.expectEqual(@as(u16, 8), ui.clampSidebarWidth(-5));
    try std.testing.expectEqual(@as(u16, 30), ui.clampSidebarWidth(30));
    try std.testing.expectEqual(@as(u16, 88), ui.clampSidebarWidth(999));

    // Tiny terminals collapse the range to the floor.
    ui.layout.cols = 15;
    try std.testing.expectEqual(@as(u16, 8), ui.clampSidebarWidth(999));
}

test "layout: narrow terminals shrink the sidebar" {
    const l = Layout.init(24, 48);
    try std.testing.expectEqual(@as(u16, 16), l.sidebar_w);
    try std.testing.expect(l.viewportCols() > 0);
}

test "sidebar session row is exactly the requested width" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var name_buf: [8]u8 = "work1234".*;
    var title_buf: [0]u8 = .{};
    const entry: Entry = .{
        .name = &name_buf,
        .attached = false,
        .idle_ms = 12_000,
        .title = &title_buf,
    };

    // An idle row is pure ASCII: exactly `width` columns and bytes.
    try appendSessionRow(alloc, &out, entry, 24, false);
    const text = out.items[0 .. out.items.len - sgr_reset.len];
    try std.testing.expectEqual(@as(usize, 24), text.len);
    try std.testing.expect(std.mem.indexOf(u8, text, "work1234") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "x "));

    // Selected rows are wrapped in inverse video; the highlight is
    // the only selection marker.
    out.clearRetainingCapacity();
    try appendSessionRow(alloc, &out, entry, 24, true);
    try std.testing.expect(std.mem.startsWith(u8, out.items, style_selected));
    try std.testing.expect(std.mem.indexOf(u8, out.items, ">") == null);
}

test "sidebar title row renders the title dim under the name" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var name_buf: [4]u8 = "work".*;
    var title_buf: [9]u8 = "vim notes".*;
    const entry: Entry = .{
        .name = &name_buf,
        .attached = false,
        .idle_ms = 0,
        .title = &title_buf,
    };

    try appendSessionTitleRow(alloc, &out, entry, 24, false);
    try std.testing.expect(std.mem.startsWith(u8, out.items, style_dim));
    const text = out.items[style_dim.len .. out.items.len - sgr_reset.len];
    try std.testing.expectEqual(@as(usize, 24), text.len);
    try std.testing.expectEqualStrings("  vim notes", std.mem.trimRight(u8, text, " "));

    // Without a title the row is blank but still full width.
    var no_title: [0]u8 = .{};
    var bare = entry;
    bare.title = &no_title;
    out.clearRetainingCapacity();
    try appendSessionTitleRow(alloc, &out, bare, 24, false);
    const blank = out.items[style_dim.len .. out.items.len - sgr_reset.len];
    try std.testing.expectEqual(@as(usize, 24), blank.len);
    try std.testing.expectEqual(@as(usize, 0), std.mem.trim(u8, blank, " ").len);
}

test "appendTermRow renders styled content for one row only" {
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init(alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("first\r\n  \x1b[1;31mred\x1b[0m end");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendTermRow(alloc, &term, 0, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "red") == null);

    out.clearRetainingCapacity();
    try appendTermRow(alloc, &term, 1, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "first") == null);
    // Leading blanks are preserved so columns line up.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "  ") != null);
    // The row carries SGR styling for the red word.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[") != null);

    // Blank rows render as nothing (the caller clears with EL).
    out.clearRetainingCapacity();
    try appendTermRow(alloc, &term, 3, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
