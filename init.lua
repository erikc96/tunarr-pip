--------------------------------
-- Tunarr picture-in-picture
--
-- opt-1 … opt-8  play that channel in a floating mini player; pressing the
--                key for the channel already showing hides/shows it
-- opt-9          find a channel: the Fuzz panel's TV tab with its search box
--                focused, filtered by fzf (a plain picker without tvUrl)
-- opt-0          stop and drop the stream
-- opt-] / opt-[  channel up / down (wraps)
-- opt-\         random channel
-- opt-= / opt--  volume up / down
-- opt-shift-v    the Fuzz panel's VHS store: pick a Plex movie or episode
--
-- With tvUrl/tvUser set (a craigo.art/tv account), the player also counts as
-- watching there: it posts a beat every minute a channel or tape really plays,
-- which feeds streaks, trophies and Fuzz, the mascot. Fuzz lives in the menu
-- bar; clicking it opens the Fuzz panel (panel.html) beside the PiP.
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
  volUpKey = '=',
  volDownKey = '-',
  volStep = 5,
  width = 480,  -- points
  height = 270,
  margin = 16,  -- from the screen's bottom-right corner (clear of the Dock)
  warmMinutes = 15,
  mpv = nil,       -- default: Homebrew's mpv (Apple silicon or Intel)
  fzf = nil,       -- default: Homebrew's fzf; ranks the panel's channel search
  tvUrl = nil,     -- craigo.art/tv style site, e.g. 'https://craigo.art/tv'; enables the club and VHS
  tvUser = nil,    -- its login; password in the Keychain (service 'craigo-tv')
  vhsKey = { { 'alt', 'shift' }, 'v' }, -- opt-shift-v (another app often owns opt-v)
  menubar = true,  -- Fuzz in the menu bar (needs tvUrl)
}

local SOCKET = '/tmp/tunarr-pip.sock'
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/') -- this repo's folder

local AUTH, HEADERS -- set by setup()
local TVPW, COOKIE -- craigo.art/tv password and session cookie

local task = nil       -- running mpv hs.task
local current = nil    -- channel number it's playing
local last = nil       -- last channel played, for channel up/down after a stop
local numbers = {}     -- sorted channel numbers, for up/down/random
local hidden = false
local stopping = false -- set while we quit mpv on purpose
local coolTimer = nil  -- quits mpv after warmMinutes hidden
local placeTimer = nil
local fullScreen = nil -- hs.screen the player fills (playOn), or nil for PiP
local tape = nil       -- VHS tape playing: { key, title, duration, sid, pos }
local names = {}       -- channel number -> name

-- What the player loads: a Tunarr channel (basic auth) or a VHS tape (the
-- craigo.art/tv session cookie). Each source only gets its own credential.
local function chanSrc(n)
  return { channel = n, title = 'Tunarr ch' .. n, header = 'Authorization: ' .. AUTH,
    url = string.format('%s/stream/channels/%d.ts', M.config.baseUrl, n) }
end

local function running()
  return task ~= nil and task:isRunning()
end

-- Each call is its own connection, so commands that must arrive in order go
-- in one call: ipc(cmd1, cmd2, ...).
local function ipc(...)
  if not running() then return end
  local lines = {}
  for _, cmd in ipairs({ ... }) do lines[#lines + 1] = hs.json.encode({ command = cmd }) end
  local json = table.concat(lines, '\n')
  hs.task.new('/bin/sh', nil, { '-c',
    "printf '%s\\n' \"$1\" | /usr/bin/nc -U -w 1 " .. SOCKET, 'sh', json }):start()
end

-- Read mpv properties: fn({ prop = value, ... }), or fn(nil) if no player.
local function mpvGet(props, fn)
  if not running() then return fn(nil) end
  local lines = {}
  for i, p in ipairs(props) do
    lines[i] = hs.json.encode({ command = { 'get_property', p }, request_id = i })
  end
  hs.task.new('/bin/sh', function(_, out)
    local vals = {}
    for line in (out or ''):gmatch('[^\n]+') do
      local ok, r = pcall(hs.json.decode, line)
      if ok and type(r) == 'table' and r.request_id and props[r.request_id] then
        vals[props[r.request_id]] = r.data
      end
    end
    fn(vals)
  end, { '-c', "printf '%s\n' \"$1\" | /usr/bin/nc -U -w 1 " .. SOCKET, 'sh',
    table.concat(lines, '\n') }):start()
end

local function mpvApp()
  return running() and hs.application.applicationForPID(task:pid())
end

local function cancelCool()
  if coolTimer then coolTimer:stop(); coolTimer = nil end
end

local endTape, unbeat -- defined with the club below

function M.stop()
  cancelCool()
  endTape()
  unbeat()
  if running() then
    stopping = true
    local t = task
    ipc({ 'quit' })
    -- Fall back to SIGTERM if mpv didn't take the quit.
    hs.timer.doAfter(1.5, function()
      if t:isRunning() then t:terminate() end
    end)
  end
  task, current, hidden, fullScreen = nil, nil, false, nil
end

-- For debugging/tests: what the module thinks is going on.
function M.state()
  local app = mpvApp()
  local win = app and app:allWindows()[1]
  return {
    pid = running() and task:pid() or nil,
    channel = current,
    tape = tape and tape.key or nil,
    hidden = hidden,
    screen = fullScreen and fullScreen:name() or nil,
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
    local settled = false
    if win and not fullScreen then
      local c = M.config
      local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
      local f = screen:frame()
      local want = hs.geometry.rect(f.x + f.w - c.width - c.margin,
        f.y + f.h - c.height - c.margin, c.width, c.height)
      -- Keep at it for a moment: mpv may still move/resize the window
      -- (e.g. right after leaving fullscreen).
      if win:frame():equals(want) then
        settled = tries >= 10
      else
        win:setFrame(want, 0)
      end
    end
    if (win and (fullScreen or settled)) or tries > 60 then
      placeTimer:stop(); placeTimer = nil
    end
  end)
end

-- mpv's --fs-screen index for an hs.screen: both follow NSScreen order.
-- (By name fails: mpv appends an id, and macOS keeps windowed mpv off a
-- display to the left of the main one.)
local function screenIndex(s)
  for i, x in ipairs(hs.screen.allScreens()) do
    if x:id() == s:id() then return i - 1 end
  end
  return 0
end

local function start(src)
  local c = M.config
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local scale = (screen:currentMode() or {}).scale or 2
  local args = {
    '--no-config',
    '--no-terminal', -- hs.task never drains stdout; a full pipe freezes mpv
    '--title=' .. src.title,
    '--force-window=immediate', -- window appears before the stream does
    '--ontop', '--no-border', '--on-all-workspaces',
    -- mpv applies --geometry in backing pixels when the video starts, so
    -- scale points to pixels or it lands half size on Retina.
    string.format('--geometry=%dx%d-%d-%d', c.width * scale, c.height * scale,
      c.margin * scale, c.margin * scale),
    '--keepaspect-window=no',
    '--native-fs=no', -- no new Space
    fullScreen and '--fullscreen' or '--no-fullscreen',
    '--fs-screen=' .. (fullScreen and screenIndex(fullScreen) or 'current'),
    '--hwdec=videotoolbox',
    '--profile=low-latency',
    '--demuxer-lavf-analyzeduration=0.5',
    '--stream-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',
    '--input-ipc-server=' .. SOCKET,
    '--script=' .. DIR .. '/static.lua',
    '--http-header-fields=' .. src.header,
    '--keep-open=no',
    '--start=' .. (src.start and tostring(src.start) or 'none'),
    src.url,
  }
  local t
  t = hs.task.new(c.mpv, function(exitCode)
    -- Player closed (q, window closed, or stream died). Ignore exits from a
    -- player we already replaced.
    if task ~= t and task ~= nil then return end
    cancelCool()
    -- A tape that quit on its own may have been watched to the end.
    endTape(exitCode == 0 and not stopping)
    unbeat()
    task, current, hidden, fullScreen = nil, nil, false, nil
    if exitCode ~= 0 and not stopping then
      hs.alert.show('Tunarr PiP: stream ended (' .. tostring(exitCode) .. ')')
    end
    stopping = false
  end, args)
  task, current, tape, hidden = t, src.channel, src.tape, false
  task:start()
  place()
end

-- Hiding mutes a channel (live TV keeps going) and pauses a tape.
local function hide()
  ipc({ 'set_property', tape and 'pause' or 'mute', true })
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
  ipc({ 'set_property', tape and 'pause' or 'mute', false })
  hidden = false
end

-- Switch the open player to another channel or tape (same window, ~3s to tune).
local function switch(src)
  show() -- with the old source, so a paused tape unpauses
  endTape()
  ipc({ 'change-list', 'http-header-fields', 'set', src.header },
    { 'set_property', 'start', src.start and tostring(src.start) or 'none' },
    { 'set_property', 'pause', false },
    { 'loadfile', src.url, 'replace' },
    { 'set_property', 'title', src.title })
  current, tape = src.channel, src.tape
end

local function load(src)
  if running() then switch(src) else start(src) end
end

function M.play(n)
  last = n
  if not running() then
    start(chanSrc(n))
  elseif current ~= n then
    switch(chanSrc(n))
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
      for i, ch in ipairs(channels) do numbers[i] = ch.number; names[ch.number] = ch.name end
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

function M.pick()
  if M.find() then return end
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
-- craigo.art/tv: login, watch beats, Fuzz and the clubhouse
--------------------------------
local TROPHIES = { -- id, name, how (same list as the site)
  { 'first_tune', 'FIRST TUNE', 'watch anything' },
  { 'hour', 'PRIME TIME', 'an hour in one day' },
  { 'marathon', 'MARATHON', '4 hours in one day' },
  { 'surfer', "SURF'S UP", '5 channels in one day' },
  { 'explorer', 'EXPLORER', '10 different channels' },
  { 'night_owl', 'AFTER HOURS', 'watch after midnight' },
  { 'together', 'COUCH BUDDY', 'same channel as a friend, at the same time' },
  { 'requester', 'REQUEST LINE', 'ask the bot for something' },
  { 'streak3', 'ON A ROLL', '3-day streak' },
  { 'streak7', 'WEEKLONG', '7-day streak' },
  { 'streak30', 'SQUARE EYES', '30-day streak' },
  { 'rewind', 'BE KIND, REWIND', 'rewind a tape you finished' },
  { 'double_feature', 'DOUBLE FEATURE', '2 hours of tapes in one day' },
}

local function tvOn() return M.config.tvUrl ~= nil and TVPW ~= nil end

local function login(fn)
  hs.http.doAsyncRequest(M.config.tvUrl .. '/api/login', 'POST',
    hs.json.encode({ username = M.config.tvUser, password = TVPW }),
    { ['Content-Type'] = 'application/json' }, function(status, _, headers)
      COOKIE = nil
      for k, v in pairs(headers or {}) do
        if k:lower() == 'set-cookie' then COOKIE = tostring(v):match('(tv_session=[^;]+)') end
      end
      if status ~= 200 or not COOKIE then
        hs.alert.show('craigo.art/tv: login failed (HTTP ' .. tostring(status) .. ')')
      end
      fn(COOKIE ~= nil)
    end, 'ignoreLocalCache')
end

-- fn(status, decoded body); logs in first, and again once if the session expired.
local function tv(method, path, body, fn)
  fn = fn or function() end
  if not tvOn() then return fn(0) end
  local function go(retry)
    local h = { Cookie = COOKIE }
    if body then h['Content-Type'] = 'application/json' end
    hs.http.doAsyncRequest(M.config.tvUrl .. '/api/' .. path, method,
      body and hs.json.encode(body) or nil, h, function(status, b)
        if status == 401 and retry then
          return login(function(ok) if ok then go(false) else fn(401) end end)
        end
        local ok, data = pcall(hs.json.decode, b or '')
        fn(status, ok and data or nil, b)
      end, 'ignoreLocalCache')
  end
  if COOKIE then go(true) else login(function(ok) if ok then go(false) else fn(401) end end) end
end

local vibe, vibeRaw = nil, nil
local menu = nil
local loadVibe, panelPush -- below

local function trophyAlert(ids)
  if type(ids) ~= 'table' or #ids == 0 then return end
  local got = {}
  for _, id in ipairs(ids) do
    local name = id
    for _, t in ipairs(TROPHIES) do if t[1] == id then name = t[2] end end
    got[#got + 1] = name
  end
  hs.alert.show('★ TROPHY · ' .. table.concat(got, ' · '), 6)
  loadVibe()
end

-- Tapes remember where you stopped (hs.settings, like the site's localStorage).
local function posKey(k) return 'tunarr-pip.vhs.' .. k end
local function doneKey(k) return 'tunarr-pip.vhs.done.' .. k end

-- Leave the tape that's playing: save the spot, stop Plex's transcode, and if
-- it played to the end, rewind it (the BE KIND, REWIND trophy).
endTape = function(ended)
  local t = tape
  tape = nil
  if not t then return end
  tv('GET', 'vhs/stop?s=' .. t.sid)
  local finished = ended and t.pos and (not t.duration or t.pos >= t.duration - 180)
  if finished then
    hs.settings.set(posKey(t.key), nil)
    hs.settings.set(doneKey(t.key), true)
    hs.alert.show('◀◀ BE KIND, REWIND · THANKS ♥', 4)
    tv('POST', 'vhs/rewind', {}, function(s, r) if s == 200 and r then trophyAlert(r.trophies) end end)
  elseif t.pos and t.pos > 10 then
    hs.settings.set(posKey(t.key), math.floor(t.pos))
  end
end

local beating = false
unbeat = function()
  if beating then beating = false; tv('DELETE', 'beat') end
end

-- Every 15s: note the tape's position; once a minute that a channel or tape
-- really played (not paused, buffering or hidden), post a beat.
local lastBeat = 0
local function tick()
  if not running() then return end
  mpvGet({ 'core-idle', 'time-pos', 'duration' }, function(v)
    if not v then return end
    if tape and v['time-pos'] then
      tape.pos = v['time-pos']
      tape.duration = v.duration or tape.duration
      if math.floor(tape.pos) % 60 < 15 and tape.pos > 10 then
        hs.settings.set(posKey(tape.key), math.floor(tape.pos))
      end
    end
    local ch = tape and 0 or current
    if hidden or v['core-idle'] ~= false or not ch or os.time() - lastBeat < 58 then return end
    lastBeat = os.time()
    beating = true
    tv('POST', 'beat', { channel = ch, day = os.date('%Y-%m-%d'), late = os.date('*t').hour < 5 },
      function(s, r) if s == 200 and r then trophyAlert(r.trophies) end end)
  end)
end

-- Fuzz, drawn from the site's pixel art as a template image (dark pixels are
-- holes, so it follows the menu bar's light/dark look).
local FUZZ_BASE = { '..#....#..', '...#..#...', '..######..', '.########.', '', '.########.', '', '', '..##..##..' }
local FUZZ = { -- rows 5 (eyes), 7 and 8 (mouth); k is a dark pixel
  watching = { '.#k####k#.', '.#k####k#.', '..#kkkk#..' },
  happy = { '.#k####k#.', '.##k##k##.', '..##kk##..' },
  ok = { '.#k####k#.', '.##kkkk##.', '..######..' },
  hungry = { '.#k####k#.', '.###kk###.', '..##kk##..' },
  sad = { '.#k####k#.', '.###kk###.', '..#k##k#..' },
  static = { '.#k####k#.', '.##kkkk##.', '..######..' },
}
local MOODS = {
  watching = "FUZZ IS DANCING · SOMEONE'S TUNED IN",
  happy = 'FUZZ IS FED FOR TODAY',
  ok = 'FUZZ IS PECKISH · NOBODY HAS WATCHED TODAY',
  hungry = 'FUZZ IS HUNGRY · 2 DAYS WITHOUT TV',
  sad = 'FUZZ IS SAD · %d DAYS WITHOUT TV',
  static = 'FUZZ IS FADING INTO STATIC…',
}

local function fuzzIcon(mood)
  local rows = {}
  for i, r in ipairs(FUZZ_BASE) do rows[i] = r end
  local m = FUZZ[mood] or FUZZ.ok
  rows[5], rows[7], rows[8] = m[1], m[2], m[3]
  local P = 2 -- points per pixel
  local cv = hs.canvas.new({ x = 0, y = 0, w = 10 * P, h = 9 * P })
  for y, row in ipairs(rows) do
    for x = 1, #row do
      if row:sub(x, x) == '#' and not (mood == 'static' and math.random() < 0.45) then
        cv:appendElements({ type = 'rectangle', action = 'fill', fillColor = { white = 0, alpha = 1 },
          frame = { x = (x - 1) * P, y = (y - 1) * P, w = P, h = P } })
      end
    end
  end
  local img = cv:imageFromCanvas()
  cv:delete()
  return img
end

local function anyTape(v)
  for _, l in ipairs(v.live or {}) do if l.channel == 0 then return true end end
  return false
end

local function moodLine(m, v)
  if m.mood == 'watching' and anyTape(v) then return 'FUZZ IS WATCHING A TAPE · POPCORN OUT' end
  return string.format(MOODS[m.mood] or '', m.idle or 0)
end

loadVibe = function()
  if not tvOn() then return end
  tv('GET', 'vibe?day=' .. os.date('%Y-%m-%d'), nil, function(status, v, raw)
    if status ~= 200 or type(v) ~= 'table' or not v.mascot then return end
    vibe, vibeRaw = v, raw
    panelPush()
    M.vibe = v -- for debugging/tests
    if menu then
      menu:setIcon(fuzzIcon(v.mascot.mood), true)
      menu:setTitle(v.me.streak > 0 and tostring(v.me.streak) or '')
      menu:setTooltip(moodLine(v.mascot, v))
    end
  end)
end
M.refresh = function() loadVibe() end

--------------------------------
-- The Fuzz panel: a window docked beside the PiP with the clubhouse (CLUB)
-- and the VHS store (VHS). panel.html draws it; messages come back here.
--------------------------------
local panel, panelReady, panelTab = nil, false, 'tv'
local panelSet = nil   -- frame we last docked it to; a different one means it was dragged
local byKey = {}       -- tape key -> tape, for clicks from the panel
local shelfCache, shelfAt = nil, 0
local coverCache = {}

-- One JSON value as JavaScript source.
local function J(v) return hs.json.encode({ v }):sub(2, -2) end

local function js(fn, ...)
  if panel and panelReady then
    panel:evaluateJavaScript('app.' .. fn .. '(' .. table.concat({ ... }, ',') .. ')')
  end
end

local function nowText()
  if tape then return '▶ VHS' end
  if current and running() then return string.format('▶ CH %02d', current) end
  return ''
end

local function trophyTable()
  local t = {}
  for i, x in ipairs(TROPHIES) do t[i] = { x[1], x[2], x[3] } end
  return t
end

panelPush = function()
  if not (panel and panelReady and vibeRaw) then return end
  local n = {}
  for k, v in pairs(names) do n[tostring(k)] = v end
  js('vibe', vibeRaw, J(n), J(trophyTable()))
  js('now', J(nowText()))
end

local function note(t)
  t.pos = hs.settings.get(posKey(t.key))
  t.done = hs.settings.get(doneKey(t.key)) and true or nil
  byKey[t.key] = t
  return t
end

local function pushShelves()
  local list = {}
  for i, t in ipairs(shelfCache or {}) do list[i] = note(t) end
  js('shelves', #list > 0 and J(list) or '[]')
end

local function loadShelves()
  -- New arrivals first, then every movie and show.
  local lists, pending = {}, 3
  for i, shelf in ipairs({ 'new', 'movies', 'tv' }) do
    tv('GET', 'vhs/shelf?shelf=' .. shelf, nil, function(status, list)
      lists[i] = status == 200 and type(list) == 'table' and list or {}
      pending = pending - 1
      if pending > 0 then return end
      local all, seen = {}, {}
      for j, l in ipairs(lists) do
        for _, t in ipairs(l) do
          if not seen[t.key] then
            seen[t.key] = true
            t.isNew = j == 1 or nil
            all[#all + 1] = t
          end
        end
      end
      shelfCache, shelfAt = all, os.time()
      pushShelves()
    end)
  end
end

local function fetchCover(id)
  if coverCache[id] then return js('cover', J(id), J(coverCache[id])) end
  if not id:match('^%d+/%d+$') then return end
  hs.http.doAsyncRequest(M.config.tvUrl .. '/api/vhs/cover/' .. id, 'GET', nil, { Cookie = COOKIE },
    function(status, body, headers)
      if status ~= 200 or not body then return end
      local ct = 'image/jpeg'
      for k, v in pairs(headers or {}) do if k:lower() == 'content-type' then ct = v end end
      coverCache[id] = 'data:' .. ct .. ';base64,' .. hs.base64.encode(body)
      js('cover', J(id), J(coverCache[id]))
    end)
end

local function openShow(key)
  tv('GET', 'vhs/tape/' .. key, nil, function(status, t)
    if status ~= 200 or type(t) ~= 'table' then
      hs.alert.show('Plex unreachable (HTTP ' .. tostring(status) .. ')')
      return
    end
    t.episodes = t.episodes or {}
    for _, ep in ipairs(t.episodes) do ep.show = t.title; note(ep) end
    js('show', J(t))
  end)
end

-- Beside the PiP (left of it, bottoms lined up), or in its corner when there's none.
local W, H = 340, 540
local function dock()
  if not panel then return end
  if panelSet and not panel:frame():equals(panelSet) then return end -- dragged: leave it
  local st = M.state()
  local scr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local f
  if st.frame and not hidden and not fullScreen then
    local pf = hs.geometry.rect(st.frame)
    scr = hs.screen.find(pf.center) or scr
    f = hs.geometry.rect(pf.x - W - 8, pf.y + pf.h - H, W, H)
  else
    local s = scr:frame()
    local c = M.config
    f = hs.geometry.rect(s.x + s.w - W - c.margin, s.y + s.h - H - c.margin, W, H)
  end
  local s = scr:frame()
  f.y = math.max(s.y, f.y)
  f.x = math.max(s.x, f.x)
  panel:frame(f)
  panelSet = panel:frame()
end
M.dockPanel = dock
M.panelEval = function(src, fn) if panel then panel:evaluateJavaScript(src, fn) end end -- for debugging/tests

local onMessage -- below

local function makePanel()
  local uc = hs.webview.usercontent.new('fuzz')
  uc:setCallback(function(m) onMessage(m.body or {}) end)
  panel = hs.webview.new({ x = 0, y = 0, w = W, h = H }, { developerExtrasEnabled = false }, uc)
  panel:windowStyle({ 'titled', 'closable', 'resizable', 'utility', 'HUD' })
  panel:windowTitle('Fuzz')
  panel:level(hs.drawing.windowLevels.floating)
  panel:behaviorAsLabels({ 'canJoinAllSpaces' })
  panel:allowTextEntry(true)
  panel:deleteOnClose(false)
  panel:closeOnEscape(false)
  local f = io.open(DIR .. '/panel.html'):read('a')
  local font = io.open(DIR .. '/vt323.woff2', 'rb'):read('a')
  f = f:gsub('{{FONT}}', function() return hs.base64.encode(font) end)
  panelReady = false
  panel:html(f)
end

-- Key window for typing. Never panel:hswindow(): it scans every app's
-- windows through Accessibility and can stall Hammerspoon for seconds.
local function focusPanel()
  panel:bringToFront(true)
  hs.focus()
end

local function panelVisible()
  return panel ~= nil and panel:isVisible()
end

-- Open the panel on a tab ('club' or 'vhs'); the same call again closes it.
function M.panel(tab)
  if not tvOn() then
    hs.alert.show('Fuzz needs tvUrl and tvUser (see README)')
    return
  end
  tab = tab or panelTab
  if panelVisible() and tab == panelTab then
    panel:hide()
    return
  end
  panelTab = tab
  if not panel then makePanel() end
  if not panelVisible() then panelSet = nil end -- re-dock each time it opens
  dock()
  panel:show()
  focusPanel()
  js('tab', J(tab))
  if shelfCache then pushShelves() end
  panelPush()
  loadVibe()
end

function M.vhs() M.panel('vhs') end

-- opt-9: the TV tab with "find a channel" focused; again hides it. False without tvUrl.
local findPending = false
function M.find()
  if not tvOn() then return false end
  if panelVisible() and panelTab == 'tv' then
    panel:hide()
    return true
  end
  M.panel('tv')
  findPending = not panelReady -- a new panel focuses it once it's ready
  js('find')
  return true
end

function M.pickerVisible()
  return (chooser ~= nil and chooser:isVisible()) or (panelVisible() and panelTab == 'tv')
end

-- Rank channel lines ("<number>\t<name> <what's on>") with fzf --filter and
-- send the matching numbers back best first; null means filter in the page.
local function fzfFilter(seq, q, lines)
  local fzf = M.config.fzf
  if not fzf or type(lines) ~= 'table' then return js('filtered', J(seq), 'null') end
  local input = {}
  for i, l in ipairs(lines) do input[i] = tostring(l):gsub('[\r\n]', ' ') end
  -- Lines go in as an argument: hs.task's setInput+closeInput loses them.
  hs.task.new('/bin/sh', function(_, out)
    local nums = {}
    for line in (out or ''):gmatch('[^\n]+') do nums[#nums + 1] = tonumber(line:match('^(%d+)')) end
    js('filtered', J(seq), #nums > 0 and J(nums) or '[]')
  end, { '-c', 'printf "%s\\n" "$1" | "$0" --filter="$2" --delimiter="\t"',
    fzf, table.concat(input, '\n'), tostring(q) }):start()
end

-- The TV tab: every channel with what's on now, as the opt-9 picker shows it.
local function pushChannels()
  hs.http.asyncGet(M.config.baseUrl .. '/api/channels', HEADERS, function(status, body)
    local channels = status == 200 and hs.json.decode(body) or nil
    if type(channels) ~= 'table' then return end
    table.sort(channels, function(a, b) return a.number < b.number end)
    local rows = {}
    for i, ch in ipairs(channels) do
      rows[i] = { number = ch.number, name = ch.name }
      names[ch.number] = ch.name
    end
    js('channels', #rows > 0 and J(rows) or '[]', J(current or false))
    for _, ch in ipairs(channels) do
      hs.http.asyncGet(M.config.baseUrl .. '/api/channels/' .. ch.id .. '/now_playing', HEADERS, function(s, b)
        local ok, np = pcall(hs.json.decode, b or '')
        js('np', J(ch.number), J(s == 200 and ok and describe(np) or ''))
      end)
    end
  end)
end

local function syncRemote()
  js('now', J(nowText()))
  js('current', J(current or false), J(hidden))
end

local REMOTE = {
  up = function() M.step(1) end,
  down = function() M.step(-1) end,
  random = function() M.random() end,
  volup = function() M.volume(M.config.volStep) end,
  voldown = function() M.volume(-M.config.volStep) end,
  toggle = function()
    if current and running() then M.play(current) elseif last then M.play(last) end
  end,
  pip = function() M.pip() end,
  stop = function() M.stop() end,
}

onMessage = function(m)
  if m.act == 'ready' then
    panelReady = true
    js('tab', J(panelTab))
    if findPending then findPending = false; js('find') end
    panelPush()
    if shelfCache then pushShelves() end
  elseif m.act == 'tab' and (m.tab == 'tv' or m.tab == 'club' or m.tab == 'vhs') then
    panelTab = m.tab
  elseif m.act == 'close' then
    if panel then panel:hide() end
  elseif m.act == 'shelves' then
    if shelfCache and os.time() - shelfAt < 600 then pushShelves() else loadShelves() end
  elseif m.act == 'cover' then
    fetchCover(tostring(m.cover))
  elseif m.act == 'show' then
    openShow(tostring(m.key))
  elseif m.act == 'tape' then
    local t = byKey[tostring(m.key)]
    if t then M.playTape(t) end
  elseif m.act == 'play' and tonumber(m.channel) then
    M.play(tonumber(m.channel))
    syncRemote()
    hs.timer.doAfter(2, dock)
  elseif m.act == 'filter' then
    fzfFilter(m.seq, m.q, m.lines)
  elseif m.act == 'channels' then
    pushChannels()
    syncRemote()
  elseif m.act == 'remote' and REMOTE[m.cmd] then
    REMOTE[m.cmd]()
    -- up/down/random may wait on the channel list
    hs.timer.doAfter(0.5, syncRemote)
    hs.timer.doAfter(2, dock)
  end
end

-- A Plex transcode session id the Worker accepts ([a-z0-9]{8,24}).
local function newSid()
  local a = 'abcdefghijklmnopqrstuvwxyz0123456789'
  local s = ''
  for _ = 1, 8 do local i = math.random(#a); s = s .. a:sub(i, i) end
  return s .. string.format('%x', os.time())
end

function M.playTape(t)
  tv('GET', 'me', nil, function(status) -- makes sure the session cookie is fresh
    if status ~= 200 then
      hs.alert.show('craigo.art/tv: not logged in (HTTP ' .. tostring(status) .. ')')
      return
    end
    local sid = newSid()
    local start = hs.settings.get(posKey(t.key))
    fullScreen = nil
    load({
      tape = { key = t.key, title = t.title, duration = t.duration, sid = sid },
      title = 'VHS · ' .. (t.show and t.show .. ' · ' or '') .. t.title,
      header = 'Cookie: ' .. COOKIE,
      url = string.format('%s/api/vhs/play/%s.m3u8?s=%s', M.config.tvUrl, t.key, sid),
      start = start,
    })
    hs.alert.show('▶ ' .. (start and 'RESUMING ' or '') .. t.title:upper(), 2)
    js('now', J(nowText()))
    hs.timer.doAfter(2, dock)
  end)
end

--------------------------------
-- Setup
--------------------------------

-- Play channel n (default: the last one, else the first) filling `screen`
-- (an hs.screen or a name hs.screen.find understands). Channel keys keep
-- working; opt-0 stops it, and the next play starts as a normal PiP.
function M.playOn(screen, n)
  local s = type(screen) == 'string' and hs.screen.find(screen) or screen
  if not s then
    hs.alert.show('Tunarr PiP: no screen ' .. tostring(screen))
    return
  end
  local keep = n == nil and tape ~= nil and running() -- move the tape, don't change it
  withNumbers(function()
    n = n or last or numbers[1] or 1
    if not keep then last = n end
    fullScreen = s
    if not running() then
      start(chanSrc(n))
    else
      if not keep and current ~= n then switch(chanSrc(n)) else show() end
      ipc({ 'set_property', 'fullscreen', false },
        { 'set_property', 'fs-screen', screenIndex(s) },
        { 'set_property', 'fullscreen', true })
    end
  end)
end

-- Play as the floating mini player on the current screen (default channel:
-- the one playing, else the last, else the first), moving it back from
-- playOn's full screen if needed.
function M.pip(n)
  local keep = n == nil and tape ~= nil and running() -- move the tape, don't change it
  withNumbers(function()
    n = n or current or last or numbers[1] or 1
    if not keep then last = n end
    if not running() then
      fullScreen = nil
      start(chanSrc(n))
      return
    end
    if not keep and current ~= n then switch(chanSrc(n)) else show() end
    fullScreen = nil
    local target = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local app = mpvApp()
    local win = app and app:allWindows()[1]
    if win and win:screen() and win:screen():id() == target:id() and not win:isFullScreen() then
      ipc({ 'set_property', 'fullscreen', false })
      place()
      return
    end
    -- Windowed mpv won't leave the screen it's on, so hop: fullscreen on the
    -- target screen, back to windowed there, then size it.
    ipc({ 'set_property', 'fs-screen', screenIndex(target) },
      { 'set_property', 'fullscreen', true })
    hs.timer.doAfter(0.7, function()
      ipc({ 'set_property', 'fullscreen', false })
      hs.timer.doAfter(0.7, place)
    end)
  end)
end

-- Change volume by delta (mpv shows the level on the player).
function M.volume(delta)
  ipc({ 'osd-msg-bar', 'add', 'volume', delta })
end

-- key: 'x' for opt-x, or { mods, 'x' }.
local function bind(key, fn)
  if type(key) == 'table' then hs.hotkey.bind(key[1], key[2], fn)
  elseif key then hs.hotkey.bind({ 'alt' }, key, fn) end
end

function M.setup(opts)
  local c = M.config
  for k, v in pairs(opts or {}) do c[k] = v end
  assert(c.baseUrl and c.user, 'tunarr_pip.setup: set baseUrl and user')
  c.baseUrl = c.baseUrl:gsub('/+$', '')
  c.mpv = c.mpv or (hs.fs.attributes('/opt/homebrew/bin/mpv') and '/opt/homebrew/bin/mpv' or '/usr/local/bin/mpv')
  c.fzf = c.fzf or (hs.fs.attributes('/opt/homebrew/bin/fzf') and '/opt/homebrew/bin/fzf')
    or (hs.fs.attributes('/usr/local/bin/fzf') and '/usr/local/bin/fzf') or nil

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
  bind(c.volUpKey, function() M.volume(c.volStep) end)
  bind(c.volDownKey, function() M.volume(-c.volStep) end)
  loadNumbers()

  if c.tvUrl then
    c.tvUrl = c.tvUrl:gsub('/+$', '')
    assert(c.tvUser, 'tunarr_pip.setup: tvUrl needs tvUser')
    local tpw, tok = hs.execute(string.format(
      "/usr/bin/security find-generic-password -s craigo-tv -a '%s' -w", c.tvUser))
    if tok then
      TVPW = tpw:gsub('%s+$', '')
      bind(c.vhsKey, M.vhs)
      M.ticker = hs.timer.doEvery(15, tick)
      if c.menubar then
        menu = hs.menubar.new()
        menu:setIcon(fuzzIcon('ok'), true)
        menu:setClickCallback(function() M.panel() end)
      end
      loadVibe()
      M.vibeTimer = hs.timer.doEvery(120, loadVibe)
      makePanel() -- hidden and loaded ahead, so opt-9 opens instantly
    else
      hs.alert.show('Tunarr PiP: no Keychain password for craigo-tv ' .. c.tvUser .. ' (see README)', 8)
    end
  end

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
