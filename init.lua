--------------------------------
-- Tunarr picture-in-picture
--
-- opt-1 … opt-8  play that channel in a floating mini player; pressing the
--                key for the channel already showing hides/shows it
-- opt-9          channel picker (every channel + what's on now)
-- opt-0          stop and drop the stream
-- opt-] / opt-[  channel up / down (wraps)
-- opt-\         random channel
-- opt-= / opt--  volume up / down
-- opt-v          VHS: pick a Plex movie or episode and play it in the player
--
-- With tvUrl/tvUser set (a craigo.art/tv account), the player also counts as
-- watching there: it posts a beat every minute a channel or tape really plays,
-- which feeds streaks, trophies and Fuzz, the mascot. Fuzz lives in the menu
-- bar; its menu has the clubhouse stats.
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
  tvUrl = nil,     -- craigo.art/tv style site, e.g. 'https://craigo.art/tv'; enables the club and VHS
  tvUser = nil,    -- its login; password in the Keychain (service 'craigo-tv')
  vhsKey = 'v',
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
        fn(status, ok and data or nil)
      end, 'ignoreLocalCache')
  end
  if COOKIE then go(true) else login(function(ok) if ok then go(false) else fn(401) end end) end
end

local vibe = nil
local menu = nil
local loadVibe -- below

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

local function mins(s) return string.format('%d MIN', math.floor((s or 0) / 60 + 0.5)) end
local function days(n) return string.format('%d DAY%s', n, n == 1 and '' or 'S') end
local function chName(n)
  if n == 0 then return 'A VHS TAPE' end
  return string.format('CH %02d%s', n, names[n] and ' ' .. names[n]:upper() or '')
end
local function anyTape(v)
  for _, l in ipairs(v.live or {}) do if l.channel == 0 then return true end end
  return false
end

local function moodLine(m, v)
  if m.mood == 'watching' and anyTape(v) then return 'FUZZ IS WATCHING A TAPE · POPCORN OUT' end
  return string.format(MOODS[m.mood] or '', m.idle or 0)
end

local function clubMenu()
  local v = vibe
  local items = {}
  local function add(t) items[#items + 1] = t end
  local function head(t) add({ title = t, disabled = true }) end
  if not v then
    head(tvOn() and 'Loading…' or 'craigo.art/tv: no login set up')
  else
    head(moodLine(v.mascot, v))
    head(string.format('FED TODAY %s OF 60 · EVERYONE COUNTS', mins(v.mascot.fed)))
    add({ title = '-' })
    head(string.format('MY STREAK %s%s', days(v.me.streak), v.me.freeze and ' · FREEZE READY ❄' or ''))
    head(string.format('TODAY %s · THIS WEEK %s', mins(v.me.today), mins(v.me.week)))
    head('SQUAD STREAK ' .. days(v.squad))
    add({ title = '-' })
    if #v.live > 0 then
      head('ON NOW')
      for _, l in ipairs(v.live) do
        add({ title = '  ' .. l.username:upper() .. ' · ' .. chName(l.channel),
          fn = l.channel ~= 0 and function() M.play(l.channel) end or nil, disabled = l.channel == 0 })
      end
    else
      head('NOBODY IS WATCHING RIGHT NOW')
    end
    local friends = {}
    for _, f in ipairs(v.friends) do
      friends[#friends + 1] = { title = string.format('%s · STREAK %d · %d ★', f.username:upper(), f.streak, f.trophies), disabled = true }
    end
    add({ title = 'Friends', menu = #friends > 0 and friends or { { title = 'none yet', disabled = true } } })
    local title, list = "LAST WEEK'S AWARDS", v.awards.last
    if #list == 0 then title, list = 'THIS WEEK SO FAR', v.awards.week end
    local aw = {}
    for _, a in ipairs(list) do
      aw[#aw + 1] = { title = a.award .. ' · ' .. table.concat(a.winners, ' & '):upper(), tooltip = a.detail, disabled = true }
    end
    if #aw == 0 then aw[1] = { title = 'NO AWARDS YET · WATCH 5 MIN TO ENTER', disabled = true } end
    add({ title = 'Awards', menu = { { title = title, disabled = true }, { title = '-' }, table.unpack(aw) } })
    local top = {}
    for _, t in ipairs(v.top) do
      top[#top + 1] = { title = chName(t.channel) .. ' · ' .. mins(t.seconds),
        fn = t.channel ~= 0 and function() M.play(t.channel) end or nil, disabled = t.channel == 0 }
    end
    if #top == 0 then top[1] = { title = 'nothing watched this week', disabled = true } end
    add({ title = 'Top channels this week', menu = top })
    local got = {}
    for _, t in ipairs(v.trophies) do got[t.badge] = true end
    local tr, n = {}, 0
    for _, t in ipairs(TROPHIES) do
      if got[t[1]] then n = n + 1 end
      tr[#tr + 1] = { title = t[2] .. ' · ' .. t[3], checked = got[t[1]] or false, disabled = true }
    end
    add({ title = string.format('Trophies %d/%d', n, #TROPHIES), menu = tr })
  end
  add({ title = '-' })
  add({ title = 'VHS…', fn = function() M.vhs() end })
  add({ title = 'Open ' .. (M.config.tvUrl or ''):gsub('^https?://', ''), fn = function() hs.urlevent.openURL(M.config.tvUrl .. '/') end })
  return items
end

M.clubMenu = clubMenu -- for debugging/tests

loadVibe = function()
  if not tvOn() then return end
  tv('GET', 'vibe?day=' .. os.date('%Y-%m-%d'), nil, function(status, v)
    if status ~= 200 or type(v) ~= 'table' or not v.mascot then return end
    vibe = v
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
-- VHS: Plex movies and episodes through craigo.art/tv
--------------------------------
local vhsChooser = nil
local shelfCache, shelfAt = nil, 0

local function clock(sec)
  sec = math.max(0, math.floor(sec or 0))
  return string.format('%d:%02d:%02d', sec // 3600, sec // 60 % 60, sec % 60)
end

local function tapeNote(t)
  local pos = hs.settings.get(posKey(t.key))
  if pos then return 'HALF WATCHED · AT ' .. clock(pos) end
  if hs.settings.get(doneKey(t.key)) then return 'SEEN IT ✓' end
  return t.duration and clock(t.duration) or ''
end

local function tapeRow(t, prefix)
  local label = t.title .. (t.year and ' (' .. t.year .. ')' or '')
  if t.type == 'episode' then
    label = string.format('S%02dE%02d  %s', t.season or 0, t.episode or 0, t.title)
  end
  local kind = ({ movie = 'MOVIE', show = 'SHOW', episode = 'EPISODE' })[t.type] or ''
  local note = t.type == 'show' and '' or tapeNote(t)
  return { text = (prefix or '') .. label, subText = kind .. (note ~= '' and ' · ' .. note or ''), tape = t }
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
  end)
end

local function showEpisodes(show)
  vhsChooser:placeholderText(show.title .. ' · episode…')
  vhsChooser:choices({ { text = 'Loading episodes…' } })
  vhsChooser:query(nil)
  vhsChooser:show()
  tv('GET', 'vhs/tape/' .. show.key, nil, function(status, t)
    if status ~= 200 or type(t) ~= 'table' then
      vhsChooser:choices({ { text = 'Plex unreachable (HTTP ' .. tostring(status) .. ')' } })
      return
    end
    local rows, next = {}, nil
    for _, ep in ipairs(t.episodes or {}) do
      if not next and hs.settings.get(posKey(ep.key)) then next = ep end
    end
    for _, ep in ipairs(t.episodes or {}) do
      if not next and not hs.settings.get(doneKey(ep.key)) then next = ep end
    end
    if next then
      local r = tapeRow(next, '▶ UP NEXT  ')
      rows[1] = r
    end
    for _, ep in ipairs(t.episodes or {}) do
      ep.show = ep.show or show.title
      rows[#rows + 1] = tapeRow(ep)
    end
    if next then next.show = next.show or show.title end
    vhsChooser:choices(rows)
  end)
end

local function loadShelves()
  -- New arrivals first, then every movie and show (the chooser filters as you type).
  local rows, seen, pending = {}, {}, 3
  local lists = {}
  local function done()
    pending = pending - 1
    if pending > 0 then return end
    for i, shelf in ipairs({ 'new', 'movies', 'tv' }) do
      for _, t in ipairs(lists[i] or {}) do
        if not seen[t.key] then
          seen[t.key] = true
          rows[#rows + 1] = tapeRow(t, shelf == 'new' and '★ NEW  ' or nil)
        end
      end
    end
    if #rows == 0 then rows[1] = { text = 'Plex unreachable' } end
    shelfCache, shelfAt = rows, os.time()
    M.vhsRows = rows -- for debugging/tests
    if vhsChooser:isVisible() then vhsChooser:choices(rows) end
  end
  for i, shelf in ipairs({ 'new', 'movies', 'tv' }) do
    tv('GET', 'vhs/shelf?shelf=' .. shelf, nil, function(status, list)
      lists[i] = status == 200 and type(list) == 'table' and list or {}
      done()
    end)
  end
end

function M.vhs()
  if not tvOn() then
    hs.alert.show('VHS needs tvUrl and tvUser (see README)')
    return
  end
  if not vhsChooser then
    vhsChooser = hs.chooser.new(function(row)
      if not row or not row.tape then return end
      if row.tape.type == 'show' then
        hs.timer.doAfter(0.1, function() showEpisodes(row.tape) end)
      else
        M.playTape(row.tape)
      end
    end)
    vhsChooser:searchSubText(true)
  end
  vhsChooser:placeholderText('CRAIGO VIDEO · movie or show…')
  vhsChooser:query(nil)
  if shelfCache then
    -- Rebuild notes (half watched / seen) from the cached tapes.
    local rows = {}
    for i, r in ipairs(shelfCache) do
      rows[i] = tapeRow(r.tape, r.text:match('^★ NEW  ') and '★ NEW  ' or nil)
    end
    vhsChooser:choices(rows)
  else
    vhsChooser:choices({ { text = 'Loading the shelves…' } })
  end
  vhsChooser:show()
  if not shelfCache or os.time() - shelfAt > 600 then loadShelves() end
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
        menu:setMenu(function() loadVibe(); return clubMenu() end)
      end
      loadVibe()
      M.vibeTimer = hs.timer.doEvery(120, loadVibe)
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
