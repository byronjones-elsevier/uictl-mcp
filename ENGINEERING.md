# Engineering notes

## Process architecture

```
CLI subcommand ──┐
                  ├──▶ DaemonClient (Unix socket, ~/.uictl/uictl.sock) ──▶ DaemonServer ──▶ CommandDispatcher ──▶ Core/*
MCP tool call  ───┘
```

- **CLI** (`Sources/uictl/CLI/*`, ArgumentParser): parses flags, builds a
  `{"command": ..., "params": ...}` JSON dict, sends it via `DaemonClient`,
  prints the JSON response, exits 0/1 based on the response's `ok` field.
- **MCP server** (`Sources/uictl/MCP/*`, `uictl mcp`): same thing, one layer
  up — each MCP tool call also just calls `DaemonClient.send`. This is why
  CLI and MCP usage share state transparently (see "element ids" below).
- **DaemonClient/DaemonServer** (`Sources/uictl/IPC/*`): a length-prefixed
  JSON protocol over a Unix domain socket, one request/response per
  connection. `DaemonClient` auto-spawns the daemon (`uictl daemon start
  --foreground`, stdio redirected to `~/.uictl/daemon.log`) if the socket
  isn't reachable, and waits up to 5s for it to come up.
- **CommandDispatcher** (`Sources/uictl/IPC/CommandDispatcher.swift`): the
  one switch statement every request goes through, regardless of front end.
  Add a new capability by adding a case here plus a CLI subcommand and/or
  MCP tool that calls it — the dispatcher is the only place that needs to
  know how to actually perform it.
- **Core** (`Sources/uictl/Core/*`): the actual macOS API calls — AppKit,
  ApplicationServices (Accessibility), CoreGraphics (CGEvent input
  synthesis), ScreenCaptureKit (capture), Vision (OCR), NSPasteboard.

## Why a daemon at all

Permission grants (Accessibility, Screen Recording) and the accessibility
tree are per-process concerns. Running every command as a fresh, short-lived
process would work for permissions (macOS grants by executable path, and a
fresh process at the same path inherits the same grant), but it can't hold
an `AXUIElement` reference across invocations. Since `elements`/`screenshot
--annotate` hand out synthetic element ids that a later `click --element
<id>` needs to resolve back to a live `AXUIElement`, that cache has to live
somewhere longer-lived than one CLI invocation — hence the daemon.

## Coordinate spaces

Three coordinate spaces are in play, and getting them confused is the most
likely source of bugs if this code is extended:

1. **Global "Quartz" screen space** — origin at the top-left of the primary
   display, y increasing downward. This is what `CGWindowListCopyWindowInfo`
   bounds, `AXUIElementCopyAttributeValue(kAXPositionAttribute/...)`, and
   `CGEvent` mouse coordinates all use. Every `"frame"` in this tool's JSON
   output is in this space, and `click --at`/`move --at`/`scroll --at`/
   `pixel --at` all take points in this space.
2. **Capture-local pixel space** — a `CGImage` from `ScreenCaptureKit`, with
   `(0,0)` at the top-left of *that capture* (a window or a display), scaled
   by `SCContentFilter.pointPixelScale` (2.0 on Retina). Converting a global
   frame into this space is `(global - capture.origin) * capture.pointPixelScale`
   — see `ScreenCapture.annotate` and `OCR.recognizeText`.
3. **Vision's normalized space** — `VNRecognizeTextRequest` bounding boxes
   are `0...1` normalized with a **bottom-left** origin, the one place a
   flip is needed before converting into capture-local pixels.

`CGContext`'s default space is also bottom-left/y-up (Quartz's *drawing*
convention, confusingly the opposite of its window-position convention);
`ScreenCapture.annotate` flips it once at the top (`translateBy` +
`scaleBy(y: -1)`) so everything drawn after that — the image and the
overlay boxes — can be expressed directly in global-Quartz-style top-left/
y-down coordinates without a second conversion.

### Multiple displays

Global-Quartz space is anchored to the *primary* display's top-left corner,
not each display's own — so a display positioned left of or above the
primary one in System Settings > Displays has **negative** x/y in its
`CGDisplayBounds`, and any window/element frame on it will too. `uictl
displays`/`uictl_displays` (`Core/Displays.swift`) enumerates every display's
id, bounds, main-display flag, and points-to-pixels scale, so a caller can
tell which display a coordinate is likely to land on before acting — its
`"index"` field matches what `screenshot --screen <index>` expects. Every
window from `windows`/`uictl_windows` also carries a `"displayId"` matching
one of those ids (`Displays.displayID(containing:)`, a synchronous
`CGGetDisplaysWithPoint` lookup on the window's center — deliberately not the
`SCShareableContent` API `Displays.list()` uses, since that requires an async
round trip per call and would be too slow to run once per window).

## Window → AXUIElement correlation

There's no public API that maps a `CGWindowID` to an `AXUIElement` directly.
`Accessibility.resolveWindowElement` matches by title + frame against the
owning app's `kAXWindowsAttribute` list (the standard approach; see e.g. any
open-source macOS AX automation tool). If an app exposes only one AX window,
that's returned immediately without needing the heuristic.

One observed exception on this machine: a freshly-launched macOS 26
Calculator reports a *different* frame via AX than via
`CGWindowListCopyWindowInfo`/`ScreenCaptureKit` for what should be the same
window (verified independently against Apple's own `screencapture -l`,
which agrees with the CGWindowList/ScreenCaptureKit number, not AX's). Root
cause not identified — plausibly specific to that app's window server
plumbing. `elements`/`screenshot --annotate` still walk the (correct) AX
tree fine; it's specifically `click --element <id>` on such a window that
would miss, since it clicks at the AX-reported frame's center in global
screen coordinates. Verified working end-to-end against TextEdit (multiple
simultaneous windows, exact frame agreement between AX and CGWindowList).

## App-name resolution across restarts

`AppSelector.resolveAll` treats a `--app`/`app` selector as a numeric pid, a
reverse-DNS bundle id, or (otherwise) a case-insensitive substring of
`localizedName` — and a substring can legitimately match more than one
running instance at once, e.g. right after an app is quit and relaunched,
where the old and new process briefly overlap in
`NSWorkspace.runningApplications`, or a helper process shares part of the
main app's name. `windows.list` uses `resolveAll` and aggregates windows
across every matching pid, so a restarted app's windows are still found
without the caller needing to know its new pid. Single-app call sites
(`activate`, `elements`, `screenshot`, `ocr`, `waitFor`, all via
`AppSelector.resolve`) instead narrow multiple matches down to one,
preferring whichever candidate actually has on-screen windows before falling
back to an exact name match, then the frontmost instance, then the first —
so a stale, windowless, about-to-terminate instance never wins over the one
actually on screen.

## The ArgumentParser async gotcha

Original design used `AsyncParsableCommand` for `Root` and the `mcp`
subcommand (since `MCPServer.run()` is `async`). This silently broke: a
concrete type that conforms to both `ParsableCommand` (which gives every
conformer a synchronous default `run() throws` via a protocol extension)
and `AsyncParsableCommand` (which requires its own `run() async throws`)
ends up with two distinct `run` witnesses. Calling `.run()` — even on the
concrete type, even through an explicit `as? AsyncParsableCommand` cast —
resolved to the synchronous default (which just prints help) instead of the
real implementation. Confirmed by hand: `uictl mcp` printed its help text
instead of starting the stdio server, with no compiler error and only an
easy-to-miss "no async operations occur within 'await' expression" warning
as a clue.

Fix: don't use `AsyncParsableCommand` at all. `Root` and every subcommand
are plain synchronous `ParsableCommand`s; `mcp`'s `run() throws` bridges into
`MCPServer.run() async throws` via the same `runSync` semaphore bridge used
for ScreenCaptureKit calls (`Sources/uictl/Core/AsyncBridge.swift`). One
bridging mechanism, used consistently, instead of two competing ones.

## Adding a new capability

1. Implement the actual macOS API call in `Core/`.
2. Add a `case` to `CommandDispatcher.dispatch`.
3. Add a CLI subcommand (`CLI/*Commands.swift`) that builds the params dict
   and calls `DaemonClient.send`.
4. Add a matching `ToolSpec` in `MCP/MCPServer.swift` if it should also be
   MCP-callable.
5. Rebuild (`swift build`), restart the daemon (`uictl daemon stop`; it
   auto-restarts on the next command) so it picks up the new binary.
