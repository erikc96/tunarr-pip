# Step 2 evidence: does mpv move/hide its own window over IPC? (2026-11-19, mpv 0.42.0, one built-in display 1512x982 pt)

Method: mpv with `av://lavfi:testsrc`, `--no-audio` (silent), startup `--geometry=960x540-32-32` (pixels, Retina x2),
IPC socket; window frame/onscreen read from `CGWindowListCopyWindowInfo` (`passtest/winlist.swift`, owner pid, layer 3 window).

| Action over IPC | Window before | Window after | Verdict |
|---|---|---|---|
| (startup `--geometry=960x540-32-32`) | none | x=1016 y=696 w=480 h=270 | matches `place()`'s target (1512-480-16, 33+949-270-16) |
| `set_property geometry 480x270-16-16` | 1016,696 480x270 | 1136,764 240x135 | size changed (pixels->points), **position not re-anchored** (resized about the centre) |
| `set_property geometry 320x180+100+100` | 1136,764 240x135 | 1176,787 160x90 | **position ignored** (+100+100 not applied) |
| `set_property window-minimized yes` | onscreen=true | onscreen=false (frame kept) | **works** |
| `set_property window-minimized no` | onscreen=false | onscreen=true | **works** |
| `fullscreen yes` then `no` | 1016,697 480x270 | 0,0 1512x982, then back 1016,697 | mpv restores the previous windowed frame |

Verdict (design section 3 step 2): `window-minimized` is good enough for hide/show. Runtime `geometry` does NOT reposition a
live window, so placement of an existing window is not possible over IPC; startup `--geometry` (plus mpv's own
`--macos-geometry-calculation=visible`) places a new window correctly. Consequence, decided here:
- Start and switch need no placement code (startup geometry; the window keeps its frame across `loadfile`).
- `pip()` back from another screen / re-pin after a drag: **relaunch mpv** on the target screen (`--screen-name`), no
  Accessibility permission needed, ~3 s retune. A Swift AX `setFrame` in tunarr-ui is the alternative, but it needs a
  new Accessibility grant for a new app, which is exactly the class of thing being removed from Hammerspoon.
- Unverified (no second display here): `--screen-name` for Sidecar, CG order vs mpv screen index.
