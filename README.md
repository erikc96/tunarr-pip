# tunarr-pip

A picture-in-picture TV player for macOS. Press a key and a [Tunarr](https://github.com/chrisbenincasa/tunarr) channel starts playing in a small borderless window that floats in the corner of your screen, above everything else. You can flip channels the way you would on an old TV, with static on screen while the next channel tunes in.

It is two small background programs and a few keys. `tunarrd` (Python, standard library only) drives [mpv](https://mpv.io) and talks to the servers; `tunarr-ui` (one Swift file) is the Fuzz menu-bar item and panel; [Hammerspoon](https://www.hammerspoon.org) only binds the keys, each one a single async request to `tunarrd`, so a slow player can never freeze your keyboard. It works with any Tunarr server that sits behind HTTPS with basic auth (a username and password).

## Keys

| Key | What it does |
|---|---|
| **⌥1** … **⌥8** | Play channel 1–8. Press the same key again to hide the player, and again to bring it back |
| **⌥]** / **⌥[** | Channel up / down (goes back to the start after the last channel) |
| **⌥\\** | Random channel |
| **⌥=** / **⌥-** | Volume up / down |
| **⌥9** | Find a channel: type to search (ranked by fzf) the list of channels and what's on each right now. With a tv.craigoslist.com/tv account it opens in the Fuzz panel's TV tab |
| **⌥0** | Turn it off |
| **⌥⇧V** | VHS store in the Fuzz panel (needs a tv.craigoslist.com/tv account, see below) |
| **⌥⇧N** | Start what the live channel is showing as a VHS tape, from the beginning (needs a tv.craigoslist.com/tv account) |

Inside the player you can use mpv's own keys: **m** mutes, **9**/**0** change the volume, **f** goes fullscreen. You can drag the player to move it. With a tv.craigoslist.com/tv account, moving the mouse over the player shows an X-Ray banner (what's on, cast), and clicking it opens the Fuzz panel's X-RAY tab.

A channel takes 3–4 seconds to start. Static fills the player while it loads, and whenever the stream stalls. A hidden player keeps the stream running (muted) for 15 minutes, so bringing it back within that time is instant.

## Setup

You need a Mac, [Homebrew](https://brew.sh), and a Tunarr address, username and password from whoever runs the server.

**1. Install the tools.** In Terminal:

```sh
brew install --cask hammerspoon
brew install mpv fzf python
```

**2. Start Hammerspoon.** Open it from Applications and give it Accessibility access (System Settings → Privacy & Security → Accessibility), so it can see the keys. Tick **Launch Hammerspoon at login** in its preferences.

**3. Get this repo and build the panel app.**

```sh
git clone https://github.com/erikc96/tunarr-pip ~/projects/tunarr-pip
bash ~/projects/tunarr-pip/tunarr-ui/build.sh
```

**4. Save your password in the Keychain.** Replace `YOUR_USERNAME` with your username. It asks for the password and doesn't show it as you type:

```sh
security add-generic-password -s tunarr-pip -a YOUR_USERNAME -w
```

**5. Write the config.** Create `~/Library/Application Support/tunarr-pip/config.json`:

```json
{ "baseUrl": "https://tunarr.example.com", "user": "YOUR_USERNAME" }
```

**6. Start the player and panel.** This installs two LaunchAgents (`com.erik.tunarr-pip.daemon` and `.ui`) that start at login and restart if they stop:

```sh
bash ~/projects/tunarr-pip/launchd/install.sh
```

**7. Give Hammerspoon the keys.** Link the key module into Hammerspoon's folder and load it from `~/.hammerspoon/init.lua`:

```sh
ln -s ~/projects/tunarr-pip/hammerspoon/tunarr_keys.lua ~/.hammerspoon/tunarr_keys.lua
```

```lua
tunarrPip = require('tunarr_keys').setup({ channelKeys = { '1', '2', '3' } }) -- ⌥1 ⌥2 ⌥3 play channels 1-3; {} for none
```

Choose **Reload Config** from the Hammerspoon menu, then press **⌥9**.

## Options

Everything about the player goes in `config.json`; `tunarrd` reads it at start (restart it with `launchctl kickstart -k gui/$(id -u)/com.erik.tunarr-pip.daemon`). The keys are in `tunarr_keys.lua`'s `setup({...})` (`channelKeys`, and `pickerKey`, `stopKey`, `upKey`, `downKey`, `randomKey`, `volUpKey`, `volDownKey`, `volStep`).

```json
{
  "baseUrl": "https://tunarr.example.com",
  "user": "YOUR_USERNAME",
  "width": 640, "height": 360,
  "warmMinutes": 5,
  "volStep": 5,
  "mpvExtra": ["--volume=30"],
  "cast": [
    { "name": "VAN", "rx": "van", "wake": "my-van-topic" },
    { "name": "IPAD (SIDECAR)", "screen": "Sidecar" }
  ]
}
```

`cast` is the panel's CAST list: an entry with `rx` opens a browser receiver (`tvUrl/?cast=<rx>`; `wake` is an ntfy topic pushed when it isn't open), an entry with `screen` plays full screen on that display (running `screenScript` first if the display isn't connected yet). Also: `canaryUrl` (warn hourly if this URL answers), `streamViaTv` (play through the tv site's stream, which beats a bad direct route), `fzf`, `mpv`.

Hammerspoon takes over the keys, so while it runs **⌥[**, **⌥]** and **⌥\\** no longer type “ ‘ «, and **⌥0–9** no longer type º¡™£¢∞§¶•ª. Change the key names in `setup({...})` if you type any of those.

## tv.craigoslist.com/tv club and VHS (optional)

If you have a [tv.craigoslist.com/tv](https://tv.craigoslist.com/tv/) account, the player can count as watching there too:

- **Fuzz in the menu bar.** The mascot's face shows its mood (dancing, fed, peckish, hungry, sad, static) and the number next to it is your streak. Click it to open the Fuzz panel.
- **The Fuzz panel** has four tabs. TV is a remote (channel up/down, random, surf, hide/show, volume, mini player, MAX, off, PLAY IN VHS, cast) above every channel with what's on now (click one to tune). It docks beside the player (or in its corner when nothing's playing) and floats over other windows. CLUB has Fuzz (click to pet), your streak, today's minutes, the squad streak, who's on now (click a channel to join), friends, weekly awards, top channels and trophies. X-RAY has the cast, crew and Wikipedia summary for what's on here or on the cast receiver. Drag it somewhere else and it stays there until you close it. Esc closes it.
- **Watch time.** Every minute a channel or tape really plays (not paused, loading or hidden), the player tells the site, which feeds your streak, trophies and Fuzz. Stopping the player marks you as not watching.
- **⌥⇧V opens the panel's VHS tab**, the CRAIGO VIDEO store: cover art, with shelves for new arrivals, movies, TV and half-watched tapes, and a search box. Pick a show to choose an episode (the next one is marked). Tapes play in the same player, pick up where you stopped, and when one plays to the end you get BE KIND, REWIND. Hiding the player pauses a tape.

**Keys in the panel** (vim style; press **?** in the panel for this list): **j/k** move over anything clickable, **h/l** move across the VHS shelf (**h** backs out of a show), **gg/G** top and bottom, **Ctrl-d/u/f/b** page, **Enter**/**o** play or open, **/** search (Esc leaves the box, Ctrl-n/p move from it; **\\** on an empty search is random), **t/c/v/x** or **H/L**/**gt/gT** tabs, **`<`/`>`** VHS shelves, **]/[** channel up/down, **r** or **\\** random, **w** surf, **space** hide/show, **=/-** volume, **n** play what's on now as a tape, **f** maximize/restore the player, **p** mini player, **C** cast, **X** off, **q**/**Esc** close.

Save your tv.craigoslist.com/tv password in the Keychain:

```sh
security add-generic-password -s craigo-tv -a YOUR_TV_USERNAME -w
```

and add two lines to `config.json`:

```json
  "tvUrl": "https://tv.craigoslist.com/tv",
  "tvUser": "YOUR_TV_USERNAME",
```

## Watching on a TV

The same channels play in a browser at [tv.craigoslist.com/tv](https://tv.craigoslist.com/tv/) (with an account), including on an Amazon Fire TV Stick in Fully Kiosk Browser. That page isn't part of this repo; ask whoever runs your server for its help pages.

## Updating

```sh
git -C ~/projects/tunarr-pip pull
bash ~/projects/tunarr-pip/tunarr-ui/build.sh
bash ~/projects/tunarr-pip/launchd/install.sh
```

Then choose **Reload Config** from the Hammerspoon menu if `hammerspoon/tunarr_keys.lua` changed.

## Troubleshooting

- **Nothing happens when I press ⌥9.** Check that `tunarrd` is running: `launchctl list | grep tunarr-pip`, and read `~/Library/Logs/tunarr-pip-daemon.log`. Hammerspoon shows "Tunarr: no token file" when the daemon has never started, and needs Accessibility access (step 2). Open its **Console** from the menu bar icon and look for red errors.
- **"no keychain password"** in the daemon log: the `user` in `config.json` must match the one you gave in step 4 exactly.
- **"stream ended (…)" / "Tunarr unreachable (HTTP 401)"** The password is wrong. Delete it with `security delete-generic-password -s tunarr-pip -a YOUR_USERNAME`, then repeat step 4 and restart the daemon.
- **HTTP 403** Your login works, but it isn't allowed to do that. Ask whoever runs the server.
- **Endless static** The channel isn't starting on the server. Try another channel, and tell whoever runs the server.
- **Is it alive?** `curl -H "X-Tunarr-Token: $(cat ~/Library/Application\ Support/tunarr-pip/token)" http://127.0.0.1:7849/state`

## Uninstall

```sh
bash ~/projects/tunarr-pip/launchd/install.sh --uninstall
rm -rf ~/Library/Application\ Support/tunarr-pip ~/.hammerspoon/tunarr_keys.lua
security delete-generic-password -s tunarr-pip -a YOUR_USERNAME
```

Then remove the `tunarrPip = …` lines from `~/.hammerspoon/init.lua`.

## Development

Tests: `python3 -W ignore -m unittest discover -s tunarrd/tests` (they start their own daemons and stub servers, so they run beside the installed one) and `tunarr-ui/build/tunarr-ui --selftest`. The old all-Hammerspoon player is `init.lua` in this repo, kept for reference only; the installed player does not load it.
