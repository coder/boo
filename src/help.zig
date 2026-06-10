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
    \\  With no arguments, boo prints this overview.
    \\
    \\commands:
    \\  new [name] [-d] [-- cmd...]  start a session (attach unless -d)
    \\  attach, at [name]            attach a session (steals politely)
    \\  ls [--json]                  list sessions
    \\  send [-s name] [text]        type into a session
    \\  peek [name]                  print the session's screen
    \\  wait [name]                  block until output matches or settles
    \\  kill [name | --all]          end a session
    \\  exorcise                     end every session
    \\  version                      print the version
    \\  help [command | topic]       this overview, or detailed help
    \\
    \\topics:
    \\  keys        the C-a key bindings inside a session
    \\  automation  driving boo from scripts and AI agents
    \\
    \\Run 'boo help <command>' for flags and examples, or
    \\'boo help --all' to print every page at once.
    \\
    \\session selection:
    \\  Commands taking [name] accept a unique prefix of the session
    \\  name. With no name, the only session is used, or the most
    \\  recently active one for read-only commands; commands that
    \\  destroy state never guess between multiple sessions.
    \\
    \\environment:
    \\  BOO_DIR  socket directory
    \\           (default: $XDG_RUNTIME_DIR/boo, else /tmp/boo-<uid>)
    \\  BOO_LOG  append daemon logs to this file (debugging)
    \\
    \\exit codes:
    \\  0 success    1 error    2 usage error
    \\  3 no such session       4 wait timed out
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
        \\usage: boo attach [name]
        \\       boo at [name]
        \\
        \\Attach this terminal to a session. The screen, scrollback,
        \\cursor, and title are restored from terminal state. If the
        \\session is attached elsewhere, the other client is detached
        \\(the session is stolen).
        \\
        \\With no name: the only session, or the most recently active
        \\one. A unique prefix of a name is accepted.
        \\
        \\Inside the session, press C-a d to detach. See 'boo help
        \\keys' for all bindings.
        \\
        \\examples:
        \\  boo attach           grab the most recent session
        \\  boo at bu            attach "build" by prefix
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
        \\usage: boo send [-s session] [text] [flags]
        \\
        \\Type into a session, exactly as if the text had been typed
        \\at the keyboard. Text is sent literally: no escape
        \\processing and no implicit newline, so there is never a
        \\quoting layer to fight. With no text and no --key, bytes
        \\are read from stdin (binary safe, NUL excluded).
        \\
        \\flags:
        \\  -s <session>  target session (default: only/most recent)
        \\  --enter       append Enter after everything else
        \\  --key <list>  send named keys, comma separated:
        \\                Enter, Tab, Escape, Space, Backspace,
        \\                Up, Down, Left, Right, Home, End, C-a..C-z.
        \\                Cannot be combined with text; use two calls.
        \\  --stdin       force reading from stdin
        \\
        \\examples:
        \\  boo send 'make test' --enter       run a command
        \\  boo send -s build 'make' --enter   ...in session "build"
        \\  boo send --key C-c                 interrupt the program
        \\  printf 'y\n' | boo send -s build   pipe bytes in
        \\
        ,
    },
    .{
        .name = "peek",
        .body =
        \\usage: boo peek [name] [--scrollback] [--json]
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
        \\usage: boo wait [name] (--for <text> | --idle <dur>) [--timeout <dur>]
        \\
        \\Block until something happens in the session, then exit 0.
        \\Replaces sleep-and-poll loops in scripts.
        \\
        \\flags:
        \\  --for <text>     until the rendered screen contains <text>
        \\                   (plain substring match)
        \\  --idle <dur>     until the session has produced no output
        \\                   for <dur>
        \\  --timeout <dur>  give up and exit 4 (default: 30s)
        \\
        \\Durations are an integer with a unit: 500ms, 2s, 1m.
        \\
        \\examples:
        \\  boo wait build --for 'PASS' --timeout 2m
        \\  boo wait build --idle 2s && boo peek build
        \\
        ,
    },
    .{
        .name = "kill",
        .body =
        \\usage: boo kill [name | --all]
        \\
        \\End a session: its process receives SIGHUP and the daemon
        \\exits. With multiple sessions a name is required unless
        \\--all is given (also available as 'boo exorcise').
        \\
        \\examples:
        \\  boo kill build
        \\  boo kill --all
        \\
        ,
    },
    .{
        .name = "exorcise",
        .body =
        \\usage: boo exorcise
        \\
        \\Banish every session on this machine. The thorough form of
        \\'boo kill --all': each session is terminated and stale
        \\sockets are swept away. No ghost survives.
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
        \\usage: boo help [command | topic] [--all]
        \\
        \\Show the overview, a command's detailed help, or a topic
        \\page ('keys', 'automation'). --all prints every page in one
        \\pass, which is handy for piping into a pager or for tools
        \\that want to learn the whole CLI in one call.
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
        \\  boo new build -d -- bash           # 1. headless session
        \\  boo send -s build 'make' --enter   # 2. type into it
        \\  boo wait build --idle 2s           # 3. let output settle
        \\  boo peek build --scrollback        # 4. read the screen
        \\  boo kill build                     # 5. clean up
        \\
        \\reading state:
        \\  peek prints the rendered screen, not a raw byte stream:
        \\  ordered, fully redrawn, and stable. --scrollback includes
        \\  history; --json adds size, cursor, and title.
        \\
        \\waiting (instead of sleep):
        \\  boo wait <name> --for <text>   screen contains <text>
        \\  boo wait <name> --idle <dur>   output quiet for <dur>
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
