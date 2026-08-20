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
  One exception: `uictl_feedback_submit` (`MCP/FeedbackSubmission.swift`) —
  see "Feedback submission & MCP elicitation" below.
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
- **GUI** (`Sources/uictl/GUI/*`): the daemon's own on-screen UI — a
  per-call toast and the `uictl log show` activity-log window. See
  "Activity log window" below.
- **Feedback** (`Core/FeedbackStore.swift`, `Core/GitHubIssues.swift`,
  `Core/GitHubToken.swift`): local CRUD storage for feedback about uictl
  itself, plus the GitHub REST client used to check a draft against
  existing issues before submitting. See "Feedback submission & MCP
  elicitation" below.

## Why a daemon at all

Permission grants (Accessibility, Screen Recording) and the accessibility
tree are per-process concerns. Running every command as a fresh, short-lived
process would work for permissions (macOS grants by executable path, and a
fresh process at the same path inherits the same grant), but it can't hold
an `AXUIElement` reference across invocations. Since `elements`/`screenshot
--annotate` hand out synthetic element ids that a later `click --element
<id>` needs to resolve back to a live `AXUIElement`, that cache has to live
somewhere longer-lived than one CLI invocation — hence the daemon.

## Activity log window

Every command that reaches `CommandDispatcher.dispatch` is timed and recorded
into `ActivityLog.shared` (`Core/ActivityLog.swift`), which the GUI layer
(`Sources/uictl/GUI/*`) observes to show a transient toast per call and drive
the `uictl log show` window. This is the first on-screen UI anywhere in this
codebase, which mattered for `DaemonServer.run`: it previously ran a bare
blocking `accept()` loop directly on the main thread, but an `NSApplication`
run loop (needed to pump events for any window) can't share a thread with a
permanently-blocking BSD socket call. The accept/dispatch loop now runs on a
dedicated background `Thread` (`DaemonServer.acceptLoop`, unchanged otherwise
— still one request at a time), freeing the main thread for
`NSApplication.shared.run()`. The app runs with `.accessory` activation
policy (no Dock icon/app-switcher entry) — it's still a background daemon,
just one that can now show a couple of small windows. Because dispatch runs
on the background thread while AppKit runs on the main thread, every UI
update the GUI layer makes in response to a recorded call
(`ActivityLog.onRecord`) hops to the main thread via `DispatchQueue.main.async`.

**Re-summoning a buried window.** `.accessory` policy means no Dock icon and
no Cmd-Tab entry, so once the log window is behind other windows, there's no
OS-level way back to it except running `uictl log show` again. That case's
handler therefore does more than `showWindow(nil)`: it also calls
`NSApp.activate(ignoringOtherApps: true)` and `window?.orderFrontRegardless()`.
Both matter — `uictl activate --app uictl` (`NSRunningApplication.activate`,
called *from a different process*) was observed consistently failing against
this daemon's own process specifically (every other app tested during this
work activated fine); self-activation from *within* the process is a
different, evidently more permitted code path. Root cause not confirmed, but
plausibly a macOS restriction on `.accessory`/unbundled processes activating
themselves via that external API.

**Commands-enabled kill switch.** The log window has a "Commands enabled"
checkbox backed by `UICtlGate` (`Core/UICtlGate.swift`). `CommandDispatcher
.dispatch` checks `UICtlGate.commandsEnabled` before doing anything else and,
if false, returns an error response without touching `dispatchInner` — the
blocked attempt still gets timed and recorded into `ActivityLog` like any
other call, so it's visible in the table rather than silently vanishing.
The gate only takes effect while the window is open: `ActivityWindowController
.showWindow` calls `UICtlGate.setWindowOpen(true)`, and the
`NSWindowDelegate.windowWillClose` callback calls `setWindowOpen(false)`, so
closing the window (rather than unchecking the box) is itself a way back to
"always enabled" — this is deliberate, since the checkbox that re-enables
commands lives inside the window it would otherwise be impossible to get
back to. `UICtlGate`'s own state is read/written from both the daemon's
background accept-loop thread (`dispatch`) and the main thread (the checkbox
and window-close callbacks), hence the internal `DispatchQueue.sync` rather
than a bare `Bool`.

**Security note — sensitive on-screen content is not redacted.**
`ActivityLog.summarizeParams`/`summarizeResponse` (`Core/ActivityLog.swift`)
redact `"text"` for `type`/`clipboard.set`/`clipboard.get` specifically,
since those are the one param/response shape where secret content flows
through uictl's own arguments (a password typed into a field, clipboard
content). They deliberately do **not** redact `ocr`/`elements`/`screenshot`
output: those commands' entire purpose is to read whatever is genuinely on
screen, and there's no reliable way to distinguish "just app UI" from
"a password field someone left visible" from plain text content — attempting
to guess would either miss real secrets or break the feature for everything
else. Whatever is on screen when one of those commands runs — which can
include passwords, tokens, or other sensitive text the automated app happens
to display — ends up in the activity log (on-screen table and any
`uictl_log_export`/`uictl log export` JSON output) and in any screenshot
file `screenshot`/`screenshot --annotate` writes to disk. Treat the activity
log window, its JSON exports, and saved screenshots as potentially
containing sensitive data: don't leave the log window on-screen or its
exports lying around on a shared or untrusted machine, and manage/dispose of
screenshot files with the same care as any other capture of your screen's
contents.

## Feedback submission & MCP elicitation

`feedback create`/`list`/`get`/`update`/`delete` are plain `FeedbackStore`
(`Core/FeedbackStore.swift`) forwards — a single `~/.uictl/feedback.json`
(`{nextId, entries}`), read-modify-written per call under a serial
`DispatchQueue`, same "not a hot path, no need for an in-memory cache"
reasoning as `ActivityLog`.

**Duplicate checking.** `feedback.checkDuplicates`/`feedback.submit`
(`CommandDispatcher.swift`) call `GitHubIssues.fetchAll` (a plain
`GET /repos/{repo}/issues?state=all`, paginated, `Core/GitHubIssues.swift`)
and diff the draft's title against every result with a deliberately simple
case-insensitive-equality-or-substring heuristic — not fuzzy matching. A
token is required for a private repo; `GitHubToken.resolve` tries an
explicit param, then `$GITHUB_TOKEN`, then `gh auth token` (handy since a
dev machine often already has `gh` authenticated) before giving up. Every
failure mode — no token, rate limit, network error — surfaces as
`GitHubIssuesError.unavailable`, which `feedback.submit` treats as "skip
the check" rather than a hard failure: **graceful degradation is load-
bearing here**, not an edge case to tolerate. When a duplicate *is* found,
`feedback.submit` deletes the local entry and returns without opening
anything — re-reporting an already-filed issue was treated as strictly
worse than occasionally missing a real duplicate due to the simple
heuristic.

**Why elicitation breaks the "everything forwards to the dispatcher"
rule.** `uictl_feedback_submit` (`MCP/FeedbackSubmission.swift`) is the one
capability whose logic doesn't live in `CommandDispatcher` — `MCP.Server`'s
`requestElicitation(...)` (form and URL modes; vendored SDK,
`.build/checkouts/swift-sdk/Sources/MCP/Server/Server.swift`) only exists
on the live `Server` object inside the `uictl mcp` process, which is
talking to a real MCP client over stdio. The daemon process has no
connection to any MCP client at all (it only speaks the Unix-socket
protocol to `DaemonClient`), so it structurally cannot be the one to call
it. `MCPServer.swift`'s `CallTool` handler special-cases this one tool
name instead of forwarding it through the generic `toolDefinitions` loop;
`FeedbackSubmission.handle` then talks back to the daemon via ordinary
`DaemonClient.send` calls (`feedback.get`, `.checkDuplicates`, `.update`,
`.buildUrl`, `.markSubmitted`, and `.submit` as the fallback) for
everything that *isn't* elicitation-specific.

The flow: check for a duplicate first (skip the rest entirely if found) →
form-mode elicitation to review/edit title+body → URL-mode elicitation
handing the client the pre-filled GitHub URL. If either elicitation isn't
supported (or the human doesn't respond), it falls back to the same
non-interactive path `feedback submit` uses from the CLI — opening the URL
directly via `NSWorkspace.shared.open` on the daemon's own machine — rather
than failing the tool call outright.

**The SDK has no elicitation timeout, and `withThrowingTaskGroup` didn't
work as a substitute.** `Server.Configuration.strict` (what would make a
missing client capability throw early) defaults to `false`, and
`sendAndAwait` has no timeout of its own — an elicitation-incapable or
unresponsive client would otherwise hang the tool call forever. The
obvious fix, racing the elicitation call against a `Task.sleep` inside a
`withThrowingTaskGroup`, was built and reproducibly did *not* work: logging
confirmed the timeout child task fired and threw right on schedule, but
`group.next()` never returned while the other child (the elicitation call,
never going to resolve since nothing was answering it) was still
outstanding — root cause not isolated, plausibly some interaction between
the vendored SDK's continuation-based `sendAndAwait` and task-group
child join/cancellation. The working replacement
(`FeedbackSubmission.swift`'s private `withTimeout`) avoids joining
entirely: two fully independent, un-grouped `Task`s race to resume a
single `NSLock`-guarded `CheckedContinuation`, so the loser (the
elicitation call, if the timeout wins) can just be silently abandoned —
this process never needs to wait on it again, unlike a task-group child.

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
one of those ids, or `null` if its center doesn't fall within any display's
bounds — rare, but possible for a mostly off-screen window
(`Displays.displayID(containing:)`, a synchronous `CGGetDisplaysWithPoint`
lookup on the window's center — deliberately not the `SCShareableContent`
API `Displays.list()` uses, since that requires an async round trip per call
and would be too slow to run once per window).

### Window-relative coordinates

`click`/`move`/`scroll`/`pixel` all take `"at"` as a global-Quartz point by
default. Passing `window` (a window id) or `app` (an app selector) alongside
`"at"` switches it to a window-relative point instead:
`CommandDispatcher.resolvePoint` re-resolves that window's *current* frame
via `WindowResolver.resolve` at call time — not from a cached/stale
screenshot — and adds `"at"` to `frame.origin`, i.e. the window's top-left
corner in the same global-Quartz, top-left/y-down space described above (if
both `window` and `app` are given, `window` wins). This is both a
multi-display convenience (no manual arithmetic against `uictl displays`'
bounds) and more robust to the window having moved since it was last
located.

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

Separately: uictl cannot reliably drive its **own** GUI (the activity log
window, see "Activity log window" below) via its own `click --element`/
`click --at`. `Accessibility.frame(of:)` against one of that window's own
AXUIElements — a self-referential query, the daemon's background accept
thread asking AppKit's in-process accessibility bridging about a view owned
by that same process's main thread — intermittently or consistently returns
no frame, and even a raw-coordinate `click --at` verified (via OCR) to land
exactly on the "Export JSON…" button did not trigger it, across several
repeated attempts including back-to-back double-clicks. Root cause not
isolated (candidates: main-thread affinity of in-process AX/view state,
something specific to an unbundled, `.accessory`-policy, `Process()`-spawned
app's window-server session) — but this is irrelevant to uictl's actual job
of driving *other* apps, which this session's testing exercised extensively
(TextEdit, Chrome, Terminal, etc.) with no such issue. A real mouse click
from a human never goes through any of uictl's code at all, so this caveat
only affects uictl-driving-uictl, not normal use.

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

The one exception to steps 2–4 being a thin forward: a capability that
needs the MCP `Server` object itself (elicitation, sampling, anything else
that only exists on the live client connection) can't live in
`CommandDispatcher` at all, since the daemon has no such connection. See
`uictl_feedback_submit`/`MCP/FeedbackSubmission.swift` under "Feedback
submission & MCP elicitation" for the pattern: special-case the tool name
in `MCPServer.swift`'s `CallTool` handler instead of registering it in the
generic forwarding loop, and have that handler call back into the
dispatcher via ordinary `DaemonClient.send` for the non-elicitation parts.
