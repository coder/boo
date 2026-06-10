# boo

Sessions that haunt your terminal. A GNU `screen` style terminal
multiplexer built on [libghostty](https://github.com/ghostty-org/ghostty)
(`libghostty-vt`), written in Zig.

Every window's output is parsed through Ghostty's terminal emulation
core, so boo always knows the exact screen state of every window:
contents, styles, cursor, scrollback, and terminal modes. That state is
used to rehydrate your terminal on attach and window switches, to
answer terminal queries for background windows, and to let scripts and
AI agents read the screen exactly as a human would see it.

## Features

- Sessions that survive disconnects: detach with `C-a d`, reattach with
  `boo attach`.
- Multiple windows per session with screen-style `C-a` key bindings.
- Faithful redraws from libghostty terminal state, including SGR styles,
  cursor position, scrolling regions, window title, and terminal modes
  (alt screen, bracketed paste, mouse reporting, kitty keyboard, ...).
- Screen-style terminal etiquette: the attached client renders inside
  your terminal's alternate screen, so attaching never disturbs your
  shell scrollback and detaching restores your pre-attach view.
  Alternate-screen switches by apps inside a window are tracked in
  terminal state and repainted, never passed through raw.
- Agent-friendly automation primitives: `send`, `peek`, `wait`, and
  `--json` output, all usable without a terminal.
- Resize propagation end to end (SIGWINCH -> client -> daemon -> window
  PTY -> application).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/coder/boo/main/install.sh | sh
```

Pre-built binaries for Linux (x86_64, aarch64; fully static) and macOS
(x86_64, aarch64) are published on the
[releases page](https://github.com/coder/boo/releases). Set
`BOO_VERSION` to pin a release and `BOO_INSTALL_DIR` to change the
install location (default: `/usr/local/bin` when writable, otherwise
`~/.local/bin`).

## Building

Requires [Zig](https://ziglang.org) 0.15.2.

```sh
zig build                       # binary in zig-out/bin/boo
zig build test                  # unit tests
zig build test-integration     # end-to-end tests on a real PTY
zig build test-all             # everything
```

The libghostty dependency is fetched and built from source
automatically (pinned in `build.zig.zon`).

## Usage

```sh
boo                        # attach the most recent session, or start one
boo new                    # new session running $SHELL, attached
boo new work               # named session
boo new work -d -- make    # create detached, running a command
boo ls                     # list sessions
boo attach work            # reattach (steals if attached elsewhere)
boo at w                   # same: alias + unique-prefix matching
boo kill work              # end a session
boo exorcise               # end every session
```

Run `boo help` for the full overview, `boo help <command>` for flags
and examples, and `boo help --all` to print every help page at once.

### Key bindings (prefix `C-a`)

Bindings follow GNU screen's defaults, including the `C-x` variants
(`C-a C-d` detaches just like `C-a d`).

| Keys      | Action                              |
|-----------|-------------------------------------|
| `C-a c`, `C-a C-c` | new window                 |
| `C-a n` / `C-a p` / `C-a <space>` | next / previous window |
| `C-a 0`..`C-a 9` | select window by number      |
| `C-a C-a` | toggle to the previously used window |
| `C-a d`, `C-a C-d` | detach                     |
| `C-a k`, `C-a C-k` | kill the current window    |
| `C-a w`, `C-a C-w` | list windows in the message line |
| `C-a l`, `C-a C-l` | redraw                     |
| `C-a a`   | send a literal `C-a`                |

## Automation

Everything except `attach` works without a terminal, which makes boo a
natural sandbox for scripts and AI agents driving interactive programs.
The canonical loop:

```sh
boo new build -d -- bash           # 1. headless session
boo send -s build 'make' --enter   # 2. type into it
boo wait build --idle 2s           # 3. let output settle
boo peek build --scrollback        # 4. read the screen
boo kill build                     # 5. clean up
```

- **Reading state**: `peek` prints the rendered screen reconstructed
  from terminal state, not a raw byte log: ordered, fully redrawn, and
  stable. `--scrollback` includes history; `--json` adds size, cursor,
  window id, and title.
- **Waiting**: `wait --for <text>` blocks until the screen contains the
  text; `wait --idle <dur>` until output settles; `--timeout <dur>`
  exits 4 instead of hanging forever. No more sleep-and-poll loops.
- **Sending input**: `send` is literal: no escape processing, no
  implicit newline, no quoting layer to fight. `--enter` submits,
  `--key Enter,C-c,Up` names control keys, and stdin mode is binary
  safe.
- **Machine-readable output**: `ls --json`, `windows --json`, and
  `peek --json`.
- **Exit codes**: `0` success, `1` error, `2` usage error, `3` no such
  session, `4` wait timed out.

See `boo help automation` for the full page.

### Environment

- `BOO_DIR`: socket directory (default `$XDG_RUNTIME_DIR/boo`, else
  `/tmp/boo-<uid>`).
- `BOO_LOG`: daemon log file (daemon logging is otherwise discarded).

## Architecture

```
your terminal <-(raw tty)-> boo client <-(unix socket)-> session daemon
                                                         |- window 0: PTY + ghostty-vt Terminal
                                                         |- window 1: PTY + ghostty-vt Terminal
                                                         `- ...
```

- The **client** puts your TTY in raw mode and shuttles bytes over a
  framed Unix-socket protocol (`src/protocol.zig`).
- The **daemon** (forked on session creation) owns the windows. Each
  window is a PTY-attached child whose output feeds a persistent
  `ghostty-vt` `TerminalStream` (`src/window.zig`).
- The **active window** is passed through to your terminal byte for
  byte. On attach and window switches the daemon sanitizes your
  terminal and replays the window from libghostty state using its VT
  `TerminalFormatter`.
- Terminal queries (DSR, DA, XTWINOPS, ...) from background or detached
  windows are answered by libghostty's stream handler; for the active
  passthrough window your real terminal answers, avoiding double
  replies.

## Caveats

This is a young project, not a drop-in GNU screen replacement:

- One attached client per session (attaching steals); no `-x` sharing.
- The `C-a` prefix is not yet configurable, and pasted bytes containing
  `0x01` are interpreted as the prefix (GNU screen has the same quirk).
- No status line, monitoring, copy mode, or split regions yet.
- Windows run with `TERM=xterm-256color`.

## License

[MIT](LICENSE). Ghostty itself is MIT licensed.
