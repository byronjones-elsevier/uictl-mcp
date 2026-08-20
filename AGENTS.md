# Using uictl as an agent

This tool exists so an agent (Claude Code or similar) can drive a GUI app
during development without a human moving the mouse. This file is the
practical playbook — see `README.md` for setup and `ENGINEERING.md` for
implementation details.

## The core loop

1. **Find the window.**
   ```sh
   uictl windows --app <AppName>
   ```
   If the app isn't running yet, launch it yourself (`open -a AppName`, or
   however your workflow starts it), then retry — there's no "launch"
   command in uictl on purpose; that's app-specific and you already have a
   shell. A name substring matches, and aggregates windows from, every
   running instance whose name contains it — so this still finds the right
   window immediately after the app restarts, without you needing its new
   pid. If you're on a multi-monitor setup and a window's coordinates look
   surprising (e.g. negative), run `uictl displays` — global coordinates are
   anchored to the *primary* display's top-left corner, so anything left of
   or above it is negative.

2. **Bring it to front.**
   ```sh
   uictl activate --app <AppName>
   ```
   Do this before screenshotting or clicking — otherwise you may be looking
   at (or clicking into) a window that's behind something else.

3. **Look at it — with element numbers, not a blank screenshot.**
   ```sh
   uictl screenshot --app <AppName> --annotate --out /tmp/shot.png
   ```
   Read the returned JSON `elements` legend (each has a `number`, `id`,
   `role`, `title`, `frame`) alongside the image. This is deliberately
   *not* just a plain screenshot — a vision model reading raw pixels has to
   guess coordinates, which is where most GUI-automation flakiness comes
   from. With the overlay, you can say "click number 7" and then act on
   that entry's `id`.

4. **Act using the element id, not raw coordinates.**
   ```sh
   uictl click --element <id>
   uictl type --element <id> "some text"
   ```
   Prefer `--element` over `--at x,y` whenever you have an id: it's
   resilient to the window having moved or resized since you looked at it,
   and `type --element` tries to set the field's value directly before
   falling back to synthesized keystrokes (faster, and doesn't fight with
   autocomplete/autocorrect the way keystroke-by-keystroke typing can). If
   you don't have an element id but do know which window, `click --window
   <id> --at x,y` (or `--app <name>` instead of `--window`) treats the
   point as relative to that window's *current* top-left corner rather than
   an absolute screen point — same for `move`/`scroll`/`pixel`. `click`
   restores the real cursor to wherever it was beforehand once it's done;
   pass `--hover-cursor` if you specifically need it to stay at the click
   point (e.g. to keep a hover-triggered tooltip open for a follow-up
   screenshot).

5. **Confirm the result, don't assume it.**
   ```sh
   uictl elements --app <AppName> --title "expected label"
   ```
   or `wait-for` if the UI updates asynchronously:
   ```sh
   uictl wait-for --app <AppName> --title "Done" --timeout 10
   ```
   or re-screenshot and OCR/look at it again. Don't chain five actions
   blind — check after anything that might fail silently (a disabled
   button, a modal that didn't open, focus that landed somewhere else).
   `click --element` itself gives you a first signal for free: its response
   includes a `verification` field — `"changed"`/`"unchanged"` if the
   element's AX value/selected-state could be diffed before and after the
   click, or `"unavailable"` if it exposed neither (common for custom-drawn
   or webview controls, e.g. many HTML checkboxes). A `"changed"` result is
   good evidence the click landed; `"unavailable"` isn't evidence either
   way — still verify those independently.

## When accessibility elements aren't enough

Some UIs (canvas-drawn, game engines, custom-rendered text) don't expose
useful nodes via `elements`. Fall back to:

- `uictl ocr --app <AppName>` — reads on-screen text and returns each
  block's bounding box in the same global coordinate space as `elements`
  frames, so you can compute a click point from OCR'd text you can't find
  in the AX tree.
- `uictl pixel --at x,y` — cheap state checks (is this toggle's indicator
  lit? did a progress bar finish?) without a full screenshot+vision-model
  round trip.

## Gotchas specific to this tool

- **Element ids expire.** Every `elements`/`screenshot --annotate` call
  re-walks the tree and re-numbers it. An id from three steps ago may now
  point at nothing, or at a different element if the UI changed shape.
  Re-list before acting if any time (or any other action) has passed.
- **`click --element` uses the element's *center point*, not `AXPress`.**
  This is intentional — `AXPress` isn't implemented by many custom-drawn
  controls, so this tool always does a real synthesized mouse click at the
  element's on-screen center. If an app's AX-reported frame is stale (see
  the Calculator caveat in `README.md`), the click can miss even though
  the element looked right in `elements`. If clicks aren't landing, sanity
  check `uictl windows --app X` against what's actually visible.
- **`type` without `--element`** sends keystrokes to whatever currently has
  keyboard focus, system-wide — make sure you've clicked into the right
  field first (or passed `--element`, which handles focusing for you).
- **The daemon caches state.** If you rebuild `uictl` during development,
  run `uictl daemon stop` before your next command — otherwise you'll keep
  talking to the old binary running in the background.
- **One window frame per capture.** `screenshot --window <id>` and
  `elements --window <id>` both correlate a `CGWindowID` to an AX window by
  title+frame matching (no public API does this directly). If an app has
  several windows with identical titles, prefer `--app <name>` (picks the
  frontmost on-screen one) unless you specifically need a background
  window.
- **Don't try to drive uictl's own GUI with uictl.** The activity log
  window (`uictl log show`) is uictl's own on-screen window; clicking its
  controls via `uictl click` rather than a real mouse is unreliable
  (self-referential AX/click quirks specific to uictl targeting its own
  process — see `ENGINEERING.md`). This doesn't affect driving any other
  app. If a human tells you that window looks stuck or missing, just
  re-run `uictl log show` — the daemon has no Dock icon or Cmd-Tab entry,
  so that's the only way to bring it back to front once it's buried.
- **Screenshots/OCR/elements output isn't redacted.** Unlike `type` and
  `clipboard set`/`get` text, on-screen content read by `ocr`/`elements`/
  `screenshot` (which can include passwords or other sensitive text an app
  happens to display) is not redacted anywhere it's logged or exported —
  see "Letting a human see what you're doing" below and the Security note
  in `README.md`.

## Letting a human see what you're doing

The daemon shows a brief on-screen toast per call by default, and
`uictl log show` opens a live table of every CLI/MCP call it's handled
(`uictl log export` writes the same data to a JSON file). If a human at
this machine wants visibility into what you're automating — or you just
want to make the automation visible rather than silent — call
`uictl log show` (or `uictl_log_show` over MCP) to surface it. Keep in mind
the params/response shown there are summarized and truncated, and that
`ocr`/`elements`/`screenshot` output isn't redacted (see the gotcha above).

## MCP mode

If your harness supports MCP tools directly, prefer that over shelling out:

```sh
claude mcp add uictl -- /path/to/uictl mcp
```

Then call `uictl_screenshot`, `uictl_elements`, `uictl_click`, etc. as
structured tool calls instead of parsing CLI stdout. Same daemon, same
element-id cache, same everything underneath — just a shorter round trip.
