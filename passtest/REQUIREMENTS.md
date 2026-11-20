# Tunarr PiP out of Hammerspoon: requirements and pass test

Source: ~/.local/state/spawn-results/hs-team/tv-design.md (section 4), brief ~/life/docs/briefs/tv-out-of-hammerspoon.md.
Erik's ask (2026-11-19): "why do we have to actually have it running as a sub process of hammerspoon?"
Scope honesty: this move does not claim to fix the recorded 67 s / 104 s freezes (different causes). It removes
timers, taps, Accessibility calls and shell spawns from Hammerspoon's one main thread.

## Requirements
R1. Hammerspoon keeps only hotkeys, `hammerspoon://tunarr` and the opt-' chooser; each does one async POST (`tunarr_keys.lua`).
R2. `tunarrd` (Python stdlib) owns mpv, Tunarr/tv-site HTTP, beats, vibe, receivers, canary, tape state, Keychain reads.
R3. `tunarr-ui` (Swift) owns the Fuzz menu-bar item and the panel window; X-Ray moves into mpv (`osd-overlay`).
R4. Break overlay passthrough reads `state.json` via `hs.pathwatcher`; no IPC on the event-tap path.
R5. Each migration step leaves the player working and is undone by one line.
R6. `~/.hammerspoon/tunarr_pip` is removed with `yadm rm` (reaches the work Mac: portable, or a pending-work-mac item); README updated.
R7. Credentials only via Keychain (`/usr/bin/security`); no email address in any request; no kill of processes; no audible test audio.

## Pass test (run `passtest/hs-load.sh`; lines 1-5 are the Hammerspoon-load block)
1. Tunarr timers in Hammerspoon: 5 -> 0. (`package.loaded.tunarr_pip` nil; no `hs.timer` in tunarr files loaded by HS)
2. Tunarr event taps in Hammerspoon: 1 -> 0.
3. Accessibility calls from the player (applicationForPID / allWindows / setFrame): >0 -> 0.
4. Shell spawns (`/bin/sh` hs.task) from the player: >0 -> 0.
5. `hs -c` probes of tunarr_pip running: 1 -> 0; and no stall over 0.25 s attributable to the player in a 30-minute watch.

Erik-visible (the regression floor, 6-13): the 12 hotkeys answer < 250 ms; X-Ray; PiP through the forced-break overlay;
minute beats; warm hide/show; VHS resume survives kill -9 of tunarrd; panel docks/floats/Esc/search; processes
(`pgrep -fl 'tunarrd|tunarr-ui'` + mpv, both 0.0 % CPU by `top -l 2`).
Brief done-when: `test ! -e ~/.hammerspoon/tunarr_pip && test ! -s ~/life/bin/hs-lint-blocking.known && pgrep -f tunarrd`.
