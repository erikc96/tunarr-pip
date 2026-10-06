# tunarr-pip

A picture-in-picture TV player for macOS. Press a key and a [Tunarr](https://github.com/chrisbenincasa/tunarr) channel starts playing in a small borderless window that floats in the corner of your screen, above everything else. You can flip channels the way you would on an old TV, with static on screen while the next channel tunes in.

It's a [Hammerspoon](https://www.hammerspoon.org) module that drives [mpv](https://mpv.io). It works with any Tunarr server that sits behind HTTPS with basic auth (a username and password).

## Keys

| Key | What it does |
|---|---|
| **⌥1** … **⌥8** | Play channel 1–8. Press the same key again to hide the player, and again to bring it back |
| **⌥]** / **⌥[** | Channel up / down (goes back to the start after the last channel) |
| **⌥\\** | Random channel |
| **⌥9** | Channel list, with what's on each channel right now (type to search) |
| **⌥0** | Turn it off |
| **⌥V** | VHS store in the Fuzz panel (needs a craigo.art/tv account, see below) |

Inside the player you can use mpv's own keys: **m** mutes, **9**/**0** change the volume, **f** goes fullscreen. You can drag the player to move it.

A channel takes 3–4 seconds to start. Static fills the player while it loads, and whenever the stream stalls. A hidden player keeps the stream running (muted) for 15 minutes, so bringing it back within that time is instant.

## Setup

You need a Mac, [Homebrew](https://brew.sh), and a Tunarr address, username and password from whoever runs the server.

**1. Install Hammerspoon and mpv.** In Terminal:

```sh
brew install --cask hammerspoon
brew install mpv
```

**2. Start Hammerspoon.** Open it from Applications. When it asks, give it Accessibility access (System Settings → Privacy & Security → Accessibility). This is what lets it respond to the keys. In its preferences, tick **Launch Hammerspoon at login**.

**3. Download this module** into Hammerspoon's config folder:

```sh
git clone https://github.com/erikc96/tunarr-pip ~/.hammerspoon/tunarr_pip
```

**4. Save your password in the Keychain.** Replace `YOUR_USERNAME` with your username. It asks for the password and doesn't show it as you type:

```sh
security add-generic-password -s tunarr-pip -a YOUR_USERNAME -w
```

**5. Tell Hammerspoon to load it.** Open (or create) `~/.hammerspoon/init.lua`:

```sh
open -a TextEdit ~/.hammerspoon/init.lua   # if it doesn't exist: touch ~/.hammerspoon/init.lua first
```

Add these lines, using your server address and username:

```lua
tunarrPip = require('tunarr_pip').setup({
  baseUrl = 'https://tunarr.example.com',
  user = 'YOUR_USERNAME',
})
```

**6. Reload.** Click the Hammerspoon icon in the menu bar and choose **Reload Config**. Then press **⌥1**.

## Options

Any setting in `M.config` at the top of `init.lua` can go in `setup({...})`. For example:

```lua
tunarrPip = require('tunarr_pip').setup({
  baseUrl = 'https://tunarr.example.com',
  user = 'YOUR_USERNAME',
  width = 640, height = 360,   -- player size in points
  upKey = '=', downKey = '-',  -- ⌥= / ⌥- for channel up/down
  randomKey = nil,             -- no random key
  warmMinutes = 5,             -- how long a hidden player stays connected
})
```

Hammerspoon takes over the keys, so while it runs **⌥[**, **⌥]** and **⌥\\** no longer type “ ‘ «, and **⌥0–9** no longer type º¡™£¢∞§¶•ª. If you type any of those, move the player to other keys as shown above. Set a key to `nil` to turn it off.

## craigo.art/tv club and VHS (optional)

If you have a [craigo.art/tv](https://craigo.art/tv/) account, the player can count as watching there too:

- **Fuzz in the menu bar.** The mascot's face shows its mood (dancing, fed, peckish, hungry, sad, static) and the number next to it is your streak. Click it to open the Fuzz panel.
- **The Fuzz panel** docks beside the player (or in its corner when nothing's playing) and floats over other windows. CLUB has Fuzz (click to pet), your streak, today's minutes, the squad streak, who's on now (click a channel to join), friends, weekly awards, top channels and trophies. Drag it somewhere else and it stays there until you close it. Esc closes it.
- **Watch time.** Every minute a channel or tape really plays (not paused, loading or hidden), the player tells the site, which feeds your streak, trophies and Fuzz. Stopping the player marks you as not watching.
- **⌥V opens the panel's VHS tab**, the CRAIGO VIDEO store: cover art, with shelves for new arrivals, movies, TV and half-watched tapes, and a search box. Pick a show to choose an episode (the next one is marked). Tapes play in the same player, pick up where you stopped, and when one plays to the end you get BE KIND, REWIND. Hiding the player pauses a tape.

Save your craigo.art/tv password in the Keychain:

```sh
security add-generic-password -s craigo-tv -a YOUR_TV_USERNAME -w
```

and add two lines to `setup({...})`:

```lua
  tvUrl = 'https://craigo.art/tv',
  tvUser = 'YOUR_TV_USERNAME',
```

## Updating

```sh
git -C ~/.hammerspoon/tunarr_pip pull
```

Then choose **Reload Config** from the Hammerspoon menu.

## Troubleshooting

- **Nothing happens when I press ⌥1.** Hammerspoon needs Accessibility access (step 2). Open its **Console** from the menu bar icon and look for red errors.
- **"no Keychain password for …"** The username in `setup()` must match the one you gave in step 4 exactly.
- **"stream ended (…)" / "Tunarr unreachable (HTTP 401)"** The password is wrong. Delete it with `security delete-generic-password -s tunarr-pip -a YOUR_USERNAME`, then repeat step 4.
- **HTTP 403** Your login works, but it isn't allowed to do that. Ask whoever runs the server.
- **Endless static** The channel isn't starting on the server. Try another channel, and tell whoever runs the server.

## Uninstall

```sh
rm -rf ~/.hammerspoon/tunarr_pip
security delete-generic-password -s tunarr-pip -a YOUR_USERNAME
```

Then remove the `tunarrPip = …` lines from `~/.hammerspoon/init.lua`.

## License

MIT
