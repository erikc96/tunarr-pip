--------------------------------
-- Tunarr picture-in-picture
--
-- opt-1 … opt-8  play that channel in a floating mini player; pressing the
--                key for the channel already showing hides/shows it
-- opt-9          channel picker (every channel + what's on now)
-- opt-0          stop and drop the stream
-- opt-] / opt-[  channel up / down (wraps)
-- opt-\         random channel
--
-- TV static (static.lua, run inside mpv) covers the player while a channel
-- loads and whenever the stream stalls.
--
-- Setup (see README.md): in ~/.hammerspoon/init.lua
--   require('tunarr_pip').setup({ baseUrl = 'https://…', user = 'you' })
-- with the password in the Keychain under service 'tunarr-pip'.
--
-- A cold channel takes ~4s to first frame; one watched in the last 10 min
-- ~3s (Tunarr keeps up to 2 idle transcodes running, idleSessionLingerSeconds).
-- Hiding keeps the stream playing muted for warmMinutes, so toggling back
-- within that window is instant. Inside the player the usual
-- mpv keys work (m mute, 9/0 volume, f fullscreen); drag it to move it.
--------------------------------
local M = {}

-- Defaults; setup() overrides any of these.
M.config = {
  baseUrl = nil,   -- Tunarr behind HTTPS basic auth, e.g. 'https://tunarr.example.com'
  user = nil,      -- basic-auth user; password in the Keychain (service 'tunarr-pip')
  canaryUrl = nil, -- optional: warn hourly if this URL answers (a port that must stay closed)
  channelKeys = { '1', '2', '3', '4', '5', '6', '7', '8' }, -- opt-N -> channel N
  pickerKey = '9',
  stopKey = '0',
  upKey = ']',
  downKey = '[',
  randomKey = '\\',
  width = 480,  -- points
  height = 270,
  margin = 16,  -- from the screen's bottom-right corner (clear of the Dock)
  warmMinutes = 15,
  mpv = nil,       -- default: Homebrew's mpv (Apple silicon or Intel)
}

local SOCKET = '/tmp/tunarr-pip.sock'
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/') -- this repo's folder

local AUTH, HEADERS -- set by setup()

local task = nil       -- running mpv hs.task
local current = nil    -- channel number it's playing
local last = nil       -- last channel played, for channel up/down after a stop
local numbers = {}     -- sorted channel numbers, for up/down/random
local hidden = false
local stopping = false -- set while we quit mpv on purpose
local coolTimer = nil  -- quits mpv after warmMinutes hidden
local placeTimer = nil

local function streamUrl(n)
  return string.format('%s/stream/channels/%d.ts', M.config.baseUrl, n)
end

local function running()
  return task ~= nil and task:isRunning()
end

local function ipc(cmd)
  if not running() then return end
  local json = hs.json.encode({ command = cmd })
  hs.task.new('/bin/sh', nil, { '-c',
    "printf '%s\\n' \"$1\" | /usr/bin/nc -U -w 1 " .. SOCKET, 'sh', json }):start()
end

local function mpvApp()
  return running() and hs.application.applicationForPID(task:pid())
end

local function cancelCool()
  if coolTimer then coolTimer:stop(); coolTimer = nil end
end

function M.stop()
  cancelCool()
  if running() then
    stopping = true
    local t = task
    ipc({ 'quit' })
    -- Fall back to SIGTERM if mpv didn't take the quit.
    hs.timer.doAfter(1.5, function()
      if t:isRunning() then t:terminate() end
    end)
  end
  task, current, hidden = nil, nil, false
end

-- For debugging/tests: what the module thinks is going on.
function M.state()
  local app = mpvApp()
  local win = app and app:allWindows()[1]
  return {
    pid = running() and task:pid() or nil,
    channel = current,
    hidden = hidden,
    frame = win and win:frame().table or nil,
  }
end

-- Pin the window to the bottom-right of the visible frame (clear of the Dock),
-- since mpv's --geometry offsets are relative to the full screen.
local function place()
  if placeTimer then placeTimer:stop() end
  local tries = 0
  placeTimer = hs.timer.doEvery(0.05, function()
    tries = tries + 1
    local app = mpvApp()
    local win = app and app:allWindows()[1]
    if win then
      local c = M.config
      local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
      local f = screen:frame()
      win:setFrame({
        x = f.x + f.w - c.width - c.margin,
        y = f.y + f.h - c.height - c.margin,
        w = c.width,
        h = c.height,
      }, 0)
    end
    if win or tries > 60 then
      placeTimer:stop(); placeTimer = nil
    end
  end)
end

local function start(n)
  local c = M.config
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local scale = (screen:currentMode() or {}).scale or 2
  local args = {
    '--no-config',
    '--no-terminal', -- hs.task never drains stdout; a full pipe freezes mpv
    '--title=Tunarr ch' .. n,
    '--force-window=immediate', -- window appears before the stream does
    '--ontop', '--no-border', '--on-all-workspaces',
    -- mpv applies --geometry in backing pixels when the video starts, so
    -- scale points to pixels or it lands half size on Retina.
    string.format('--geometry=%dx%d-%d-%d', c.width * scale, c.height * scale,
      c.margin * scale, c.margin * scale),
    '--keepaspect-window=no',
    '--hwdec=videotoolbox',
    '--profile=low-latency',
    '--demuxer-lavf-analyzeduration=0.5',
    '--stream-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',
    '--input-ipc-server=' .. SOCKET,
    '--script=' .. DIR .. '/static.lua',
    '--http-header-fields=Authorization: ' .. AUTH,
    '--keep-open=no',
    streamUrl(n),
  }
  local t
  t = hs.task.new(c.mpv, function(exitCode)
    -- Player closed (q, window closed, or stream died). Ignore exits from a
    -- player we already replaced.
    if task ~= t and task ~= nil then return end
    cancelCool()
    task, current, hidden = nil, nil, false
    if exitCode ~= 0 and not stopping then
      hs.alert.show('Tunarr PiP: stream ended (' .. tostring(exitCode) .. ')')
    end
    stopping = false
  end, args)
  task, current, hidden = t, n, false
  task:start()
  place()
end

local function hide()
  ipc({ 'set_property', 'mute', true })
  local app = mpvApp()
  if app then app:hide() end
  hidden = true
  cancelCool()
  coolTimer = hs.timer.doAfter(M.config.warmMinutes * 60, M.stop)
end

local function show()
  cancelCool()
  local app = mpvApp()
  if app then
    app:unhide()
    local win = app:mainWindow()
    if win then win:raise() end
  end
  ipc({ 'set_property', 'mute', false })
  hidden = false
end

-- Switch the open player to another channel (same window, ~3s to tune).
local function switch(n)
  ipc({ 'loadfile', streamUrl(n), 'replace' })
  ipc({ 'set_property', 'title', 'Tunarr ch' .. n })
  current = n
  show()
end

function M.play(n)
  last = n
  if not running() then
    start(n)
  elseif current ~= n then
    switch(n)
  elseif hidden then
    show()
  else
    hide()
  end
end

--------------------------------
-- Channel up/down/random
--------------------------------

-- Refresh the channel list, then call fn (if given) once it's known.
local function loadNumbers(fn)
  hs.http.asyncGet(M.config.baseUrl .. '/api/channels', HEADERS, function(status, body)
    local channels = status == 200 and hs.json.decode(body) or nil
    if channels then
      numbers = {}
      for i, ch in ipairs(channels) do numbers[i] = ch.number end
      table.sort(numbers)
    end
    if fn then
      if #numbers > 0 then fn() else hs.alert.show('Tunarr unreachable (HTTP ' .. status .. ')') end
    end
  end)
end

-- Act on the cached list at once (tuning shouldn't wait on HTTP), refreshing
-- it in the background; only the first press waits for the list.
local function withNumbers(fn)
  if #numbers == 0 then loadNumbers(fn) else fn(); loadNumbers() end
end

-- Next channel after `from` in direction dir (+1/-1), wrapping; `from` may be
-- a number that no longer exists.
function M.step(dir)
  withNumbers(function()
    local from = current or last
    local k = #numbers
    if not from then
      M.play(numbers[dir > 0 and 1 or k])
      return
    end
    for i = 1, k do
      local j = dir > 0 and i or k + 1 - i
      if (dir > 0 and numbers[j] > from) or (dir < 0 and numbers[j] < from) then
        M.play(numbers[j])
        return
      end
    end
    M.play(numbers[dir > 0 and 1 or k])
  end)
end

function M.random()
  withNumbers(function()
    local pool = {}
    for _, n in ipairs(numbers) do
      if n ~= current then pool[#pool + 1] = n end
    end
    if #pool > 0 then M.play(pool[math.random(#pool)]) end
  end)
end

--------------------------------
-- Picker
--------------------------------
local chooser = nil

local function describe(np)
  if type(np) ~= 'table' or not np.title then return nil end
  if np.subtype == 'episode' and np.grandparent and np.grandparent.title then
    local se = ''
    if np.parent and np.parent.index and np.episodeNumber then
      se = string.format(' S%02dE%02d', np.parent.index, np.episodeNumber)
    end
    return np.grandparent.title .. se .. ' – ' .. np.title
  end
  return np.title
end

local function loadPickerRows()
  local base = M.config.baseUrl
  hs.http.asyncGet(base .. '/api/channels', HEADERS, function(status, body)
    if status ~= 200 then
      chooser:choices({ { text = 'Tunarr unreachable (HTTP ' .. status .. ')', number = -1 } })
      return
    end
    local channels = hs.json.decode(body) or {}
    table.sort(channels, function(a, b) return a.number < b.number end)
    local rows = {}
    for i, ch in ipairs(channels) do
      rows[i] = {
        text = string.format('%s%d  %s', ch.number == current and '▶ ' or '', ch.number, ch.name),
        subText = '…',
        number = ch.number,
      }
    end
    M.pickerRows = rows -- for debugging/tests
    chooser:choices(rows)
    -- Fill in what's on now as each answer arrives.
    for i, ch in ipairs(channels) do
      hs.http.asyncGet(base .. '/api/channels/' .. ch.id .. '/now_playing', HEADERS,
        function(s, b)
          rows[i].subText = (s == 200 and describe(hs.json.decode(b))) or ''
          if chooser:isVisible() then chooser:choices(rows) end
        end)
    end
  end)
end

function M.pickerVisible() return chooser ~= nil and chooser:isVisible() end

function M.pick()
  if not chooser then
    chooser = hs.chooser.new(function(choice)
      if choice and choice.number and choice.number >= 0 then
        M.play(choice.number)
      end
    end)
    chooser:placeholderText('Tunarr channel…')
    chooser:searchSubText(true)
  end
  chooser:choices({ { text = 'Loading channels…', number = -1 } })
  chooser:show()
  loadPickerRows()
end

--------------------------------
-- Setup
--------------------------------

local function bind(key, fn)
  if key then hs.hotkey.bind({ 'alt' }, key, fn) end
end

function M.setup(opts)
  local c = M.config
  for k, v in pairs(opts or {}) do c[k] = v end
  assert(c.baseUrl and c.user, 'tunarr_pip.setup: set baseUrl and user')
  c.baseUrl = c.baseUrl:gsub('/+$', '')
  c.mpv = c.mpv or (hs.fs.attributes('/opt/homebrew/bin/mpv') and '/opt/homebrew/bin/mpv' or '/usr/local/bin/mpv')

  local pw, ok = hs.execute(string.format(
    "/usr/bin/security find-generic-password -s tunarr-pip -a '%s' -w", c.user))
  if not ok then
    hs.alert.show('Tunarr PiP: no Keychain password for ' .. c.user .. ' (see README)', 8)
    return M
  end
  AUTH = 'Basic ' .. hs.base64.encode(c.user .. ':' .. pw:gsub('%s+$', ''))
  HEADERS = { Authorization = AUTH }

  -- A Hammerspoon reload forgets the running player; quit any leftover one so
  -- the next hotkey press doesn't start a second.
  hs.task.new('/bin/sh', nil, { '-c',
    [[printf '{"command":["quit"]}\n' | /usr/bin/nc -U -w 1 ]] .. SOCKET }):start()

  for i, key in ipairs(c.channelKeys) do
    local n = tonumber(key) or i
    bind(key, function() M.play(n) end)
  end
  bind(c.pickerKey, M.pick)
  bind(c.stopKey, M.stop)
  bind(c.upKey, function() M.step(1) end)
  bind(c.downKey, function() M.step(-1) end)
  bind(c.randomKey, M.random)
  loadNumbers()

  if c.canaryUrl then
    M.canary = hs.timer.doEvery(3600, function()
      hs.http.asyncGet(c.canaryUrl, nil, function(status)
        if status > 0 then
          hs.notify.new({ title = 'Tunarr port reopened', informativeText = c.canaryUrl .. ' answered ' .. status }):send()
        end
      end)
    end)
  end
  return M
end

return M
