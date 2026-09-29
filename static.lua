-- mpv script loaded into the Tunarr PiP (init.lua passes --script=).
-- Shows TV static from the moment a channel starts loading until its first
-- frame, and while the stream stalls for cache. It runs inside mpv, so the
-- static appears without an IPC round trip and follows the window.
local W, H, FRAMES = 320, 180, 6
local DIR = '/tmp/tunarr-static'

-- Raw BGRA noise frames, generated once per boot (overlay-add reads files).
local files = {}
do
  local px = {}
  for v = 0, 255 do px[v] = string.char(v, v, v, 255) end
  os.execute('mkdir -p ' .. DIR)
  for i = 1, FRAMES do
    local path = string.format('%s/%d.bgra', DIR, i)
    local f = io.open(path, 'rb')
    local ok = f and f:seek('end') == W * H * 4
    if f then f:close() end
    if not ok then
      local buf = {}
      for j = 1, W * H do buf[j] = px[math.random(0, 255)] end
      f = io.open(path, 'wb')
      f:write(table.concat(buf))
      f:close()
    end
    files[i] = path
  end
end

local timer, frame = nil, 0
local loading, stalled = false, false

local function tick()
  local w, h = mp.get_property_number('osd-width', 0), mp.get_property_number('osd-height', 0)
  if w <= 0 or h <= 0 then return end -- no window yet
  frame = frame % FRAMES + 1
  mp.command_native({ 'overlay-add', 0, 0, 0, files[frame], 0, 'bgra', W, H, W * 4, w, h })
end

local function update()
  if loading or stalled then
    if not timer then
      tick()
      timer = mp.add_periodic_timer(1 / 24, tick)
    end
  elseif timer then
    timer:kill(); timer = nil
    mp.command_native({ 'overlay-remove', 0 })
  end
end

mp.register_event('start-file', function() loading = true; update() end)
mp.register_event('playback-restart', function() loading = false; update() end)
mp.register_event('end-file', function() loading = false; update() end)
mp.observe_property('paused-for-cache', 'bool', function(_, v) stalled = v == true; update() end)
