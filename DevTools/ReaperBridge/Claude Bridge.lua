-- @noindex
-- Claude Bridge: dev-only file-polling bridge for driving the test REAPER from the shell.
-- Loaded by <resource>/Scripts/__startup.lua in the test install. Not a ReaPack package.
--
-- Protocol: the `rt` CLI writes <id>.lua into <resource>/ClaudeBridge/inbox. The bridge runs it
-- (print() is captured, return values are serialized) and writes <id>.txt into outbox:
-- first line "OK" or "ERR", then the captured output.

local ROOT   = reaper.GetResourcePath() .. "/ClaudeBridge"
local INBOX  = ROOT .. "/inbox"
local OUTBOX = ROOT .. "/outbox"
local POLL_INTERVAL = 0.1

reaper.RecursiveCreateDirectory(INBOX, 0)
reaper.RecursiveCreateDirectory(OUTBOX, 0)

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function write_atomic(path, content)
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "wb"))
  f:write(content)
  f:close()
  os.rename(tmp, path)
end

local function serialize(v, indent, seen)
  indent = indent or ""
  seen = seen or {}
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t ~= "table" then return tostring(v) end
  if seen[v] then return "<cycle>" end
  seen[v] = true
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  if #keys == 0 then return "{}" end
  table.sort(keys, function(a, b)
    if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
    return type(a) < type(b)
  end)
  local inner = indent .. "  "
  local parts = {}
  local is_array = #v == #keys
  for _, k in ipairs(keys) do
    local val = serialize(v[k], inner, seen)
    local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. serialize(k) .. "]")
    parts[#parts + 1] = inner .. (is_array and val or (key .. " = " .. val))
  end
  seen[v] = nil
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

---------------------------------------------------------------------------
-- Helpers exposed to snippets
---------------------------------------------------------------------------

local H = {}

-- Summary of the current project: tracks, items, markers/regions, selection.
function H.snapshot()
  local proj = 0
  local out = { tracks = {}, markers = {}, regions = {} }
  local _, projfn = reaper.EnumProjects(-1)
  out.project = projfn ~= "" and projfn or "(unsaved)"
  out.cursor = reaper.GetCursorPosition()
  local ts_s, ts_e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if ts_e > ts_s then out.time_selection = { ts_s, ts_e } end
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, name = reaper.GetTrackName(tr)
    local t = {
      idx = i + 1, name = name,
      selected = reaper.IsTrackSelected(tr) or nil,
      depth = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")),
      items = {},
    }
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, j)
      local take = reaper.GetActiveTake(it)
      local src = take and reaper.GetMediaItemTake_Source(take)
      local _, notes = reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "", false)
      t.items[#t.items + 1] = {
        pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION"),
        len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH"),
        take = take and reaper.GetTakeName(take) or nil,
        src = src and reaper.GetMediaSourceFileName(src) or nil,
        selected = reaper.IsMediaItemSelected(it) or nil,
        notes = notes ~= "" and notes or nil,
      }
    end
    if #t.items == 0 then t.items = nil end
    out.tracks[#out.tracks + 1] = t
  end
  local i = 0
  while true do
    local ok, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers(i)
    if ok == 0 then break end
    if isrgn then
      out.regions[#out.regions + 1] = { idx = idx, name = name, pos = pos, ["end"] = rgnend }
    else
      out.markers[#out.markers + 1] = { idx = idx, name = name, pos = pos }
    end
    i = i + 1
  end
  return out
end

-- Visible top-level windows (useful for spotting error dialogs and ReaImGui windows).
function H.windows()
  if not reaper.JS_Window_ArrayAllTop then return "js_ReaScriptAPI not installed" end
  local arr = reaper.new_array({}, 1024)
  reaper.JS_Window_ArrayAllTop(arr)
  local out = {}
  for _, addr in ipairs(arr.table()) do
    local hwnd = reaper.JS_Window_HandleFromAddress(addr)
    if reaper.JS_Window_IsVisible(hwnd) then
      local title = reaper.JS_Window_GetTitle(hwnd)
      if title ~= "" then
        local _, l, t, r, b = reaper.JS_Window_GetRect(hwnd)
        out[#out + 1] = { title = title, rect = { l, t, r, b } }
      end
    end
  end
  return out
end

-- Text of all child controls of the first visible window whose title contains `pattern`
-- (plain, case-insensitive match). Reads message boxes / error dialogs.
function H.window_text(pattern)
  local arr = reaper.new_array({}, 1024)
  reaper.JS_Window_ArrayAllTop(arr)
  for _, addr in ipairs(arr.table()) do
    local hwnd = reaper.JS_Window_HandleFromAddress(addr)
    local title = reaper.JS_Window_GetTitle(hwnd)
    if reaper.JS_Window_IsVisible(hwnd) and title:lower():find(pattern:lower(), 1, true) then
      local kids = reaper.new_array({}, 1024)
      reaper.JS_Window_ArrayAllChild(hwnd, kids)
      local texts = {}
      for _, caddr in ipairs(kids.table()) do
        local s = reaper.JS_Window_GetTitle(reaper.JS_Window_HandleFromAddress(caddr))
        if s ~= "" then texts[#texts + 1] = s end
      end
      return { title = title, text = texts }
    end
  end
  return nil
end

-- Contents of the ReaScript console window, if open.
function H.console()
  local w = H.window_text("ReaScript console output")
  if not w then return "" end
  table.sort(w.text, function(a, b) return #a > #b end)
  return w.text[1] or ""
end

-- Screen rect (points, top-left origin) of the first visible window whose title contains `pattern`.
function H.window_rect(pattern)
  for _, w in ipairs(H.windows()) do
    if w.title:lower():find(pattern:lower(), 1, true) then
      local l, t, r, b = table.unpack(w.rect)
      if t > b then -- macOS: bottom-left origin, flip to top-left using the primary display
        local _, vt, _, vb = reaper.my_getViewport(0, 0, 0, 0, 0, 0, 0, 0, false)
        local screen_h = math.abs(vt - vb)
        return { x = l, y = screen_h - t, w = r - l, h = t - b, title = w.title }
      end
      return { x = l, y = t, w = r - l, h = b - t, title = w.title }
    end
  end
  return nil
end

-- Open a blank project in the current tab without a save prompt.
function H.reset()
  local empty = ROOT .. "/empty.rpp"
  if not reaper.file_exists(empty) then write_atomic(empty, "<REAPER_PROJECT 0.1\n>\n") end
  reaper.Main_openProject("noprompt:template:" .. empty)
  return "reset"
end

-- Wrapper run in the target script's own Lua state. Errors (including ones inside defer
-- callbacks) and ShowConsoleMsg output go to log files instead of REAPER's modal error dialog,
-- which would otherwise block the bridge. get_action_context reports the target's path.
local WRAPPER = [==[
local TARGET, LOG_DIR = %q, %q
reaper.set_action_options(1) -- re-launch terminates the running instance instead of prompting
local function append(file, s)
  local f = io.open(LOG_DIR .. "/" .. file, "a")
  if f then f:write(s) f:close() end
end
local function on_err(e)
  append("errors.log", os.date("[%%H:%%M:%%S] ") .. tostring(e) .. "\n")
end
local ShowConsoleMsg = reaper.ShowConsoleMsg
reaper.ShowConsoleMsg = function(s) append("console.log", tostring(s)) ShowConsoleMsg(s) end
local get_action_context = reaper.get_action_context
reaper.get_action_context = function()
  local r = table.pack(get_action_context())
  r[2] = TARGET
  return table.unpack(r, 1, r.n)
end
local function guard(f)
  return function(...)
    local ok, e = xpcall(f, debug.traceback, ...)
    if not ok then on_err(e) end
  end
end
-- Modal prompts would block the bridge: answer them from the queue in answers.lua (written by
-- `rt run`), or with a cancel-style default. Every prompt is logged to console.log.
local ok_ans, answers = pcall(dofile, LOG_DIR .. "/answers.lua")
os.remove(LOG_DIR .. "/answers.lua")
if ok_ans and type(answers) == "table" then
  local MB_CANCEL = { [0] = 1, [1] = 2, [2] = 3, [3] = 2, [4] = 7, [5] = 2 }
  local defaults = {
    MB = function(_, _, t) return MB_CANCEL[t] or 2 end,
    ShowMessageBox = function(_, _, t) return MB_CANCEL[t] or 2 end,
    GetUserInputs = function() return false, "" end,
    GetUserFileNameForRead = function() return false, "" end,
    JS_Dialog_BrowseForSaveFile = function() return 0, "" end,
    JS_Dialog_BrowseForFolder = function() return 0, "" end,
    JS_Dialog_BrowseForOpenFiles = function() return 0, "" end,
  }
  for name, default in pairs(defaults) do
    if reaper[name] then
      local queue = answers[name] or {}
      reaper[name] = function(...)
        local a = table.remove(queue, 1)
        local r
        if a == nil then
          r = table.pack(default(...))
          on_err("unanswered prompt " .. name .. " (returned default)")
        else
          r = type(a) == "table" and table.pack(table.unpack(a)) or table.pack(a)
        end
        local args, rets = {}, {}
        for i = 1, select("#", ...) do args[i] = tostring((select(i, ...))) end
        for i = 1, r.n do rets[i] = tostring(r[i]) end
        append("console.log", "[prompt] " .. name .. "(" .. table.concat(args, ", ") .. ") -> "
          .. table.concat(rets, ", ") .. "\n")
        return table.unpack(r, 1, r.n)
      end
    end
  end
end
local defer, atexit = reaper.defer, reaper.atexit
reaper.defer = function(f) return defer(guard(f)) end
reaper.atexit = function(f) return atexit(guard(f)) end
local chunk, err = loadfile(TARGET)
if not chunk then on_err(err) return end
guard(chunk)()
]==]

-- Run a script as an action in its own Lua state (needed for defer/ReaImGui scripts and anything
-- that uses get_action_context to find its own path), through an error-catching wrapper.
function H.run_script(path)
  if not reaper.file_exists(path) then error("no such script: " .. path) end
  local wrap_dir = ROOT .. "/wrappers"
  reaper.RecursiveCreateDirectory(wrap_dir, 0)
  local wrapper = wrap_dir .. "/" .. path:match("[^/]+$"):gsub("[^%w%.]", "_")
  write_atomic(wrapper, WRAPPER:format(path, ROOT))
  local cmd = reaper.AddRemoveReaScript(true, 0, wrapper, true)
  if cmd == 0 then error("could not register script: " .. wrapper) end
  reaper.Main_OnCommand(cmd, 0)
  return "launched " .. path
end

---------------------------------------------------------------------------
-- Request handling
---------------------------------------------------------------------------

local function run_request(code)
  local buf = {}
  local function capture(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
      local v = select(i, ...)
      parts[i] = type(v) == "table" and serialize(v) or tostring(v)
    end
    buf[#buf + 1] = table.concat(parts, "\t")
  end
  local env = setmetatable({ print = capture, H = H, serialize = serialize }, { __index = _G })

  local chunk, err = load(code, "=snippet", "t", env)
  if not chunk then return false, err end
  local res = table.pack(xpcall(chunk, debug.traceback))
  local ok = res[1]
  if not ok then
    local lines = {}
    for line in tostring(res[2]):gmatch("[^\n]+") do
      if not line:find("Claude Bridge.lua", 1, true) and not line:find("'xpcall'", 1, true) then
        lines[#lines + 1] = line
      end
    end
    buf[#buf + 1] = table.concat(lines, "\n")
    return false, table.concat(buf, "\n")
  end
  for i = 2, res.n do
    local v = res[i]
    buf[#buf + 1] = type(v) == "table" and serialize(v) or tostring(v)
  end
  return true, table.concat(buf, "\n")
end

local last_poll = 0

local function poll()
  local now = reaper.time_precise()
  if now - last_poll >= POLL_INTERVAL then
    last_poll = now
    reaper.EnumerateFiles(INBOX, -1) -- invalidate directory cache
    local pending = {}
    local i = 0
    while true do
      local f = reaper.EnumerateFiles(INBOX, i)
      if not f then break end
      if f:match("%.lua$") then pending[#pending + 1] = f end
      i = i + 1
    end
    table.sort(pending)
    for _, f in ipairs(pending) do
      local path = INBOX .. "/" .. f
      local code = read_file(path)
      os.remove(path)
      if code then
        local id = f:gsub("%.lua$", "")
        local ok, out = run_request(code)
        write_atomic(OUTBOX .. "/" .. id .. ".txt", (ok and "OK\n" or "ERR\n") .. out)
      end
    end
  end
  reaper.defer(poll)
end

write_atomic(ROOT .. "/bridge.pid", tostring(os.time()))
poll()
