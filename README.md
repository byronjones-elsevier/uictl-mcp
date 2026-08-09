# uictl

A macOS command-line tool (and MCP server) for finding, inspecting, and
driving running GUI applications — built so a coding agent (Claude Code or
otherwise) can locate a window, screenshot it, read its UI structure, and
click/type into it without a human at the keyboard.

## What it does

- **Find & activate** — list running apps and their windows, bring one to
  the front.
- **Screenshot** — capture a window or a whole display, optionally with a
  numbered "set-of-marks" overlay on every clickable element so a
  vision-capable model can say "click element 7" instead of guessing pixel
  coordinates.
- **Inspect** — walk an app's accessibility (AX) tree: every element's role,
  title, value, and on-screen frame.
- **Act** — click (by coordinate or by element id), move, scroll, type
  (direct value-set or synthesized keystrokes), send key combos.
- **Wait** — block until an element matching a role/title appears.
- **Read** — OCR a window or image region, sample a pixel's color,
  read/write the clipboard.
- **MCP server** — every capability above is also exposed as an MCP tool
  over stdio, so an MCP-aware client can call `uictl_screenshot`,
  `uictl_click`, etc. directly instead of shelling out and parsing JSON.

Every CLI command prints one JSON object to stdout and exits `0`/non-zero on
success/failure, so it's easy to script or parse.

## Build

```sh
swift build -c release
```

The binary lands at `.build/release/uictl`. Put it on your `PATH`, or invoke
it via its full path.

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
uictl windows --app Safari                   # list an app's windows
uictl activate --app Safari                  # bring it to front
uictl screenshot --app Safari --annotate     # numbered element overlay + legend
uictl elements --app Safari --role AXButton  # just the buttons
uictl click --element 12345-7                # click element 7 from that legend
uictl type --element 12345-9 "hello"         # type into a specific field
uictl type "hello"                           # type into whatever's focused
uictl key "cmd+shift+4"                      # keyboard shortcut
uictl wait-for --app Safari --title "Done"   # poll for an element
uictl ocr --app Safari                       # read on-screen text
uictl pixel --at 100,200                     # sample a pixel's color
uictl clipboard get / set "text"
uictl daemon status / stop
```

Run `uictl --help` (also `-h`, `-H`, `--HELP`, `-?`) or `uictl <subcommand>
--help` for full option lists. A man page (`man/uictl.1`) and HTML help
(`docs/help.html`) are also included.

## Using it as an MCP server

```sh
claude mcp add uictl -- /path/to/uictl mcp
```

This registers 16 `uictl_*` tools (screenshot, elements, click, type, etc.)
that a client can call directly with structured arguments instead of
shelling out to the CLI and parsing stdout.

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
