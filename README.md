# cuelight

[![CI](https://github.com/odiumuniverse/cuelight/actions/workflows/ci.yml/badge.svg)](https://github.com/odiumuniverse/cuelight/actions/workflows/ci.yml)

Blinks the Caps Lock LED on your keyboards while a coding agent session is waiting for
you. Handles several sessions in several windows at once, lets you pick which keyboards
light up and how long they keep blinking, and — since the same hooks already know when
the agent was working and when it was waiting — reports how your time actually went.

Supported agents: **Claude Code**, **opencode**, **Gemini CLI**, **Antigravity**,
**Codex**, and **Cursor**. Hooks are installed per agent, by hand, from the *Agent hooks*
submenu or `cuelight hooks install <agent>`.

It drives the keyboard's LED element directly. The Caps Lock **modifier** is never
touched, so your typing case is unaffected — verified by sampling both
`IOHIDGetModifierLockState` and the event system's `.maskAlphaShift` flag while the
LEDs were lit: neither was ever asserted.

> This is an unofficial, community-developed project. It is not affiliated with,
> endorsed by, or sponsored by Anthropic or any of the agents it watches.

## Install

Needs macOS 13 or newer, and at least one supported agent.

### Homebrew

```sh
brew tap odiumuniverse/tap
brew trust odiumuniverse/tap
brew install --cask cuelight
```

Installs `cuelight.app` into `/Applications`, the `cuelight` CLI onto your
`PATH`, and the zsh completion. Homebrew downloads with `curl`, so the app
carries no quarantine flag and Gatekeeper does not block it.

### From source (recommended)

```sh
git clone https://github.com/odiumuniverse/cuelight
cd cuelight
make install
```

That builds the app, puts it in `/Applications`, symlinks the CLI onto your `PATH`,
installs the zsh completion, and launches it. Needs `swiftc` from the Xcode Command
Line Tools — `xcode-select --install` if you do not have them.

Building locally also sidesteps Gatekeeper entirely, because nothing was downloaded.

### From a release

Download the zip from
[Releases](https://github.com/odiumuniverse/cuelight/releases), unzip, and move
`cuelight.app` to `/Applications`.

macOS will refuse to open it: the app is ad-hoc signed, not notarised, and anything
that arrives through a browser carries a quarantine flag. Either strip the flag:

```sh
xattr -dr com.apple.quarantine /Applications/cuelight.app
```

or open it once, let it be blocked, then allow it in
*System Settings → Privacy & Security → Open Anyway*.

Notarising would remove this step, and requires a paid Apple Developer account.

Launch it once either way. It lives in the menu bar — no Dock icon, no app switcher
entry. Hooks are never installed behind your back: tick an agent under *Agent hooks*,
or run `cuelight hooks install <agent>`.

### Rebuilding

An ad-hoc signature is derived from the binary, so every rebuild looks like a
different app to macOS and the Input Monitoring grant stops applying. `make install`
clears the stale grant so the prompt appears again; grant it and the app restarts
itself.

```sh
make            # build into build/
make test       # run the checks
make run        # launch the built copy without installing it
make install    # build, install, relaunch
make uninstall  # remove the app, the CLI and the completion
make release    # zip the bundle for a GitHub release
make clean      # throw away build output
make help       # list the targets
```

## Layout and tests

`Sources/cuelight/Core/` holds everything that can be decided without a keyboard or a
screen — keyboard selection, the blink decision and its timeout, which events blink,
staleness, the event log, the statistics, and the per-agent hook merges. It imports
neither AppKit nor IOKit. `Sources/cuelight/App/` is the shell around it: the menu bar,
the HID writes, the CLI.

`make test` compiles `Core/` together with `Tests/main.swift` and runs it. Assert-based
checks, no framework and no fixtures — one binary that prints what it verified and
exits non-zero when something breaks. Because only `Core/` is compiled in, logic that
needs a test has to live there.

CI runs on every pull request and every push to `master`: the tests, a build with
`-warnings-as-errors`, SwiftLint, a syntax check of the zsh completion, and the full
`make release` path — which is the only thing that proves the icon still draws, since
`Resources/cuelight.icns` is generated rather than committed. The packaged zip is
attached to each run, so a pull request can be downloaded and run rather than trusted.

`.swiftlint.yml` records where the house style and SwiftLint's defaults disagree, with
the reason for each — short argument labels like `to:` and `at:`, aligned `if`/`else`
pairs, trailing commas in multi-line literals.

## Menu

| Item | What it does |
|---|---|
| *N sessions waiting* | how many sessions are waiting on you right now |
| Blink on keyboards | tick any combination; keyboards without a caps LED are listed but not selectable |
| Blink for | 5 min, 10 min, 30 min, or Always — how long the lamp keeps blinking |
| Blink on | tick which events light the lamp: Turn finished, Permission prompt, Work in flight |
| Statistics… | opens the stats window; see [Statistics](#statistics) |
| Agent hooks | one tick per agent: tick to install that agent's hooks, untick to remove |
| Start at login | registers a login item via `SMAppService` |
| Hide icon | takes the icon out of the menu bar, keeps blinking |
| Visit GitHub | opens this page |

Without Input Monitoring the menu shows none of that. It leads with the missing
permission and a button to the settings pane instead, because every keyboard would
otherwise appear to have no caps LED — see [Permissions](#permissions).

Hiding is not quitting. To bring the icon back, launch cuelight again — a second
launch reopens the running copy rather than starting another — or run `cuelight show`.

The lamp has exactly one meaning: an agent is waiting for you. It stays dark while the
agent works, which is most of the time. *Blink on* is how that is shaped:

- **Turn finished** (on) — the agent finished its turn, the ball is yours.
- **Permission prompt** (on) — the agent is blocked on a prompt.
- **Work in flight** (off) — turn it on and the lamp blinks while the agent works, which
  inverts the lamp's meaning on purpose: it becomes a busy light rather than a
  doorbell. Untick both defaults and the lamp simply never lights; the statistics keep
  recording either way.

*Blink for* puts a limit on how long it keeps blinking. The default is *Always*, which
is what the app has always done: blink until you answer. Pick a duration instead and the
lamp gives up after it, on the theory that a light you have ignored for half an hour has
stopped being information. The session is not forgotten — the menu and
`cuelight status` still count it as waiting, and the next thing the agent does re-arms
the timer.

Unticking the last selected keyboard is refused. "Nothing selected" and "everything
selected" are the same stored value, so allowing it would leave you looking at a menu
full of ticks and a lamp that never lights. Ticking no blinking events, on the other
hand, is a real choice: the stored list says what it means.

## CLI

The app bundle is also the CLI: one binary, which runs the menu bar app when given no
arguments and answers as a command line tool when given some. `make install` symlinks
it onto your `PATH`.

```
cuelight                      run the menu bar app
cuelight devices              list keyboards and which ones blink
cuelight devices --names      names only, for scripts
cuelight test <keyboard>      light a keyboard for 3s
cuelight status               show tracked sessions
cuelight blink                show how long the lamp blinks for
cuelight blink <duration>     set it: 5m, 30m, 90s, 1h, or always
cuelight stats                time spent, today and over the last 7 days
cuelight show                 bring the icon back after hiding it
cuelight hooks                print each agent's hook config, if you prefer to install it yourself
cuelight hooks install <id>   install hooks for one agent: claude | opencode | gemini | antigravity | codex | cursor | all
cuelight hooks remove <id>    remove them again
cuelight help                 the same list
```

`cuelight hook <agent> <event>` also exists and is not for you: it is what the
installed hooks call.

Zsh completion for `cuelight test` lists your keyboards. The names are read from the
running binary, so a keyboard you just plugged in is completable straight away.

`cuelight blink` and the *Blink for* menu write the same setting, and the running app
notices within a second either way — nothing needs restarting. The menu offers four
presets; the CLI takes any duration.

## Agent support

Each agent reports its own events, and cuelight maps them onto four canonical ones:
`prompt` (work in flight), `stop` (turn done), `notify` (blocked on you), and `end`
(forget the session).

| Agent | Config file | Events used |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | UserPromptSubmit, Stop, Notification, PostToolUse, SessionEnd |
| opencode | `~/.config/opencode/plugins/cuelight.js` | chat.message, session.idle, permission.asked, question.asked, permission.replied, question.replied, question.rejected, session.deleted |
| Gemini CLI | `~/.gemini/settings.json` | BeforeAgent, AfterAgent, Notification, AfterTool, SessionEnd |
| Antigravity | `~/.gemini/config/hooks.json` | PreInvocation, PostToolUse, PreToolUse (ask_question), Stop |
| Codex | `~/.codex/hooks.json` | UserPromptSubmit, Stop, PermissionRequest, PostToolUse, SessionEnd |
| Cursor | `~/.cursor/hooks.json` | beforeSubmitPrompt, stop, sessionEnd |

Hooks are installed per agent and never automatically. The launch-time pass only
re-points hooks that are already ours at the current bundle path, so moving
`cuelight.app` does not leave a dead path behind.

Known limitations, deliberate rather than bugs:

- **Cursor**: `beforeShellExecution` is deliberately not hooked. Returning a permission
  decision there would make cuelight the decider for every shell command and could
  auto-approve or block it. The consequence is that a mid-turn approval prompt does not
  light the lamp; Cursor shows its own notification for that.
- **Antigravity**: there is no session-end event, so dead sessions are cleaned up by
  the pid check or the 12-hour TTL rather than immediately.
- **Codex**: after `cuelight hooks install codex`, run `/hooks` inside Codex once to
  review and trust the new hooks — untrusted hooks are skipped by Codex.
- **Gemini CLI** is being superseded by Antigravity CLI; both are supported.

## How it works

Agent hooks report *events* — `prompt`, `stop`, `notify`, `end` — into
`~/.config/cuelight/sessions/`, one file per session, tagged with the agent that sent
it. The app decides what those events mean, so the hooks stay dumb and the agent config
files never have to change again.

By default `stop` and `notify` mean an agent needs you, and light the lamp. `prompt`
means work is in flight. A tool finishing also reports `prompt`, which is what stops
the lamp blinking after you approve a permission prompt: a tool running is the evidence
that the block is gone.

Several windows aggregate with OR — any one session waiting is enough to blink.
Subagent sessions are skipped: Claude's `SubagentStop` is deliberately not hooked, and
the opencode plugin tracks child session ids so they cannot blink for the main agent.

A session killed with `kill -9`, or a terminal window closed without warning, leaves
its file behind. The app records the owning process id and drops any session whose
process is gone, within a second. A 12 hour TTL is the backstop for the rare case
where the process could not be identified.

Everything cuelight keeps lives under `~/.config/cuelight/`:

| Path | What |
|---|---|
| `config.json` | keyboard selection, blink timeout, blinking events, idle cap |
| `sessions/` | one file per live session: pid, timestamp, last event, agent |
| `events/YYYY-MM.jsonl` | the append-only event log the statistics read |
| `diagnostics.log` | what the app saw at launch — keyboards, permission state |

`diagnostics.log` is the first thing to read when the lamp does not light: it records
whether Input Monitoring was granted and which keyboards exposed a caps LED.

## Statistics

The same hooks append one line each to `~/.config/cuelight/events/YYYY-MM.jsonl`, one
file per month. `cuelight stats` reads them back:

```
today      worked 1h 12m · waiting on you 34m · blocked 2m
this week  worked 8h 03m · waiting on you 3h 41m

project      worked   waiting
topscan       5h 20m    2h 10m
cuelight      2h 43m    1h 31m

12 sessions this week · 4h 12m skipped as away (gaps over 5m)
```

Every pair of consecutive events brackets a gap, and the earlier event says what was
happening during it: after `prompt` the agent was working, after `stop` it was waiting
for you, after `notify` it was blocked on a permission prompt. Sessions from different
agents are pooled; per-agent breakdown is not part of the report.

```
cuelight stats week|month|year|all   one window instead of today plus the week
cuelight stats -i                    pick a period and a destination with the arrows
cuelight stats month --md            a markdown table, for pasting
cuelight stats week --json           the same numbers, for scripts
cuelight stats all --card [file]     a PNG card, for sharing
```

The menu has the same thing under *Statistics…*: a segmented control to switch period,
and buttons for *Copy as Markdown* and *Save PNG Card…*.

The picker only appears when both ends are a terminal, so `cuelight stats --json |
jq` is never interrupted by a menu.

A gap longer than five minutes is not counted at all — you went to lunch, or shut the
lid, and no honest number can tell that apart from thinking hard. It is reported on
the last line rather than dropped silently. Change the threshold with
`"idleCapSeconds"` in `~/.config/cuelight/config.json`.

Only the last component of the working directory is stored, never the full path, so
sharing a report does not leak where your work lives.

## Permissions

cuelight **requires Input Monitoring**, in
*System Settings → Privacy & Security → Input Monitoring*. It asks on first launch.

macOS gates opening a keyboard HID device behind that permission whether you mean to
read keystrokes or only write to an LED. Without it the caps LED element is not merely
unwritable, it is invisible — the keyboard looks like it has no LED at all. The menu
says so explicitly and offers to open the settings pane, rather than showing you a
list of keyboards that mysteriously cannot be selected.

The command line tool often works without the grant because it inherits the one held
by your terminal. The app is its own subject in the privacy database and needs its own.

What that permission allows and what cuelight does with it are different things.
There is no input-reading code in this repository: no
`IOHIDDeviceRegisterInputValueCallback`, no `IOHIDDeviceRegisterInputReportCallback`,
no event tap, no global monitor. It registers device arrival and removal callbacks,
and writes LED values. Grep for it before you trust it.

## Tested on

| Keyboard | Transport | Result |
|---|---|---|
| Apple Internal Keyboard (MacBook) | SPI | works |
| Apple Magic Keyboard 2 | Bluetooth | works |

Works with or without a Caps Lock → Control remap; the remap turned out to be
irrelevant to LED writes.

Other keyboards are handled generically: if the keyboard exposes a Caps Lock LED
element it can be driven, and `cuelight test <name>` tells you in three seconds.

## Uninstall

Untick every agent under *Agent hooks* in the menu first — that takes cuelight out of
each agent's config and leaves your other hooks alone. Then:

```sh
make uninstall          # app, CLI symlink, completion
rm -rf ~/.config/cuelight   # config and session state, if you mean it
```

`make uninstall` deliberately leaves the config alone, so reinstalling does not lose
your keyboard selection.

## License

MIT
