//! All user-facing help text: the overview, per-command help, and
//! topic pages. Kept in one place so the CLI surface reads as a whole
//! and stays consistent.

pub const Entry = struct {
    /// Primary command or topic name.
    name: []const u8,
    /// Optional short alias (e.g. `at` for `attach`).
    alias: ?[]const u8 = null,
    /// Full help text printed by `boo help <name>`.
    body: []const u8,
};

pub const overview =
    \\boo: sessions that haunt your terminal
    \\
    \\A terminal multiplexer in the spirit of GNU screen, built on
    \\libghostty. Sessions keep running when you disconnect; reattach
    \\and the screen, scrollback, and title come back exactly as a
    \\human would see them.
    \\
    \\usage:
    \\  boo <command> [arguments]
    \\
    \\commands:
    \\  new [name] [-d] [-- cmd...]  start a session (attach unless -d)
    \\  attach, at, a <name>         attach a session (steals politely)
    \\  ui, i                        manage sessions in a full-screen UI
    \\  ls [--json]                  list sessions
    \\  send <name> [flags]          type into a session
    \\  peek <name>                  print the session's screen
    \\  wait <name>                  block until output matches or settles
    \\  kill <name | --all>          end a session, or all of them
    \\  rename <name> <new-name>     rename a session
    \\  version                      print the version
    \\  help [page]                  this overview, or detailed help
    \\
    \\Run 'boo help <command>' for flags and examples, 'boo help keys'
    \\for the key bindings inside a session, 'boo help automation' for
    \\driving boo from scripts, or 'boo help --all' for every page.
    \\
    \\session selection:
    \\  Commands taking <name> accept a unique prefix of the session
    \\  name (e.g. 'boo attach bu' for "build").
    \\
    \\environment:
    \\  BOO_DIR  socket directory
    \\           (default: $XDG_RUNTIME_DIR/boo, else /tmp/boo-<uid>)
    \\  BOO_LOG  append daemon logs to this file (debugging)
    \\
;

pub const commands = [_]Entry{
    .{
        .name = "new",
        .body =
        \\usage: boo new [name] [-d|--detached] [-- cmd...]
        \\
        \\Start a session running cmd (default: $SHELL) and attach to
        \\it. The session keeps running after you detach (C-a d) or
        \\lose the connection.
        \\
        \\Names may contain letters, digits, '.', '_', and '-'. The
        \\default name is the name of the current directory, or the
        \\process id when that name is taken or unusable. Everything
        \\after '--' is the command to run in the session.
        \\
        \\flags:
        \\  -d, --detached  start without attaching and print the
        \\                  session name on stdout
        \\
        \\examples:
        \\  boo new                      interactive shell, attach now
        \\  boo new work                 named session
        \\  boo new build -d -- make -j  background a build
        \\
        ,
    },
    .{
        .name = "attach",
        .alias = "at",
        .body =
        \\usage: boo attach <name>
        \\       boo at <name>
        \\       boo a <name>
        \\
        \\Attach this terminal to a session. The screen, scrollback,
        \\cursor, and title are restored from terminal state. If the
        \\session is attached elsewhere, the other client is detached
        \\(the session is stolen).
        \\
        \\A unique prefix of the name is accepted.
        \\
        \\Inside the session, press C-a d to detach. See 'boo help
        \\keys' for all bindings.
        \\
        \\examples:
        \\  boo attach build     reattach "build"
        \\  boo at bu            the same, by prefix
        \\
        ,
    },
    .{
        .name = "ui",
        .alias = "i",
        .body =
        \\usage: boo ui
        \\       boo i
        \\
        \\Manage sessions in a full-screen interface: a sidebar lists
        \\every session (window title underneath) and the focused
        \\session runs in a viewport on the right, rendered live from
        \\terminal state.
        \\
        \\mouse:
        \\  click a session     focus it (steals politely, like attach)
        \\  click its 'x'       kill it (asks for confirmation)
        \\  scroll the sidebar  scroll the session list
        \\  wheel in viewport   scroll the session's history; wheel
        \\                      back down or press esc to return to
        \\                      live output (full-screen applications
        \\                      receive arrow keys instead)
        \\  in the viewport     forwarded to the application when it
        \\                      asked for mouse reporting; otherwise
        \\                      dragging selects text and copies it on
        \\                      release (OSC 52)
        \\
        \\keys (prefix C-a, control variants match GNU screen):
        \\  C-a c   create a session and focus it
        \\  C-a k   kill the focused session (asks y/n)
        \\  C-a r   rename the focused session
        \\  C-a g   go to a session by name (best match)
        \\  C-a n   focus the next session
        \\  C-a p   focus the previous session
        \\  C-a Up, C-a Down
        \\          browse the session list without attaching:
        \\          Up/Down move the selection, Enter attaches it,
        \\          Esc returns to the focused session
        \\  C-a Left, C-a Right
        \\          resize the sidebar: Left/Right adjust the width,
        \\          Enter keeps it, Esc restores the previous width
        \\  C-a C-a focus the previously focused session
        \\  C-a d   quit the UI (sessions keep running)
        \\  C-a l   redraw
        \\  C-a a   send a literal C-a to the application
        \\  C-a Esc cancel the armed prefix
        \\
        \\Pressing C-a alone lists these bindings in the bottom bar.
        \\
        \\Everything else is typed into the focused session. Unlike a
        \\plain attach, pasted text may contain C-a bytes safely
        \\(bracketed paste).
        \\
        ,
    },
    .{
        .name = "ls",
        .alias = "list",
        .body =
        \\usage: boo ls [--json]
        \\
        \\List sessions: name, attach state, idle time (time since the
        \\last output or client input), and the session's title. Stale
        \\sockets left by crashed daemons are cleaned up.
        \\
        \\flags:
        \\  --json  emit a JSON array:
        \\          [{"name","attached","idle_ms","title"}]
        \\
        ,
    },
    .{
        .name = "send",
        .body =
        \\usage: boo send <name> [--text <text>] [--key <list>] [flags]
        \\
        \\Type into a session, exactly as if the text had been typed
        \\at the keyboard. --text is sent literally: no escape
        \\processing and no implicit newline, so there is never a
        \\quoting layer to fight. With neither --text nor --key,
        \\bytes are read from stdin (binary safe, NUL excluded).
        \\
        \\flags:
        \\  --text <text>  the text to type
        \\  --enter        append Enter after everything else
        \\  --key <list>   send named keys, comma separated:
        \\                 Enter, Tab, Escape, Space, Backspace,
        \\                 Up, Down, Left, Right, Home, End, C-a..C-z.
        \\                 Cannot be combined with --text; use two calls.
        \\  --stdin        force reading from stdin
        \\
        \\examples:
        \\  boo send build --text 'make test' --enter   run a command
        \\  boo send build --key C-c                    interrupt it
        \\  printf 'y\n' | boo send build               pipe bytes in
        \\
        ,
    },
    .{
        .name = "peek",
        .body =
        \\usage: boo peek <name> [--scrollback] [--json]
        \\
        \\Print the session's rendered screen: what a human attached
        \\right now would see, reconstructed from terminal state (not
        \\a raw byte log). Safe to run while attached.
        \\
        \\flags:
        \\  --scrollback  include the full scrollback history
        \\  --json        emit {"session","title","rows","cols",
        \\                "cursor":{"row","col"},"screen"}
        \\
        \\examples:
        \\  boo peek build | tail -20
        \\  boo peek build --scrollback | grep -n error
        \\
        ,
    },
    .{
        .name = "wait",
        .body =
        \\usage: boo wait <name> (--text <text> | --idle) [--timeout <dur>]
        \\
        \\Block until something happens in the session, then exit 0.
        \\Replaces sleep-and-poll loops in scripts.
        \\
        \\flags:
        \\  --text <text>    until the rendered screen contains <text>
        \\                   (plain substring match)
        \\  --idle           until the session has produced no output
        \\                   for 2 seconds
        \\  --timeout <dur>  give up and exit 4 (default: 30s)
        \\
        \\Durations are an integer with a unit: 500ms, 2s, 1m, 4h
        \\(or 4hr), 1d. Flags also accept --flag=value.
        \\
        \\examples:
        \\  boo wait build --text 'PASS' --timeout 2m
        \\  boo wait build --idle && boo peek build
        \\
        ,
    },
    .{
        .name = "kill",
        .body =
        \\usage: boo kill <name | --all>
        \\
        \\End a session: its process receives SIGHUP and the daemon
        \\exits. --all ends every session and sweeps stale sockets.
        \\
        \\examples:
        \\  boo kill build
        \\  boo kill --all
        \\
        ,
    },
    .{
        .name = "rename",
        .body =
        \\usage: boo rename <name> <new-name>
        \\
        \\Rename a session. The running program is unaffected and an
        \\attached client stays attached. The old name accepts a
        \\unique prefix, like attach.
        \\
        \\example:
        \\  boo rename work api-server
        \\
        ,
    },
    .{
        .name = "version",
        .body =
        \\usage: boo version
        \\
        \\Print the boo version. Also available as -V or --version.
        \\
        ,
    },
    .{
        .name = "help",
        .body =
        \\usage: boo help [page] [--all]
        \\
        \\Show the overview or a detailed page. There is a page for
        \\every command, plus 'keys' (the C-a bindings inside a
        \\session) and 'automation' (driving boo from scripts and AI
        \\agents). --all prints every page in one pass, which is handy
        \\for piping into a pager or for tools that want to learn the
        \\whole CLI in one call.
        \\
        ,
    },
};

pub const topics = [_]Entry{
    .{
        .name = "keys",
        .body =
        \\Key bindings inside an attached session (prefix C-a)
        \\
        \\  C-a d   detach
        \\  C-a l   redraw
        \\  C-a a   send a literal C-a
        \\
        \\Control variants match GNU screen: C-a C-d detaches and
        \\C-a C-l redraws. Detaching leaves the session running;
        \\'boo attach' brings it back.
        \\
        \\'boo ui' adds bindings for managing sessions; see
        \\'boo help ui'.
        \\
        ,
    },
    .{
        .name = "automation",
        .body =
        \\Driving boo from scripts and AI agents
        \\
        \\Everything except 'attach' works without a terminal. The
        \\canonical loop:
        \\
        \\  boo new build -d -- bash               # 1. headless session
        \\  boo send build --text 'make' --enter   # 2. type into it
        \\  boo wait build --idle                  # 3. let output settle
        \\  boo peek build --scrollback            # 4. read the screen
        \\  boo kill build                         # 5. clean up
        \\
        \\reading state:
        \\  peek prints the rendered screen, not a raw byte stream:
        \\  ordered, fully redrawn, and stable. --scrollback includes
        \\  history; --json adds size, cursor, and title.
        \\
        \\waiting (instead of sleep):
        \\  boo wait <name> --text <text>   screen contains <text>
        \\  boo wait <name> --idle          output quiet for 2 seconds
        \\  boo wait <name> ... --timeout <dur>   exit 4 on timeout
        \\
        \\sending input:
        \\  send is literal: no escapes, no implicit newline, no
        \\  quoting layer. --enter submits; --key Enter,C-c,Up names
        \\  control keys; stdin mode is binary safe.
        \\
        \\machine-readable output:
        \\  boo ls --json    [{"name","attached","idle_ms","title"}]
        \\  boo peek --json  {"session","title","rows","cols",
        \\                    "cursor":{"row","col"},"screen"}
        \\
        \\exit codes:
        \\  0 success    1 error    2 usage error
        \\  3 no such session       4 wait timed out
        \\
        \\tips:
        \\  - Sessions are cheap; use one session per task.
        \\  - 'boo new -d' prints the session name on stdout.
        \\  - Pick unique session names so [name] prefixes stay
        \\    unambiguous.
        \\
        ,
    },
};

pub fn find(name: []const u8) ?*const Entry {
    const eql = @import("std").mem.eql;
    for (&commands) |*entry| {
        if (eql(u8, entry.name, name)) return entry;
        if (entry.alias) |alias| {
            if (eql(u8, alias, name)) return entry;
        }
    }
    for (&topics) |*entry| {
        if (eql(u8, entry.name, name)) return entry;
    }
    return null;
}
