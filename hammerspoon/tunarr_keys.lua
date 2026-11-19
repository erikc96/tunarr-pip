-- Tunarr PiP hotkeys for Hammerspoon. Every handler is ONE async POST to tunarrd (127.0.0.1:7849) and returns:
-- no timers, no event taps, no shell, no Accessibility calls, nothing that waits. The player itself is tunarrd (Python)
-- and tunarr-ui (Swift), both LaunchAgents; see README.md. The break overlay's passthrough reads state.json (written by
-- tunarrd) through one hs.pathwatcher, so a key or mouse event never asks another process anything.
local M = {}

local DIR = os.getenv("HOME") .. "/Library/Application Support/tunarr-pip"
local URL = "http://127.0.0.1:7849/cmd"
local FRESH = 15 -- seconds: tunarrd refreshes state.json every 5 s while a player exists; older means a dead daemon

local function slurp(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local lastAlert = 0
local function alert(msg)
  if os.time() - lastAlert >= 30 then lastAlert = os.time(); hs.alert.show(msg, 3) end
end

-- hs.http has no timeout: a wedged daemon makes a key silently inert, never freezes Hammerspoon.
local function post(cmd)
  local token = slurp(DIR .. "/token")
  if not token then return alert("Tunarr: no token file (is tunarrd installed?)") end
  hs.http.asyncPost(URL, hs.json.encode(cmd),
    { ["X-Tunarr-Token"] = token:gsub("%s+$", ""), ["Content-Type"] = "application/json" },
    function(status)
      if status < 200 or status >= 300 then alert("Tunarr: tunarrd answered " .. tostring(status)) end
    end)
end
M.post = post

-- state.json cache for the break passthrough (parsed on change, read in microseconds)
local st = {}
local function reload()
  local raw = slurp(DIR .. "/state.json")
  local ok, t = pcall(hs.json.decode, raw or "")
  st = (ok and type(t) == "table") and t or {}
end
local function fresh() return st.pid and st.ts and os.time() - st.ts <= FRESH end

function M.setup(opts)
  opts = opts or {}
  local c = {
    channelKeys = opts.channelKeys or {}, -- opt-N -> channel N (empty on Erik's Mac: opt-1..8 are for other tools)
    pickerKey = "9", stopKey = "0", upKey = "]", downKey = "[", randomKey = "\\", volUpKey = "=", volDownKey = "-",
    volStep = 5,
  }
  local function bind(mods, key, fn) hs.hotkey.bind(mods, key, fn) end
  for i, key in ipairs(c.channelKeys) do
    local n = tonumber(key) or i
    bind({ "alt" }, key, function() post({ cmd = "play", ch = n }) end)
  end
  bind({ "alt" }, c.pickerKey, function() post({ cmd = "find" }) end)
  bind({ "alt" }, c.stopKey, function() post({ cmd = "stop" }) end)
  bind({ "alt" }, c.upKey, function() post({ cmd = "step", d = 1 }) end)
  bind({ "alt" }, c.downKey, function() post({ cmd = "step", d = -1 }) end)
  bind({ "alt" }, c.randomKey, function() post({ cmd = "random" }) end)
  bind({ "alt" }, c.volUpKey, function() post({ cmd = "volume", d = c.volStep }) end)
  bind({ "alt" }, c.volDownKey, function() post({ cmd = "volume", d = -c.volStep }) end)
  bind({ "alt", "shift" }, "v", function() post({ cmd = "panel", tab = "vhs" }) end)
  bind({ "alt", "shift" }, "n", function() post({ cmd = "vhsnow" }) end)

  -- hammerspoon://tunarr?screen=Sidecar[&channel=N] (Raycast "Tunarr on iPad"): fill that screen
  hs.urlevent.bind("tunarr", function(_, p)
    post({ cmd = "playon", screen = p.screen or "Sidecar", ch = tonumber(p.channel) })
  end)

  -- opt-': choose where Tunarr plays (HS-native, two rows, no timers)
  local function toIpad()
    if hs.screen.find("Sidecar") then
      post({ cmd = "playon", screen = "Sidecar" })
    else
      hs.task.new(os.getenv("HOME") .. "/.config/raycast/script-commands/tunarr-ipad.sh", function(code, out)
        if code ~= 0 then hs.alert.show(out) end
      end):start()
    end
  end
  local where = hs.chooser.new(function(row)
    if not row then return end
    if row.id == "pip" then post({ cmd = "pip" }) else toIpad() end
  end)
  where:choices({
    { id = "pip", text = "Mini player", subText = "Floating, on the current display" },
    { id = "ipad", text = "iPad (Sidecar)", subText = "Extend to the iPad, fullscreen there" },
  })
  hs.hotkey.bind({ "alt" }, "'", function() where:query(nil):show() end)
  M.toIpad = toIpad

  reload()
  M.watcher = hs.pathwatcher.new(DIR, function(files)
    for _, f in ipairs(files) do if f:match("state%.json$") then return reload() end end
  end):start()
  return M
end

-- The break overlay's passthrough (forcedBreak.passthrough.tunarr): the PiP shows through the overlay, and its
-- opt-keys and the open panel get keys. All four functions read the cached table only.
function M.hole()
  if fresh() and not st.hidden and st.frame then return st.frame end
end
function M.pickerVisible()
  return st.pickerVisible == true and fresh() ~= nil
end
function M.rects()
  local list = {}
  if M.hole() then list[#list + 1] = M.hole() end
  if st.panel and st.panel.visible and st.panel.frame then list[#list + 1] = st.panel.frame end
  return list
end
function M.key(e)
  if M.pickerVisible() then return true end
  local f = e:getFlags()
  return f.alt and not (f.cmd or f.ctrl) and (e:getCharacters(true) or ""):match("^[90%[%]\\=%-]$") ~= nil
end
M.reload = reload -- re-read state.json now (the break calls this once at its start)

return M
