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
- **Wait** — block until an element matching a role/title appears.
- **Read** — OCR a window or image region, sample a pixel's color,
  read/write the clipboard.
- **Activity log** — an on-screen toast per call plus a live log window
  (`uictl log show`) so whoever's at the machine can see what's being
  automated, and an audit trail exportable as JSON (`uictl log export`).
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

Either way, it registers 19 `uictl_*` tools (screenshot, elements, click,
type, displays, log_show, log_export, etc.) that a client can call directly
with structured arguments instead of shelling out to the CLI and parsing
stdout. Since it's the same daemon underneath either front end, permissions
granted via the CLI (or vice versa) carry over automatically.

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

## Security note

`ocr`, `elements`, and `screenshot` read whatever is genuinely on screen,
which can include passwords, tokens, or other sensitive text an automated
app happens to display; that content is **not** redacted (unlike
`type`/`clipboard set`/`clipboard get` text, which is — see
`ENGINEERING.md`). It can end up in the activity log window, in
`uictl log export`'s JSON output, and in saved screenshot files. Manage and
dispose of those the same way you would any other capture of your screen's
contents.
