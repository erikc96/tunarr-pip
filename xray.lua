-- X-Ray banner inside the Tunarr PiP (mpv script; init.lua / tunarrd pass --script=, so the script
-- name is `xray`). Port of the Hammerspoon canvas in init.lua (xrayText/xrayDraw/xrayHover), now an
-- osd-overlay, so it follows the window and needs no Accessibility polling, event tap or 0.2 s timer.
--
-- Messages in (daemon -> mpv):
--   script-message-to xray set <json>    X-Ray table | {"error":N} | null/"" (= looking)
--   script-message-to xray enable <0|1>  0 while the player is hidden or no channel is on
-- Messages out (mpv -> daemon, seen as `client-message` IPC events):
--   tunarr-xray-want    banner is up and data is missing/stale: send `set`
--   tunarr-xray-click   banner clicked: open the panel on the X-RAY tab
-- Input: hover = observe `mouse-pos` (show while the pointer is over the window and moved in the last
-- 2 s; one re-armed timeout hides it). Wheel and click use a section whose mouse area is the banner box,
-- enabled only while the banner is up, so outside the box the keys reach mpv unchanged.
-- Idle cost: while hidden only the `mouse-pos` observer exists (flag checks); the timer, the
-- osd-dimensions/fullscreen observers, the input section and the overlay exist only while shown.
--
-- Test hooks, only when mpv runs with env XRAY_TEST set (tunarrd/tests/test_xray.py):
--   script-message xray-test hover <0|1> <x> <y>   fake a mouse-pos event
--   script-message xray-test idle                  fire the idle hide now
--   script-message xray-test idle_s <seconds>      idle time (default 2)
--   script-message xray idle_s <seconds>           same, short form
--   user-data/xray gains `ass` (the drawn ASS) and window size falls back to 640x360 without a VO.
-- Always (read-only state for tests / debugging): property user-data/xray =
--   {visible, scroll, label, title, bounds={x0,y0,x1,y1}, ass_len, enabled}
--
-- Limits (no visible window was available when this was written):
--  * Font: `VT323` if a VT323 file is in ~/Library/Fonts or /Library/Fonts, else `Menlo`
--    (override: --script-opts=xray-font=NAME). ASS \fn takes one name; libass does its own fallback if
--    the name still fails. --osd-fonts-dir is deliberately not used.
--  * Wrapping is done here with the measured monospace advance (ass-events cannot set per-event
--    margins), so a proportional fallback font wraps conservatively (measured with "W").
--  * A native window drag is consumed by the VO and never reaches Lua, so "hide while a button is held"
--    is only the 2 s idle hide for window drags.
--  * upper-case is Lua's ASCII upper(), as in the Hammerspoon version.
local utils = require 'mp.utils'

local TEST = os.getenv('XRAY_TEST') ~= nil
local SECTION = 'xray'
local NAME = mp.script_name
local AMBER, WHITE = '47B3FF', 'FFFFFF' -- BGR of { 1, .7, .28 } and white
local DIM_A, BOX_A, EDGE_A, SHADOW_A = '40', '26', 'E0', '4D' -- ASS alpha (00 opaque): .75 / .85 / .12 / .7 opaque

-- ---------------------------------------------------------------- font
local function has_font(needle)
  for _, dir in ipairs({ (os.getenv('HOME') or '') .. '/Library/Fonts', '/Library/Fonts' }) do
    for _, f in ipairs(utils.readdir(dir, 'files') or {}) do
      if f:lower():find(needle:lower(), 1, true) then return true end
    end
  end
  return false
end
local FONT = mp.get_opt('xray-font') or (has_font('vt323') and 'VT323' or 'Menlo')

-- ---------------------------------------------------------------- state
local ov = mp.create_osd_overlay('ass-events')
local enabled, shown = true, false
local data, stop = nil, 0
local segs, label, title = nil, '', ''
local scroll, max_scroll = 0, 0
local bounds, ass_len, last_ass = { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }, 0, ''
local idle, timer = 2, nil
local lx, ly

local function publish()
  local t = { visible = shown, enabled = enabled, scroll = math.floor(scroll + .5), label = label, title = title,
    bounds = bounds, ass_len = ass_len }
  if TEST then t.ass = last_ass end
  mp.set_property_native('user-data/xray', t)
end

-- ---------------------------------------------------------------- text
local UPPER_BAD = '[%c]'
local function esc(s) -- one line, no newlines
  s = tostring(s):gsub('\\', '\\\239\187\191'):gsub('{', '\\{'):gsub('}', '\\}')
  return s
end

local function ulen(s) return select(2, s:gsub('[^\128-\191]', '')) end

local function wrap(text, maxc) -- greedy word wrap to maxc characters; returns lines
  local out = {}
  for para in (tostring(text):gsub('\r\n?', '\n') .. '\n'):gmatch('(.-)\n') do
    para = para:gsub(UPPER_BAD, ' ')
    local cur, clen = '', 0
    local function flush() out[#out + 1] = cur; cur, clen = '', 0 end
    local any = false
    for word in para:gmatch('%S+') do
      any = true
      local wl = ulen(word)
      while wl > maxc do -- a word longer than a line: break it
        local room = maxc - (clen > 0 and clen + 1 or 0)
        if room < 3 then flush(); room = maxc end
        local head, n = '', 0
        for ch in word:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
          if n >= room then break end
          head, n = head .. ch, n + 1
        end
        cur = (clen > 0 and cur .. ' ' or '') .. head
        word, wl = word:sub(#head + 1), wl - n
        flush()
      end
      if clen == 0 then cur, clen = word, wl
      elseif clen + 1 + wl <= maxc then cur, clen = cur .. ' ' .. word, clen + 1 + wl
      else flush(); cur, clen = word, wl end
    end
    if clen > 0 or not any then flush() end
  end
  return out
end

-- Segments of the banner, as the Lua version: small amber label, bold white title, dim detail lines.
local function segments(x)
  if x == nil then
    return { { t = 'X-RAY · LOOKING…', size = 13, dim = true } }, 'X-RAY · LOOKING…', ''
  end
  if x.error then
    return { { t = 'NO X-RAY FOR THIS ONE', size = 13, dim = true } }, 'NO X-RAY FOR THIS ONE', ''
  end
  local facts = {}
  for _, f in ipairs({ x.year or false, x.contentRating or false,
      tonumber(x.rating) and string.format('★ %.1f', tonumber(x.rating)) or false, x.studio or false }) do
    if f then facts[#facts + 1] = tostring(f) end
  end
  if type(x.genres) == 'table' then
    for i, g in ipairs(x.genres) do if i <= 2 then facts[#facts + 1] = tostring(g) end end
  end
  local lbl
  if x.show then
    lbl = string.format('%s · S%02dE%02d', tostring(x.show), math.floor(tonumber(x.season) or 0), math.floor(tonumber(x.episode) or 0))
  else
    lbl = table.concat(facts, ' · ')
  end
  lbl = lbl:upper()
  local ttl = tostring(x.title or ''):upper()
  local s = { { t = lbl, size = 13, color = AMBER }, { t = ttl, size = 19, color = WHITE, bold = true } }
  if x.show and #facts > 0 then s[#s + 1] = { t = table.concat(facts, ' · '):upper(), size = 14, dim = true } end
  local cast = {}
  if type(x.cast) == 'table' then
    for _, c in ipairs(x.cast) do
      if #cast >= 8 then break end
      if type(c) == 'table' and c.name then cast[#cast + 1] = tostring(c.name):upper() end
    end
  end
  if #cast > 0 then s[#s + 1] = { t = (x.guest and 'GUEST ' or 'WITH ') .. table.concat(cast, ', '), size = 14, dim = true } end
  local sum = x.summary or (type(x.wiki) == 'table' and type(x.wiki[1]) == 'table' and x.wiki[1].extract)
  if sum then s[#s + 1] = { t = tostring(sum):upper(), size = 14, dim = true } end
  return s, lbl, ttl
end

-- ---------------------------------------------------------------- measuring
local function dims()
  local w, h = mp.get_property_number('osd-width', 0), mp.get_property_number('osd-height', 0)
  if w <= 0 or h <= 0 then
    if TEST then return 640, 360 end
    return nil -- no window yet
  end
  return w, h
end

local function ink(data_)
  ov.hidden, ov.compute_bounds, ov.data = true, true, data_
  local r = ov:update()
  if r and r.x0 and r.x1 and r.y0 and r.y1 then return r end
end

-- Font metrics in px per size, measured once and cached: advance of one character
-- ((w(20 W) - w(10 W)) / 10, so bearings cancel), line pitch ((h(3 lines) - h(1 line)) / 2) and the gap
-- between the \pos y and the ink top of the first line. Bounds cover only what is on screen, so the
-- height of a long text is computed from line count x pitch, never measured whole.
local metric_cache = {}
local function metrics(size, bold)
  local k = FONT .. size .. (bold and 'b' or '')
  if metric_cache[k] then return metric_cache[k] end
  local function probe(str)
    return ink(string.format('{\\an7\\pos(0,0)\\fn%s\\fs%d\\b%d\\bord0\\shad0\\q2}%s', FONT, size, bold and 1 or 0, str))
  end
  local a, b, h1, h3 = probe(string.rep('W', 10)), probe(string.rep('W', 20)), probe('W'), probe('W\\NW\\NW')
  local mt = { adv = size * .6, pitch = size * 1.2, top = size * .2 }
  if a and b and b.x1 - b.x0 > a.x1 - a.x0 then mt.adv = ((b.x1 - b.x0) - (a.x1 - a.x0)) / 10 end
  if h1 and h3 and h3.y1 - h3.y0 > h1.y1 - h1.y0 then mt.pitch = ((h3.y1 - h3.y0) - (h1.y1 - h1.y0)) / 2 end
  if h1 then mt.top = h1.y0 end
  metric_cache[k] = mt
  return mt
end

-- ---------------------------------------------------------------- drawing
local function fnum(v) return string.format('%d', math.floor(v + .5)) end

local function rrect(x, y, w, h, r) -- rounded-rect ASS path, clockwise
  local k = r * .5523
  local p = {}
  local function a(...) for _, v in ipairs({ ... }) do p[#p + 1] = fnum(v) end end
  p[#p + 1] = 'm'; a(x + r, y)
  p[#p + 1] = 'l'; a(x + w - r, y)
  p[#p + 1] = 'b'; a(x + w - r + k, y, x + w, y + r - k, x + w, y + r)
  p[#p + 1] = 'l'; a(x + w, y + h - r)
  p[#p + 1] = 'b'; a(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h)
  p[#p + 1] = 'l'; a(x + r, y + h)
  p[#p + 1] = 'b'; a(x + r - k, y + h, x, y + h - r + k, x, y + h - r)
  p[#p + 1] = 'l'; a(x, y + r)
  p[#p + 1] = 'b'; a(x, y + r - k, x + r - k, y, x + r, y)
  return table.concat(p, ' ')
end

-- ASS text for the segments, wrapped to tw px. Escaping: backslash -> backslash + U+FEFF (mpv's osc
-- trick, so it cannot start a tag), { } -> \{ \}, newlines never survive (wrap splits them -> \N).
local function body(sc, tw)
  local parts, height, top = {}, 0, nil
  for _, sg in ipairs(segs) do
    local size = math.floor(sg.size * sc + .5)
    local mt = metrics(size, sg.bold)
    local lines = wrap(sg.t, math.max(4, math.floor(tw / mt.adv)))
    height = height + #lines * mt.pitch
    top = top or mt.top
    for i, l in ipairs(lines) do lines[i] = esc(l) end
    parts[#parts + 1] = string.format('{\\fs%d\\b%d\\1c&H%s&\\1a&H%s&}%s', size, sg.bold and 1 or 0,
      sg.dim and WHITE or sg.color, sg.dim and DIM_A or '00', table.concat(lines, '\\N'))
  end
  return table.concat(parts, '\\N'), height, top or 0
end

local function text_event(x, y, sc, text, clip)
  return string.format('{\\an7\\pos(%s,%s)%s\\fn%s\\bord0\\shad%s\\4c&H000000&\\4a&H%s&\\q2}%s',
    fnum(x), fnum(y), clip and string.format('\\clip(%s,%s,%s,%s)', fnum(clip[1]), fnum(clip[2]), fnum(clip[3]), fnum(clip[4])) or '',
    FONT, fnum(2 * sc), SHADOW_A, text)
end

local function frame_w(W, sc)
  return mp.get_property_native('fullscreen') and math.min(520 * sc, W / 3) or W
end

local function remove()
  ov.hidden, ov.compute_bounds = false, false
  ov:remove()
  bounds = { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
  ass_len, last_ass = 0, ''
end

local function draw()
  local W, H = dims()
  if not W then return false end
  local sc = mp.get_property_number('display-hidpi-scale', 1)
  local m, padx, pady = 8 * sc, 12 * sc, 10 * sc
  local fw = frame_w(W, sc)
  local bw = math.min(fw * .62, 340 * sc)
  local bx, by = fw - bw - m, m
  local tw = bw - 2 * padx
  ov.res_x, ov.res_y = W, H

  -- Box height = wrapped text height (line count x measured pitch), capped at osd-height - 16.
  local text, text_h, top = body(sc, tw)
  local content_h = text_h - top + 2 * pady
  local bh = math.min(content_h, H - 2 * m)
  max_scroll = math.max(0, content_h - bh)
  scroll = math.max(0, math.min(scroll, max_scroll))

  -- rounded box + clipped, scrolled text
  local ty = by + pady - top - scroll
  local lines = {
    string.format('{\\an7\\pos(0,0)\\bord%s\\1c&H1A1A1A&\\1a&H%s&\\3c&HFFFFFF&\\3a&H%s&\\shad0\\p1}%s',
      fnum(math.max(1, sc)), BOX_A, EDGE_A, rrect(bx, by, bw, bh, 14 * sc)),
    text_event(bx + padx, ty, sc, text, { bx + 1, by + 1, bx + bw - 1, by + bh - 1 }),
  }
  ov.data = table.concat(lines, '\n')
  ov.hidden, ov.compute_bounds = false, false
  ov:update()
  bounds = { x0 = math.floor(bx), y0 = math.floor(by), x1 = math.floor(bx + bw), y1 = math.floor(by + bh) }
  ass_len, last_ass = #ov.data, ov.data
  mp.set_mouse_area(bounds.x0, bounds.y0, bounds.x1, bounds.y1, SECTION)
  return true
end

-- ---------------------------------------------------------------- show / hide
local on_dims

local function hide()
  if timer then timer:kill() end
  if not shown then return end
  shown = false
  mp.unobserve_property(on_dims)
  mp.disable_key_bindings(SECTION)
  remove()
  publish()
end

local function want()
  local fresh = data ~= nil and not data.error and (stop == 0 or os.time() * 1000 < stop)
  if not fresh then mp.commandv('script-message', 'tunarr-xray-want') end
end

local function arm()
  if not timer then timer = mp.add_timeout(idle, hide) end
  timer:kill()
  timer.timeout = idle
  timer:resume()
end

local function show()
  if shown or not enabled then return end
  if not draw() then return end
  shown = true
  mp.enable_key_bindings(SECTION)
  mp.observe_property('osd-dimensions', 'native', on_dims)
  mp.observe_property('fullscreen', 'native', on_dims)
  want()
  publish()
end

local seen_dims
on_dims = function() -- registered only while shown
  local W, H = dims()
  local k = tostring(W) .. 'x' .. tostring(H) .. tostring(mp.get_property_native('fullscreen'))
  if k == seen_dims then return end
  seen_dims = k
  if shown then draw(); publish() end
end

local function moved()
  if not enabled then return end
  arm()
  show()
end

local function on_mouse(_, m)
  if not enabled or type(m) ~= 'table' then return end -- idle + disabled: a flag check, nothing else
  local inside = m.hover == true
  if inside and mp.get_property_native('fullscreen') then
    local W = dims()
    if W then inside = m.x <= frame_w(W, mp.get_property_number('display-hidpi-scale', 1)) end
  end
  if not inside then hide(); lx, ly = nil, nil; return end
  if m.x == lx and m.y == ly then return end
  lx, ly = m.x, m.y
  moved()
end

local primed = false
local function observer(_, m) -- the sample delivered on registration is not a movement
  if not primed then primed = true; return end
  on_mouse(_, m)
end

local function set_enabled(on)
  if on == enabled then return end
  enabled = on
  if on then
    primed = false
    mp.observe_property('mouse-pos', 'native', observer)
    publish()
  else
    mp.unobserve_property(observer)
    hide()
    lx, ly = nil, nil
    publish()
  end
end

-- ---------------------------------------------------------------- scroll / click
local function scroll_by(dir)
  if not shown then return end
  local sc = mp.get_property_number('display-hidpi-scale', 1)
  scroll = math.max(0, math.min(scroll + dir * 3 * 14 * 1.2 * sc, max_scroll)) -- 3 text lines
  arm() -- scrolling counts as movement
  draw()
  publish()
end

mp.register_script_message('xray-wheel-up', function() scroll_by(-1) end)
mp.register_script_message('xray-wheel-down', function() scroll_by(1) end)
mp.register_script_message('xray-click', function()
  if not shown then return end
  arm()
  mp.commandv('script-message', 'tunarr-xray-click')
end)
-- Bindings live in their own section, enabled only while the banner is up; the mouse area (set in
-- draw) is the banner box, so wheel/click elsewhere fall through to mpv's own bindings.
mp.set_key_bindings({
  { 'WHEEL_UP', 'script-message-to ' .. NAME .. ' xray-wheel-up' },
  { 'WHEEL_DOWN', 'script-message-to ' .. NAME .. ' xray-wheel-down' },
  { 'MBTN_LEFT', 'script-message-to ' .. NAME .. ' xray-click' },
  { 'MBTN_LEFT_DBL', 'ignore' }, -- the second click of a double click must not toggle fullscreen
}, SECTION, 'force')

-- ---------------------------------------------------------------- daemon messages
mp.register_script_message('set', function(json)
  local d
  if json and json ~= '' and json ~= 'null' then d = utils.parse_json(json) end
  if type(d) ~= 'table' then d = nil end
  data, stop, scroll = d, d and tonumber(d.stop) or 0, 0, nil
  segs, label, title = segments(d)
  if shown then draw() end
  publish()
end)
mp.register_script_message('enable', function(v) set_enabled(v == '1' or v == 'true' or v == 'yes') end)

segs, label, title = segments(nil)
mp.observe_property('mouse-pos', 'native', observer)
publish()

-- ---------------------------------------------------------------- test hooks
if TEST then
  local function idle_s(v) idle = tonumber(v) or idle end
  mp.register_script_message('xray', function(sub, v) if sub == 'idle_s' then idle_s(v) end end)
  mp.register_script_message('xray-test', function(sub, a, x, y)
    if sub == 'hover' then on_mouse(nil, { hover = a == '1', x = tonumber(x) or 0, y = tonumber(y) or 0 })
    elseif sub == 'idle' then hide()
    elseif sub == 'idle_s' then idle_s(a) end
  end)
end
