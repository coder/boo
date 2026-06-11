<div align="center">
<pre>
 _                     .-.
 | |__   ___   ___     (o o)
 | '_ \ / _ \ / _ \    | O \
  | |_) | (_) | (_) |    \   \
   |_.__/ \___/ \___/      `~~~'
</pre>

Sessions that haunt your terminal.

[Install](#install) | [Usage](#usage) | [Automation](#automation) | [Architecture](#architecture)

[![ci](https://github.com/coder/boo/actions/workflows/ci.yml/badge.svg)](https://github.com/coder/boo/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/coder/boo)](https://github.com/coder/boo/releases/latest)
[![license](https://img.shields.io/github/license/coder/boo)](./LICENSE)
[![discord](https://img.shields.io/discord/747933592273027093?label=discord)](https://discord.gg/coder)

</div>

A GNU `screen` style terminal multiplexer built on
[libghostty](https://github.com/ghostty-org/ghostty)
(`libghostty-vt`), written in Zig.

Every session's output is parsed through Ghostty's terminal emulation
core, so boo always knows the exact screen state of every session:
contents, styles, cursor, scrollback, and terminal modes. That state is
used to rehydrate your terminal on attach, to answer terminal queries
for detached sessions, and to let scripts and AI agents read the screen
exactly as a human would see it.

## Features

- Sessions that survive disconnects: detach with `Ctrl-A d`, reattach with `boo attach`.
- A full-screen session manager: `boo ui` lists sessions in a sidebar.
- Faithful redraws from libghostty terminal state, including SGR styles, cursor position, scrolling regions, window title, and terminal modes.
- Agent-friendly automation primitives: `send`, `peek`, `wait`, and `--json` output, all usable without a TTY.

## Install

For Linux and macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/coder/boo/main/install.sh | sh
```

Pre-built binaries are published on the [releases page](https://github.com/coder/boo/releases). Set `BOO_VERSION` to pin a release and `BOO_INSTALL_DIR` to change the
install location (default: `/usr/local/bin` when writable, otherwise
`~/.local/bin`).

## Usage

```sh
boo new                    # new session running $SHELL, attached
boo new work               # named session
boo new work -d -- make    # create detached, running a command
boo ui                     # manage sessions in a full-screen UI (alias: i)
boo ls                     # list sessions
boo attach work            # reattach (alias: at, a)
boo rename work api        # rename a session
boo kill work              # end a session
boo kill --all             # end every session
```

With no name, `boo new` names the session after the current directory,
falling back to the process id when that name is taken or unusable.

Run `boo help` for the full overview, `boo help <command>` for flags
and examples, and `boo help --all` to print every help page at once.

### Key bindings (prefix `Ctrl-a`)

Bindings follow GNU screen's defaults, including the `C-x` variants
(`C-a C-d` detaches just like `C-a d`).

| Keys      | Action                              |
|-----------|-------------------------------------|
| `C-a d`, `C-a C-d` | detach                     |
| `C-a l`, `C-a C-l` | redraw                     |
| `C-a a`   | send a literal `C-a`                |

`boo ui` adds additional keybinds for switching, resizing, creating sessions, and killing them.

### Automation

Everything except `attach` works without a terminal, which makes boo a
natural sandbox for scripts and AI agents driving interactive programs.
The canonical loop:

```sh
boo new build -d -- bash               # 1. headless session
boo send build --text 'make' --enter   # 2. type into it
boo wait build --idle                  # 3. let output settle
boo peek build --scrollback            # 4. read the screen
boo kill build                         # 5. clean up
```

- **Reading state**: `peek` prints the rendered screen reconstructed
  from terminal state, not a raw byte log: ordered, fully redrawn, and
  stable. `--scrollback` includes history; `--json` adds size, cursor,
  and title.
- **Waiting**: `wait --text <text>` blocks until the screen contains
  the text; `wait --idle` until output has been quiet for 2 seconds;
  `--timeout <dur>` exits 4 instead of hanging forever (durations:
  `500ms`, `2s`, `1m`, `4h`, `1d`). No more sleep-and-poll loops.
- **Sending input**: `send --text` is literal: no escape processing, no
  implicit newline, no quoting layer to fight. `--enter` submits,
  `--key Enter,C-c,Up` names control keys, and stdin mode is binary
  safe.
- **Machine-readable output**: `ls --json` and `peek --json`.
- **Exit codes**: `0` success, `1` error, `2` usage error, `3` no such
  session, `4` wait timed out.

See `boo help automation` for the full page.

## Contributing

Requires [Zig](https://ziglang.org) 0.15.2.

```sh
zig build                       # binary in zig-out/bin/boo
zig build test                  # unit tests
zig build test-integration     # end-to-end tests on a real PTY
zig build test-all             # everything
```

The libghostty dependency is fetched and built from source
automatically (pinned in `build.zig.zon`).

With Nix, `nix develop` opens a shell with the right Zig version, and
`nix build` builds the package to `./result/bin/boo`.

## Architecture

```
your terminal <-(raw tty)-> boo client <-(unix socket)-> session daemon
                                                         `- PTY + ghostty-vt Terminal
```

- The **client** puts your TTY in raw mode and shuttles bytes over a
  framed Unix-socket protocol (`src/protocol.zig`).
- The **daemon** (forked on session creation) owns the session's
  command: a PTY-attached child whose output feeds a persistent
  `ghostty-vt` `TerminalStream` (`src/window.zig`).
- While attached, output is passed through to your terminal byte for
  byte. On attach the daemon sanitizes your terminal and replays the
  screen from libghostty state using its VT `TerminalFormatter`.
- Terminal queries (DSR, DA, XTWINOPS, ...) while detached are answered
  by libghostty's stream handler; while attached your real terminal
  answers, avoiding double replies.

## Caveats

This is a young project, not a drop-in GNU screen replacement:

- One attached client per session (attaching steals); no `-x` sharing.
- One window per session: no splits or tabs inside a session. Run one
  session per task and juggle them with `boo ui`.
- The `C-a` prefix is not yet configurable, and pasted bytes containing
  `0x01` are interpreted as the prefix (GNU screen has the same quirk;
  `boo ui` is immune thanks to bracketed paste).
- Sessions run with `TERM=xterm-256color`.

## Support

Feel free to [open an issue](https://github.com/coder/boo/issues/new)
if you have questions, run into bugs, or have a feature request.

[Join the Coder Discord](https://discord.gg/coder) to chat with the
community.

## License

[MIT](LICENSE). Ghostty itself is MIT licensed.
