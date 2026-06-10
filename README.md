# ghostscreen

A GNU `screen` style terminal multiplexer built on
[libghostty](https://github.com/ghostty-org/ghostty) (`libghostty-vt`),
written in Zig.

Every window's output is parsed through Ghostty's terminal emulation
core, so ghostscreen always knows the exact screen state of every
window: contents, styles, cursor, scrollback, and terminal modes. That
state is used to rehydrate your terminal on attach and window switches,
to answer terminal queries for background windows, and to produce
plain-text hardcopies.

## Features

- Sessions that survive disconnects: detach with `C-a d`, reattach with
  `ghostscreen -r`.
- Multiple windows per session with screen-style `C-a` key bindings.
- Faithful redraws from libghostty terminal state, including SGR styles,
  cursor position, scrolling regions, and terminal modes (alt screen,
  bracketed paste, mouse reporting, kitty keyboard, ...).
- Scriptable control commands (`-X`), including `stuff` and `hardcopy`.
- Resize propagation end to end (SIGWINCH -> client -> daemon -> window
  PTY -> application).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/coder/ghostscreen/main/install.sh | sh
```

Pre-built binaries for Linux (x86_64, aarch64; fully static) and macOS
(x86_64, aarch64) are published on the
[releases page](https://github.com/coder/ghostscreen/releases). Set
`GHOSTSCREEN_VERSION` to pin a release and `GHOSTSCREEN_INSTALL_DIR` to
change the install location (default: `/usr/local/bin` when writable,
otherwise `~/.local/bin`).

## Building

Requires [Zig](https://ziglang.org) 0.15.2.

```sh
zig build                       # binary in zig-out/bin/ghostscreen
zig build test                  # unit tests
zig build test-integration     # end-to-end tests on a real PTY
zig build test-all             # everything
```

The libghostty dependency is fetched and built from source
automatically (pinned in `build.zig.zon`).

## Usage

```sh
ghostscreen                   # new session running $SHELL, attached
ghostscreen htop              # new session running a command
ghostscreen -S work           # named session
ghostscreen -d -m -S work     # create detached
ghostscreen -ls               # list sessions
ghostscreen -r work           # reattach (steals if attached elsewhere)
ghostscreen -S work -X stuff 'echo hi\n'        # type into the session
ghostscreen -S work -X hardcopy /tmp/screen.txt # dump screen as text
```

### Key bindings (prefix `C-a`)

| Keys      | Action                              |
|-----------|-------------------------------------|
| `C-a c`   | new window                          |
| `C-a n` / `C-a p` / `C-a <space>` | next / previous window |
| `C-a 0`..`C-a 9` | select window by number      |
| `C-a C-a` | toggle to the previously used window |
| `C-a d`   | detach                              |
| `C-a k`   | kill the current window             |
| `C-a w`   | list windows in the message line    |
| `C-a l`   | redraw                              |
| `C-a a`   | send a literal `C-a`                |

### Control commands (`-X`)

`stuff <text>` (with `\n \r \t \e \xHH` escapes), `hardcopy <path>`,
`new-window [cmd ...]`, `select <n>`, `next`, `prev`, `windows`,
`kill-window`, `info`, `quit`.

### Environment

- `GHOSTSCREEN_DIR`: socket directory (default
  `$XDG_RUNTIME_DIR/ghostscreen`, else `/tmp/ghostscreen-<uid>`).
- `GHOSTSCREEN_LOG`: daemon log file (daemon logging is otherwise
  discarded).

## Architecture

```
your terminal <-(raw tty)-> ghostscreen client <-(unix socket)-> session daemon
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
