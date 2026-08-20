# uictl

A macOS command-line tool (and MCP server) for finding, inspecting, and
driving running GUI applications — built so a coding agent (Claude Code or
otherwise) can locate a window, screenshot it, read its UI structure, and
click/type into it without a human at the keyboard.

## What it does

- **Find & activate** — list running apps and their windows (substring app
  names match, and aggregate windows across, every running instance — so a
  just-restarted app is still found under its old query), bring one to the
  front.
- **Displays** — enumerate connected displays (id, global-coordinate bounds,
  main-display flag, points-to-pixels scale), so multi-monitor coordinates
  (which can be negative for a display left of/above the primary one) are
  something you can reason about instead of guess at.
- **Screenshot** — capture a window or a whole display, optionally with a
  numbered "set-of-marks" overlay on every clickable element so a
  vision-capable model can say "click element 7" instead of guessing pixel
  coordinates.
- **Inspect** — walk an app's accessibility (AX) tree: every element's role,
  title, value, and on-screen frame.
- **Act** — click (by coordinate, by element id, or window-relative to a
  given `--window`/`--app`), move, scroll, type (direct value-set or
  synthesized keystrokes), send key combos. Element clicks report back
  whether the click's effect could be verified.
- **Focus hold** — pin uictl to one window (`uictl focus hold --app/--window`)
  so every subsequent click/move/scroll/type/key call re-activates and raises
  it first if it isn't already frontmost — countering a human's own
  mouse/keyboard use (e.g. clicking back into the terminal running the agent)
  stealing focus away from whatever uictl is mid-task automating. Release
  with `uictl focus release`; check the current hold with `uictl focus
  status`.
- **Wait** — block until an element matching a role/title appears.
- **Read** — OCR a window or image region, sample a pixel's color,
  read/write the clipboard.
- **Activity log** — an on-screen toast per call plus a live log window
  (`uictl log show`) so whoever's at the machine can see what's being
  automated, and an audit trail exportable as JSON (`uictl log export`).
- **Feedback** — draft issues/errors/recommendations about uictl itself
  locally (full CRUD, `uictl feedback ...`), check a draft's title against
  existing GitHub issues first to avoid re-reporting something already
  filed, then hand it off to GitHub by opening a pre-filled "new issue"
  page (`uictl feedback submit`) — a human still reviews and clicks
  "Create" there. Called from MCP, `uictl_feedback_submit` asks the human
  to review the content via MCP elicitation first, since an agent may be
  the one initiating it.
- **MCP server** — every capability above is also exposed as an MCP tool
  over stdio, so an MCP-aware client can call `uictl_screenshot`,
  `uictl_click`, etc. directly instead of shelling out and parsing JSON.

Every CLI command prints one JSON object to stdout and exits `0`/non-zero on
success/failure, so it's easy to script or parse.

## Build

Requires the Xcode command-line tools (Swift 5.9+ toolchain) and macOS 14+.
From this directory:

```sh
swift build -c release
```

SwiftPM fetches its two dependencies (swift-argument-parser, the MCP Swift
SDK) on first build. The binary lands at `.build/release/uictl`. Either
invoke it by that full path, or put it on your `PATH`:

```sh
ln -s "$(pwd)/.build/release/uictl" /usr/local/bin/uictl
uictl --help
```

During development, use the faster debug build (`swift build`, binary at
`.build/debug/uictl`) instead. If you rebuild while the daemon is running,
run `uictl daemon stop` afterward so the next command relaunches it from
the new binary — otherwise you'll keep talking to the old one.

## First run: permissions

uictl needs **Accessibility** and **Screen Recording** permission for
whichever process actually invokes it (your terminal app, or `uictl`
itself if you grant it directly):

```sh
uictl permissions --request   # triggers the OS prompts
uictl permissions             # check status any time
```

## Hello World

The smallest possible walkthrough: launch a text editor, find its window,
bring it to front, and type into it. uictl deliberately has no "launch an
app" command (that's app-specific, and you already have a shell/agent that
can do it), so that one step uses `open` directly.

**From the command line:**

```sh
open -a TextEdit                             # launch it — uictl finds windows, it doesn't launch apps
uictl windows --app TextEdit                 # confirm it's running and find its window (auto-starts the uictl daemon on first use)
uictl activate --app TextEdit                # bring it to front
uictl type "Hello World"                     # type into whatever's focused — the new document's text area
```

**In an agent session** (uictl registered as an MCP server — see below):
you'd ask the agent to do the same thing in plain English, e.g. "open
TextEdit and type Hello World into it." It launches the app itself (its own
shell access, same as `open -a TextEdit` above), then drives it with the
matching MCP tool calls:

```
uictl_windows({"app": "TextEdit"})
uictl_activate({"app": "TextEdit"})
uictl_type({"text": "Hello World"})
```

Same three steps either way — `uictl_windows` confirms the window exists,
`uictl_activate` brings it to front, `uictl_type` (with no `element` given)
sends keystrokes to whatever currently has keyboard focus, which for a
freshly created document is its own text area. See "Recommended agent
workflow" below for the more robust version of this (finding a specific
element by id instead of relying on whatever already has focus) once
you're doing more than typing into a blank document.

## Architecture in one paragraph

`uictl` is a thin CLI/MCP front end over a small background daemon. The
first command you run auto-spawns the daemon (a detached process listening
on a Unix socket at `~/.uictl/uictl.sock`); every subsequent command — CLI
or MCP — is a client that sends one JSON request and gets one JSON response
back. The daemon is what actually holds permission grants, the Accessibility
tree walks, and the element-id cache, so state is consistent no matter which
front end you used to get there. See `ENGINEERING.md` for the details.

## CLI quick reference

```sh
uictl apps                                   # list running apps
uictl displays                               # enumerate connected displays
uictl windows --app Safari                   # list an app's windows
uictl activate --app Safari                  # bring it to front
uictl screenshot --app Safari --annotate     # numbered element overlay + legend
uictl elements --app Safari --role AXButton  # just the buttons
uictl click --element 12345-7                # click element 7 from that legend
uictl click --window 12345 --at 20,15        # click relative to a window's top-left corner
uictl type --element 12345-9 "hello"         # type into a specific field
uictl type "hello"                           # type into whatever's focused
uictl key "cmd+shift+4"                      # keyboard shortcut
uictl wait-for --app Safari --title "Done"   # poll for an element
uictl ocr --app Safari                       # read on-screen text
uictl pixel --at 100,200                     # sample a pixel's color
uictl clipboard get / set "text"
uictl log show                               # open the live activity log window
uictl log export                             # export it as JSON
uictl feedback create --category issue --title "..." --body "..."
uictl feedback submit <id>                   # checks for duplicates, then opens a pre-filled GitHub issue
uictl daemon status / stop
```

Run `uictl --help` (also `-h`, `-H`, `--HELP`, `-?`) or `uictl <subcommand>
--help` for full option lists. A man page (`man/uictl.1`) and HTML help
(`docs/help.html`) are also included.

## Using it as an MCP server

`uictl mcp` runs as an MCP server over stdio — no separate flags or config
file of its own; whatever launches it just needs to point at the binary.

**Claude Code** (from this directory, using the release binary built above):

```sh
claude mcp add uictl -- "$(pwd)/.build/release/uictl" mcp
```

Add `--scope user` instead of the default `--scope local` if you want it
available in every project, not just this one. Verify it registered and
started correctly:

```sh
claude mcp list         # should show "uictl" as connected
claude mcp get uictl     # shows the exact command it's running
```

**Claude Desktop / other MCP clients** that take a JSON config
(`claude_desktop_config.json` or equivalent) instead of a CLI flag:

```json
{
  "mcpServers": {
    "uictl": {
      "command": "/Users/jonesb7/dev/uictl-mcp/.build/release/uictl",
      "args": ["mcp"]
    }
  }
}
```

Either way, it registers 26 `uictl_*` tools (screenshot, elements, click,
type, displays, log_show, log_export, feedback_create, feedback_submit,
etc.) that a client can call directly with structured arguments instead of
shelling out to the CLI and parsing stdout. Since it's the same daemon
underneath either front end, permissions granted via the CLI (or vice
versa) carry over automatically.

## Recommended agent workflow

1. `apps` / `windows --app <name>` to find the target window.
2. `activate --app <name>` to bring it to front.
3. `screenshot --app <name> --annotate` — get an image plus a legend
   mapping numbers to element ids/roles/titles.
4. `click --element <id>` / `type --element <id> "..."` to act.
5. Re-run `elements` or `screenshot --annotate` to confirm the result, or
   `wait-for` if the UI update isn't instant.

See `AGENTS.md` for a more detailed walkthrough and gotchas.

## Known limitations

- **AX vs. window-server frame mismatch**: a small number of apps (observed
  with a freshly-launched Calculator on macOS 26) report a different window
  frame via the Accessibility API than via the window server/ScreenCaptureKit.
  When that happens, screenshots are still accurate (verified against
  `screencapture -l`) but clicks derived from AX element frames can miss.
  If clicks don't seem to land, sanity-check `windows --app X`'s reported
  size against what you see on screen.
- Element ids from `elements`/`screenshot --annotate` are only valid until
  the next time that window's elements are listed — the tree is re-walked
  and re-numbered every time.
- Window→AX correlation (needed for `elements`/`screenshot --annotate` when
  targeting a specific `--window <id>`) matches by title + frame, since
  macOS has no public API mapping a `CGWindowID` directly to an
  `AXUIElement`. This is the standard approach used by most macOS UI
  automation tools, but is a heuristic.
- **uictl can't reliably drive its own GUI.** The activity log window
  (`uictl log show`) is uictl's own on-screen UI; clicking its controls via
  `uictl click` (rather than a real mouse) is unreliable — a self-referential
  edge case that doesn't affect driving any other app. See `ENGINEERING.md`
  for what was tried.
- The daemon runs with no Dock icon and no Cmd-Tab entry (it's a background
  `.accessory` app), so if the activity log window gets buried behind other
  windows, Cmd-Tab won't bring it back — run `uictl log show` again instead.
- **`feedback submit`'s duplicate check needs a GitHub token for a private
  repo** — it resolves one from `--token`, then `$GITHUB_TOKEN`, then `gh
  auth token` if `gh` is installed and already authenticated. If none of
  those pan out, the check is skipped (reported as such) rather than
  blocking submission — it's a courtesy, not a guarantee. The match itself
  is a simple case-insensitive title comparison, not fuzzy matching, so it
  won't catch a duplicate that's worded very differently.

## Security note

`ocr`, `elements`, and `screenshot` read whatever is genuinely on screen,
which can include passwords, tokens, or other sensitive text an automated
app happens to display; that content is **not** redacted (unlike
`type`/`clipboard set`/`clipboard get` text, which is — see
`ENGINEERING.md`). It can end up in the activity log window, in
`uictl log export`'s JSON output, and in saved screenshot files. Manage and
dispose of those the same way you would any other capture of your screen's
contents.
