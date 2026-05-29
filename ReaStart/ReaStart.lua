-- @description ReaStart — Project Launcher
-- @author Stephen Schappler
-- @version 0.2.1
-- @about
--   Reaper project launcher: browse recent projects, pinned work, templates,
--   and watched folders. Requires ReaImGui 0.9+.

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("ReaImGui is required for this script.", "Missing Dependency", 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local script_path = ({reaper.get_action_context()})[2]
local script_dir  = script_path:match("^(.*[/\\])")
local theme_path  = script_dir .. "Common/ReaImGuiTheme.lua"
if not reaper.file_exists(theme_path) then
  theme_path = script_dir .. "../Common/ReaImGuiTheme.lua"
end
local ok_theme, theme = pcall(dofile, theme_path)
if not ok_theme then
  theme = { Push = function() return 0, 0 end, Pop = function() end }
end

-- ── Palette ───────────────────────────────────────────────────────────
local C = {
  bg       = 0x1a1a1aff,
  panel    = 0x222222ff,
  panel2   = 0x282828ff,
  panel3   = 0x323232ff,
  sel      = 0x3a3550ff,
  hover    = 0x262626ff,
  row_hover= 0x303030ff,
  border   = 0x2c2c2cff,
  border2  = 0x383838ff,
  text     = 0xe2e2e2ff,
  text2    = 0xb8b8b8ff,
  text3    = 0x909090ff,
  text4    = 0x6a6a6aff,
  accent   = 0x9b8fc4ff,
  accent2  = 0x6f6494ff,
  accentbg = 0x9b8fc424,
  warning  = 0xc89a4aff,
  danger   = 0xc75a5aff,
  info     = 0x6b8db8ff,
  pink     = 0xb079a3ff,
  teal     = 0x5fb09eff,
  orange   = 0xc78a4aff,
}

local TAG_COLORS = {
  mix        = 0xc78a4aff,
  master     = 0xb079a3ff,
  album      = 0x9b8fc4ff,
  live       = 0x6b8db8ff,
  sounddesign= 0x5fb09eff,
  scoring    = 0xc89a4aff,
  drums      = 0xc78a4aff,
  vocal      = 0xb079a3ff,
  podcast    = 0x6b8db8ff,
  client     = 0x9b8fc4ff,
  sketch     = 0x6c6c6cff,
  archive    = 0x4a4a4aff,
}

-- ── Context + fonts ───────────────────────────────────────────────────
local ctx = ImGui.CreateContext("ReaStart")
local _mono_obj = ImGui.CreateFont("Consolas", 11)
local FONT_MONO = _mono_obj and ImGui.Attach(ctx, _mono_obj) or nil

local WIN_FLAGS = ImGui.WindowFlags_NoCollapse
                | ImGui.WindowFlags_NoScrollbar
                | ImGui.WindowFlags_NoScrollWithMouse

local CHILD_BORDER = rawget(ImGui, "ChildFlags_Borders")
                  or rawget(ImGui, "ChildFlags_Border") or 1

-- ── ImGui constants (version-safe) ───────────────────────────────────
local SEL_SPAN = (rawget(ImGui, "SelectableFlags_SpanAllColumns") or 0)
               | (rawget(ImGui, "SelectableFlags_AllowOverlap")
                  or rawget(ImGui, "SelectableFlags_AllowItemOverlap") or 0)

local KEY_LCTRL  = rawget(ImGui, "Key_LeftCtrl")
local KEY_RCTRL  = rawget(ImGui, "Key_RightCtrl")
local KEY_LSHIFT = rawget(ImGui, "Key_LeftShift")
local KEY_RSHIFT = rawget(ImGui, "Key_RightShift")
local KEY_ESCAPE = rawget(ImGui, "Key_Escape")
local KEY_ENTER  = rawget(ImGui, "Key_Enter")
local KEY_K      = rawget(ImGui, "Key_K")
local KEY_UP     = rawget(ImGui, "Key_UpArrow")
local KEY_DOWN   = rawget(ImGui, "Key_DownArrow")

local TABLE_ROW_BG_TARGET = rawget(ImGui, "TableBgTarget_RowBg0") or 1

-- ── State ─────────────────────────────────────────────────────────────
local ui = {
  tab             = "recent",
  search          = "",
  tag_filter      = nil,
  selected_path   = nil,
  selected_paths  = {},   -- path -> true (multi-select)
  anchor_path     = nil,  -- shift-click range anchor (last plain click)
  selected_set_id = nil,  -- active set in Sets tab
  ctx_menu_open   = false,
  palette_open    = false,
  palette_q       = "",
  palette_sel     = 1,
  palette_focus   = false,
  flash_msg       = nil,
  flash_t         = 0,
  win_x           = 0,
  win_y           = 0,
  win_w           = 900,
  win_h           = 650,
}

local projects        = {}
local templates       = {}
local watched_folders = {}
local meta_cache      = {}
local all_tags        = {}
local notes_buf       = {}   -- full_path → live edit string

local settings = {
  density         = "comfort",
  show_path       = true,
  show_tags       = true,
  open_at_startup  = false,
  close_on_open    = true,
  accent          = "#9b8fc4",
}

local pinned        = {}   -- full_path → true
local project_tags  = {}   -- filename_key → {tag,...}
local project_notes = {}   -- filename_key → string
local last_opened   = {}   -- full_path → os.time()
local tag_registry  = {}   -- tag_name → 0xRRGGBBAA (user-defined colors)
local project_sets  = {}   -- set_id → { id, name, paths={} }
local sets_order    = {}   -- array of set_ids in insertion order

local tag_popup = {
  open        = false,
  skip_close  = false,
  proj_key    = nil,
  proj_path   = nil,
  creating    = false,
  focus_input = false,
  new_name    = "",
  new_color   = 0x9b8fc4ff,
}

local set_popup = {
  open        = false,
  skip_close  = false,
  name_buf    = "",
  focus_input = false,
  new_color   = 0x9b8fc4ff,
}

local DENSITY_H = { compact = 22, comfort = 32, detail = 48 }

-- ── Formatters ────────────────────────────────────────────────────────
local function fmt_ago(t)
  if not t then return "—" end
  local d = os.difftime(os.time(), t)
  if d < 60          then return "just now" end
  if d < 3600        then return math.floor(d / 60)           .. "m ago" end
  if d < 86400       then return math.floor(d / 3600)         .. "h ago" end
  if d < 86400 * 7   then return math.floor(d / 86400)        .. "d ago" end
  if d < 86400 * 30  then return math.floor(d / (86400*7))    .. "w ago" end
  return               math.floor(d / (86400*30))             .. "mo ago"
end

local function fmt_size(b)
  if not b or b == 0 then return "—" end
  if b >= 1073741824 then return string.format("%.1f GB", b / 1073741824) end
  if b >= 10485760   then return string.format("%d MB",   math.floor(b / 1048576)) end
  return string.format("%.1f MB", b / 1048576)
end

local function path_key(p)
  return (p:match("([^\\/]+)$") or p)
end

local function path_name(p)
  local base = path_key(p)
  return base:match("^(.-)%.[^.]*$") or base
end

local function new_set_id()
  return "set_" .. tostring(os.time()) .. "_" .. tostring(math.random(999))
end

local function selection_count()
  local n = 0
  for _ in pairs(ui.selected_paths) do n = n + 1 end
  return n
end

local function selection_list()
  local out = {}
  for p in pairs(ui.selected_paths) do out[#out + 1] = p end
  return out
end

local function clear_selection()
  ui.selected_paths = {}
  ui.selected_path  = nil
  ui.anchor_path    = nil
end

-- ── Tag utilities ─────────────────────────────────────────────────────
local function get_tag_color(name)
  return tag_registry[name] or TAG_COLORS[name] or C.text3
end

local function has_tag(key, name)
  for _, t in ipairs(project_tags[key] or {}) do
    if t == name then return true end
  end
  return false
end

local function toggle_project_tag(key, name)
  local tags = project_tags[key] or {}
  for i, t in ipairs(tags) do
    if t == name then
      table.remove(tags, i)
      project_tags[key] = tags
      return
    end
  end
  tags[#tags + 1] = name
  project_tags[key] = tags
end

local function remove_project_tag(key, name)
  local tags = project_tags[key] or {}
  for i, t in ipairs(tags) do
    if t == name then
      table.remove(tags, i)
      project_tags[key] = tags
      return
    end
  end
end

local function rebuild_all_tags()
  local seen = {}
  all_tags = {}
  for _, p in ipairs(projects) do
    for _, t in ipairs(project_tags[p.key] or {}) do
      if not seen[t] then seen[t] = true; all_tags[#all_tags+1] = t end
    end
  end
  table.sort(all_tags)
end

local function group_of(t)
  if not t then return "Earlier" end
  local d = os.difftime(os.time(), t)
  if d < 86400     then return "Today" end
  if d < 86400*2   then return "Yesterday" end
  if d < 86400*7   then return "This week" end
  if d < 86400*30  then return "This month" end
  return "Earlier"
end

-- ── File-based persistence ────────────────────────────────────────────
-- User data lives in a file separate from the script so updates never
-- wipe tags, notes, pinned projects, or sets.
local DATA_FILE = reaper.GetResourcePath() .. "/Data/ReaStart_data.lua"

-- Recursive Lua-value serialiser (handles strings, numbers, booleans, tables).
local function serialize(v)
  local t = type(v)
  if t == "nil"     then return "nil"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number"  then
    if v == math.floor(v) and math.abs(v) < 2^53 then
      return string.format("%d", v)   -- integer (timestamps, color ints)
    else
      return string.format("%.17g", v)
    end
  elseif t == "string" then return string.format("%q", v)
  elseif t == "table"  then
    local parts = {}
    local n = #v
    for i = 1, n do parts[#parts + 1] = serialize(v[i]) end
    for k, val in pairs(v) do
      local seq = type(k) == "number" and k == math.floor(k) and k >= 1 and k <= n
      if not seq then
        local key = (type(k) == "string" and k:match("^[%a_][%w_]*$"))
                    and k or ("[" .. serialize(k) .. "]")
        parts[#parts + 1] = key .. "=" .. serialize(val)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  else
    return "nil"
  end
end

local function save_all_state()
  local wf = {}
  for _, f in ipairs(watched_folders) do
    wf[#wf + 1] = { path = f.path, watch = f.watch }
  end
  local data = {
    pinned        = pinned,
    project_tags  = project_tags,
    project_notes = project_notes,
    last_opened   = last_opened,
    tag_registry  = tag_registry,
    watched_folders = wf,
    settings      = settings,
    project_sets  = project_sets,
    sets_order    = sets_order,
  }
  local f = io.open(DATA_FILE, "w")
  if not f then return end
  f:write("return " .. serialize(data) .. "\n")
  f:close()
end

-- ── ExtState layer (kept for one-time migration) ──────────────────────
local EXT = "ReaStart"

local function es_get(k)    return reaper.GetExtState(EXT, k) end
local function es_set(k, v) reaper.SetExtState(EXT, k, v, true) end
local function es_has(k)    return reaper.HasExtState(EXT, k) end

local function load_from_extstate()
  for path in es_get("pinned"):gmatch("[^\n]+") do
    pinned[path] = true
  end
  for fname in es_get("tags_index"):gmatch("[^\n]+") do
    local ts = es_get("tags/" .. fname)
    if ts ~= "" then
      project_tags[fname] = {}
      for tag in ts:gmatch("[^,]+") do
        project_tags[fname][#project_tags[fname] + 1] = tag
      end
    end
  end
  for fname in es_get("notes_index"):gmatch("[^\n]+") do
    local n = es_get("notes/" .. fname)
    if n ~= "" then project_notes[fname] = n end
  end
  for line in es_get("last_opened"):gmatch("[^\n]+") do
    local path, t = line:match("^(.*)\t(%d+)$")
    if path and t then last_opened[path] = tonumber(t) end
  end
  for line in es_get("watched_folders"):gmatch("[^\n]+") do
    watched_folders[#watched_folders + 1] = { path = line, watch = true }
  end
  if es_has("settings/density")      then settings.density         = es_get("settings/density") end
  if es_has("settings/show_path")    then settings.show_path       = es_get("settings/show_path") == "1" end
  if es_has("settings/show_tags")    then settings.show_tags       = es_get("settings/show_tags") == "1" end
  if es_has("settings/startup")      then settings.open_at_startup = es_get("settings/startup") == "1" end
  if es_has("settings/close_on_open") then settings.close_on_open  = es_get("settings/close_on_open") == "1" end
  if es_has("settings/accent")       then settings.accent          = es_get("settings/accent") end
  for line in es_get("tag_registry"):gmatch("[^\n]+") do
    local name, hex = line:match("^(.+)\t([0-9a-fA-F]+)$")
    if name and hex then tag_registry[name] = tonumber(hex, 16) end
  end
  for id in es_get("sets_index"):gmatch("[^\n]+") do
    local name = es_get("sets/" .. id .. "/name")
    local paths = {}
    for p in es_get("sets/" .. id .. "/paths"):gmatch("[^\n]+") do
      paths[#paths + 1] = p
    end
    if name ~= "" then
      project_sets[id] = { id = id, name = name, paths = paths }
      sets_order[#sets_order + 1] = id
    end
  end
end

local function load_all_state()
  -- Try data file first
  local chunk = loadfile(DATA_FILE)
  if chunk then
    local ok, data = pcall(chunk)
    if ok and type(data) == "table" then
      for k, v in pairs(data.pinned        or {}) do pinned[k]        = v end
      for k, v in pairs(data.project_tags  or {}) do project_tags[k]  = v end
      for k, v in pairs(data.project_notes or {}) do project_notes[k] = v end
      for k, v in pairs(data.last_opened   or {}) do last_opened[k]   = v end
      for k, v in pairs(data.tag_registry  or {}) do tag_registry[k]  = v end
      for _, f in ipairs(data.watched_folders or {}) do
        watched_folders[#watched_folders + 1] = f
      end
      for k, v in pairs(data.settings or {}) do settings[k] = v end
      for k, v in pairs(data.project_sets or {}) do project_sets[k] = v end
      for _, id in ipairs(data.sets_order or {}) do
        sets_order[#sets_order + 1] = id
      end
      -- Seed built-in tag palette for any tag not yet in registry
      for name, col in pairs(TAG_COLORS) do
        if not tag_registry[name] then tag_registry[name] = col end
      end
      return  -- loaded from file, done
    end
  end

  -- No data file found — migrate from ExtState (first run after update)
  load_from_extstate()
  for name, col in pairs(TAG_COLORS) do
    if not tag_registry[name] then tag_registry[name] = col end
  end
  save_all_state()  -- write the data file so future runs load from it
end

local function save_settings()        save_all_state() end
local function save_pinned()          save_all_state() end
local function save_project_data(_)   save_all_state() end
local function save_last_opened_state() save_all_state() end
local function save_watched_folders() save_all_state() end
local function save_tag_registry()    save_all_state() end
local function save_sets()            save_all_state() end

-- ── Data layer ────────────────────────────────────────────────────────

-- Parse recent project paths from reaper.ini.
-- Keys are "recent01", "recent02", ... under [Recent].
local function get_recent_files()
  local files = {}
  local seen  = {}

  local function add(p)
    if not p or p == "" then return end
    p = p:match("^%s*(.-)%s*$")  -- trim whitespace / CR
    if p == "" or seen[p] then return end
    seen[p] = true
    files[#files + 1] = p
  end

  -- Try native API first (present in some Reaper builds)
  if reaper.GetRecentFile then
    local i = 0
    repeat
      local p = reaper.GetRecentFile(i)
      add(p)
      i = i + 1
    until (not p or p == "") or i > 200
    if #files > 0 then return files end
  end

  -- Fallback: parse [Recent] section of reaper.ini.
  -- Keys: recent01=path, recent02=path, … (any alphanumeric key is accepted)
  local ini_path = reaper.GetResourcePath() .. "/reaper.ini"
  local f = io.open(ini_path, "r")
  if not f then
    ini_path = reaper.GetResourcePath() .. "\\reaper.ini"
    f = io.open(ini_path, "r")
  end

  if f then
    local in_recent = false
    for line in f:lines() do
      line = line:match("^(.-)%s*$")  -- strip trailing CR/whitespace
      local section = line:match("^%[(.-)%]")
      if section then
        in_recent = (section:lower() == "recent")
      elseif in_recent and line ~= "" then
        -- Accept any key=value; filter by .rpp / .rpt / .RPP extension
        local val = line:match("^[^=]+=(.+)$")
        if val then
          local ext = (val:match("%.([^.]+)$") or ""):lower()
          if ext == "rpp" or ext == "rpt" then
            add(val)
          end
        end
      end
      if #files >= 200 then break end
    end
    f:close()
  end

  return files
end

local function get_templates()
  local dir = reaper.GetResourcePath() .. "/ProjectTemplates"
  local result = {}
  local i = 0
  repeat
    local f = reaper.EnumerateFiles(dir, i)
    if f and f ~= "" then
      local ext = (f:match("%.([^.]+)$") or ""):lower()
      if ext == "rpt" or ext == "rpp" then
        result[#result + 1] = {
          name = (f:match("^(.-)%.[^.]*$") or f),
          file = f,
          path = dir .. "/" .. f,
        }
      end
    end
    i = i + 1
  until not f or f == "" or i > 500
  return result
end

local function get_folder_files(dir)
  local result = {}
  local i = 0
  repeat
    local f = reaper.EnumerateFiles(dir, i)
    if f and f ~= "" then
      local ext = (f:match("%.([^.]+)$") or ""):lower()
      if ext == "rpp" then result[#result + 1] = dir .. "/" .. f end
    end
    i = i + 1
  until not f or f == "" or i > 1000
  return result
end

local function file_size(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local sz = f:seek("end") or 0
  f:close()
  return sz
end

local function parse_rpp(path)
  if meta_cache[path] then return meta_cache[path] end
  local f = io.open(path, "r")
  if not f then return nil end
  local m = { bpm = 0, sr = 48000, tracks = 0 }
  local n = 0
  for line in f:lines() do
    n = n + 1
    if n > 400 then break end
    local bpm = line:match("^%s*TEMPO%s+([%d%.]+)")
    if bpm then m.bpm = tonumber(bpm) or m.bpm end
    local sr = line:match("^%s*SAMPLERATE%s+(%d+)")
    if sr then m.sr = tonumber(sr) or m.sr end
    if line:match("^%s*<TRACK") then m.tracks = m.tracks + 1 end
  end
  f:close()
  meta_cache[path] = m
  return m
end

-- Rough timestamp estimates for projects with no ExtState record
local function recency_estimate(idx)
  local b = os.time()
  -- Monotonically-decreasing offsets so position always determines sort order
  local offsets = {
         300,  -- 1: ~5m
        3600,  -- 2: ~1h
        7200,  -- 3: ~2h
       14400,  -- 4: ~4h
       28800,  -- 5: ~8h
       86400,  -- 6: ~1d
      172800,  -- 7: ~2d
      345600,  -- 8: ~4d
      604800,  -- 9: ~1w
     1209600,  -- 10: ~2w
     1814400,  -- 11: ~3w
     2592000,  -- 12: ~1mo
  }
  return b - (offsets[idx] or (86400 * (30 + idx)))
end

-- Group label when no real timestamp; based on rank in recent list
local function rank_group(rank)
  if rank <= 2  then return "Today" end
  if rank <= 6  then return "This week" end
  if rank <= 12 then return "This month" end
  return "Earlier"
end

local function build_project_list()
  local seen   = {}
  local result = {}

  for i, path in ipairs(get_recent_files()) do
    if not seen[path] then
      seen[path] = true
      local k        = path_key(path)
      local real_t   = last_opened[path]
      local display_t = real_t or recency_estimate(i)
      local sz       = file_size(path)
      result[#result + 1] = {
        name     = path_name(path),
        path     = path,
        key      = k,
        rank     = i,
        pinned   = pinned[path] or false,
        tags     = project_tags[k] or {},
        notes    = project_notes[k] or "",
        last_t   = display_t,
        last_str = fmt_ago(display_t),
        size_b   = sz,
        size_str = fmt_size(sz),
        group    = real_t and group_of(real_t) or rank_group(i),
      }
    end
  end

  for _, folder in ipairs(watched_folders) do
    if folder.watch then
      for _, path in ipairs(get_folder_files(folder.path)) do
        if not seen[path] then
          seen[path] = true
          local k = path_key(path)
          local t = last_opened[path] or (os.time() - 86400 * 60)
          local sz = file_size(path)
          result[#result + 1] = {
            name     = path_name(path),
            path     = path,
            key      = k,
            pinned   = pinned[path] or false,
            tags     = project_tags[k] or {},
            notes    = project_notes[k] or "",
            last_t   = t,
            last_str = fmt_ago(t),
            size_b   = sz,
            size_str = fmt_size(sz),
            group    = group_of(t),
          }
        end
      end
    end
  end

  -- Sort: pinned first, then by Reaper's recent-list rank (position = truth for recency)
  table.sort(result, function(a, b)
    if a.pinned ~= b.pinned then return a.pinned end
    return (a.rank or 0) > (b.rank or 0)
  end)

  projects = result

  local tag_set = {}
  for _, p in ipairs(projects) do
    for _, t in ipairs(p.tags) do tag_set[t] = true end
  end
  all_tags = {}
  for t in pairs(tag_set) do all_tags[#all_tags + 1] = t end
  table.sort(all_tags)
end

-- ── Open project ──────────────────────────────────────────────────────

-- Returns the ReaProject handle if path is already open in a tab, else nil.
-- Normalises path separators and case (Windows paths are case-insensitive).
local function find_open_project(path)
  local target = path:lower():gsub("\\", "/")
  local i = 0
  while true do
    local proj, proj_path = reaper.EnumProjects(i, "")
    if not proj then break end
    if proj_path:lower():gsub("\\", "/") == target then return proj end
    i = i + 1
  end
end

local function open_project(path)
  if not reaper.file_exists(path) then
    ui.flash_msg = "File not found: " .. path_name(path)
    ui.flash_t   = os.time()
    return
  end
  local existing = find_open_project(path)
  if existing then
    reaper.SelectProjectInstance(existing)
    ui.flash_msg = "Already open: " .. path_name(path)
    ui.flash_t   = os.time()
    return
  end
  reaper.Main_openProject(path)
  last_opened[path] = os.time()
  save_last_opened_state()
  ui.flash_msg = "Opened  " .. path_name(path)
  ui.flash_t   = os.time()
  if settings.close_on_open then
    ui.close_requested = true
  else
    build_project_list()
  end
end

local function open_project_set(set_id)
  local s = project_sets[set_id]
  if not s then return end
  local opened, skipped = 0, 0
  for _, path in ipairs(s.paths) do
    if reaper.file_exists(path) then
      if find_open_project(path) then
        skipped = skipped + 1
      else
        reaper.Main_OnCommand(40859, 0)              -- New project tab
        reaper.Main_openProject("noprompt:" .. path) -- Load project into that tab
        last_opened[path] = os.time()
        opened = opened + 1
      end
    end
  end
  save_last_opened_state()
  build_project_list()
  local msg
  if opened > 0 then
    msg = "Opened " .. opened .. " project" .. (opened ~= 1 and "s" or "")
          .. " from \"" .. s.name .. "\""
    if skipped > 0 then
      msg = msg .. " (" .. skipped .. " already open)"
    end
  elseif skipped > 0 then
    msg = "All projects in \"" .. s.name .. "\" already open"
  else
    msg = "No valid files in set \"" .. s.name .. "\""
  end
  ui.flash_msg = msg
  ui.flash_t   = os.time()
end

local function reveal_path(path)
  if reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(path)
  else
    local dir = path:match("^(.*[/\\])") or path
    os.execute('explorer "' .. dir:gsub("/", "\\") .. '"')
  end
end

-- ── Theme push/pop ────────────────────────────────────────────────────
local rs_nc, rs_nv = 0, 0

local function push_rs_theme()
  local colors = {
    { ImGui.Col_WindowBg,        C.bg     },
    { ImGui.Col_ChildBg,         C.panel  },
    { ImGui.Col_PopupBg,         C.panel2 },
    { ImGui.Col_Border,          C.border },
    { ImGui.Col_BorderShadow,    0x00000000 },
    { ImGui.Col_FrameBg,         C.panel2 },
    { ImGui.Col_FrameBgHovered,  C.panel3 },
    { ImGui.Col_FrameBgActive,   C.panel3 },
    { ImGui.Col_Header,          C.sel    },
    { ImGui.Col_HeaderHovered,   C.row_hover },
    { ImGui.Col_HeaderActive,    C.accent2},
    { ImGui.Col_Button,          C.panel2 },
    { ImGui.Col_ButtonHovered,   C.panel3 },
    { ImGui.Col_ButtonActive,    C.border2},
    { ImGui.Col_Text,            C.text   },
    { ImGui.Col_TextDisabled,    C.text3  },
    { ImGui.Col_CheckMark,       C.accent },
    { ImGui.Col_SliderGrab,      C.accent },
    { ImGui.Col_ScrollbarBg,     C.bg     },
    { ImGui.Col_ScrollbarGrab,   C.panel3 },
    { ImGui.Col_ScrollbarGrabHovered, C.border2 },
    { ImGui.Col_Separator,       C.border },
  }
  local tab_names = {
    "Col_Tab", "Col_TabHovered", "Col_TabActive",
    "Col_TabUnfocused", "Col_TabUnfocusedActive",
  }
  local tab_vals = { C.bg, C.panel2, C.panel2, C.bg, C.panel2 }
  for i, name in ipairs(tab_names) do
    local e = rawget(ImGui, name)
    if e then colors[#colors + 1] = { e, tab_vals[i] } end
  end

  for _, c in ipairs(colors) do ImGui.PushStyleColor(ctx, c[1], c[2]) end
  rs_nc = #colors

  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding,    6)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding,     4)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_GrabRounding,      4)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ScrollbarRounding,  6)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing,       6, 3)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding,     0, 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding,      6, 3)
  rs_nv = 7
end

local function pop_rs_theme()
  ImGui.PopStyleColor(ctx, rs_nc)
  ImGui.PopStyleVar(ctx, rs_nv)
end

-- ── Font helpers (no-op if FONT_MONO failed to load) ─────────────────
local function push_mono() if FONT_MONO then ImGui.PushFont(ctx, FONT_MONO) end end
local function pop_mono()  if FONT_MONO then ImGui.PopFont(ctx) end end

-- ── Utility: push a simple button style ──────────────────────────────
local function push_btn(bg, hov, act)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, hov)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  act)
end
local function pop_btn() ImGui.PopStyleColor(ctx, 3) end

-- ── Render: top bar ───────────────────────────────────────────────────
local function render_topbar()
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.panel)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 8, 0)
  if ImGui.BeginChild(ctx, "##topbar", 0, 36, 0) then
    ImGui.SetCursorPos(ctx, 8, 8)
    -- Brand
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
    ImGui.Text(ctx, "ReaStart")
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.border2)
    ImGui.Text(ctx, "│")
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    -- Search
    local avail = ImGui.GetContentRegionAvail(ctx)
    ImGui.SetNextItemWidth(ctx, avail - 4)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, C.bg)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,    C.text2)
    local changed, new_s = ImGui.InputText(ctx, "##search", ui.search, 256)
    if changed then ui.search = new_s end
    ImGui.PopStyleColor(ctx, 2)
  end
  ImGui.EndChild(ctx)
  ImGui.PopStyleVar(ctx)
  ImGui.PopStyleColor(ctx)

  -- Hairline separator
  local dl = ImGui.GetWindowDrawList(ctx)
  local wx, wy = ImGui.GetWindowPos(ctx)
  ImGui.DrawList_AddLine(dl, wx, wy + 36, wx + ImGui.GetWindowWidth(ctx), wy + 36, C.border, 1)
end

-- ── Render: tag bar ────────────────────────────────────────────────────
local function render_tag_bar()
  if #all_tags == 0 then return end
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.bg)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 4, 0)
  local tbv = ImGui.BeginChild(ctx, "##tagbar", 0, 26, 0)
  if tbv then
    ImGui.SetCursorPos(ctx, 8, 5)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
    ImGui.Text(ctx, "Tags")
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    for _, tag in ipairs(all_tags) do
      local tc     = get_tag_color(tag)
      local active = (ui.tag_filter == tag)
      if active then
        push_btn(C.accentbg, C.accentbg, C.sel)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      else
        push_btn(0x00000000, C.panel2, C.panel3)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, tc)
      end
      if ImGui.SmallButton(ctx, "● " .. tag .. "##t_" .. tag) then
        ui.tag_filter = (ui.tag_filter == tag) and nil or tag
      end
      ImGui.PopStyleColor(ctx, 4)
      ImGui.SameLine(ctx)
    end
    if ui.tag_filter then
      push_btn(0x00000000, C.panel2, C.panel3)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
      if ImGui.SmallButton(ctx, "✕ clear##tagclear") then ui.tag_filter = nil end
      ImGui.PopStyleColor(ctx, 4)
    end
    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleVar(ctx)
  ImGui.PopStyleColor(ctx)
end

-- ── Render: resume card ────────────────────────────────────────────────
local function render_resume_card(proj)
  if not proj then return end
  local card_h = 72
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.panel2)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
  local cv = ImGui.BeginChild(ctx, "##resume", 0, card_h, CHILD_BORDER)
  if cv then
    local dl     = ImGui.GetWindowDrawList(ctx)
    local wx, wy = ImGui.GetWindowPos(ctx)
    local ww     = ImGui.GetWindowWidth(ctx)

    -- Accent-tinted gradient bg (left 60%)
    ImGui.DrawList_AddRectFilled(dl, wx, wy, wx + math.floor(ww * 0.6), wy + card_h, C.accentbg)
    -- 3px accent left border
    ImGui.DrawList_AddRectFilled(dl, wx, wy, wx + 3, wy + card_h, C.accent)

    -- Eyebrow: pulsing dot + label
    ImGui.SetCursorPos(ctx, 14, 10)
    local pulse = 0.55 + 0.45 * math.abs(math.sin(ImGui.GetTime(ctx) * math.pi))
    local dot_c = (C.teal & 0xffffff00) | math.floor(pulse * 255)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, dot_c)
    ImGui.Text(ctx, "●")
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx, 0, 4)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.Text(ctx, "RESUME LAST SESSION")
    ImGui.PopStyleColor(ctx)

    -- Project name
    ImGui.SetCursorPos(ctx, 14, 29)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text)
    ImGui.Text(ctx, proj.name)
    ImGui.PopStyleColor(ctx)

    -- Meta row: last_str · tracks · bpm
    ImGui.SetCursorPos(ctx, 14, 50)
    push_mono()
    local meta  = parse_rpp(proj.path) or {}
    local parts = { proj.last_str }
    if meta.tracks and meta.tracks > 0 then
      parts[#parts + 1] = meta.tracks .. " trk"
    end
    if meta.bpm and meta.bpm > 0 then
      parts[#parts + 1] = string.format("%.0f bpm", meta.bpm)
    end
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.Text(ctx, table.concat(parts, "  ·  "))
    ImGui.PopStyleColor(ctx)
    pop_mono()

    -- Resume button (right-aligned, vertically centred)
    local btn_w, btn_h = 76, 26
    ImGui.SetCursorPos(ctx, ww - btn_w - 10, math.floor((card_h - btn_h) * 0.5))
    push_btn(C.accent2, C.accent, C.accent2)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xffffffff)
    if ImGui.Button(ctx, "Resume##resume_btn", btn_w, btn_h) then
      open_project(proj.path)
    end
    ImGui.PopStyleColor(ctx)
    pop_btn()

    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleVar(ctx)
  ImGui.PopStyleColor(ctx)
end

-- ── Render: project table ─────────────────────────────────────────────
local function tag_color_for(tags)
  for _, t in ipairs(tags) do
    local col = tag_registry[t] or TAG_COLORS[t]
    if col then return col end
  end
  return nil
end

local function render_project_table(list)
  if #list == 0 then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
    ImGui.SetCursorPos(ctx, 10, 8)
    ImGui.Text(ctx, "No projects found.")
    ImGui.PopStyleColor(ctx)
    return
  end

  -- Row height: for multi-line rows we use a fixed 5px top pad + per-line height +
  -- 4px bottom pad so the Selectable and stripe exactly cover all sub-lines.
  -- Compact keeps its old centering approach.
  local lh_sp  = ImGui.GetTextLineHeightWithSpacing(ctx)
  local n_sub  = 0
  if settings.density ~= "compact" and settings.show_path then n_sub = n_sub + 1 end
  if settings.density == "detail"  and settings.show_tags then n_sub = n_sub + 1 end
  local row_h
  if settings.density == "compact" then
    row_h = DENSITY_H.compact  -- 22px, single line centered
  else
    row_h = math.ceil(5 + (1 + n_sub) * lh_sp + 4)
    row_h = math.max(row_h, DENSITY_H[settings.density] or 32)
  end

  local tbl_flags = ImGui.TableFlags_BordersInnerV
                  | (rawget(ImGui, "TableFlags_NoPadOuterX") or 0)

  if not ImGui.BeginTable(ctx, "##projtbl", 3, tbl_flags) then return end

  ImGui.TableSetupColumn(ctx, "##name", ImGui.TableColumnFlags_WidthStretch)
  ImGui.TableSetupColumn(ctx, "##last", ImGui.TableColumnFlags_WidthFixed, 72)
  ImGui.TableSetupColumn(ctx, "##act",  ImGui.TableColumnFlags_WidthFixed, 72)

  local dl         = ImGui.GetWindowDrawList(ctx)
  local win_sx, _  = ImGui.GetWindowPos(ctx)
  local win_sw     = ImGui.GetWindowWidth(ctx)
  local last_group = nil

  -- Precompute per-group counts for the header badges
  local group_counts = {}
  for _, p in ipairs(list) do
    group_counts[p.group] = (group_counts[p.group] or 0) + 1
  end

  for _, proj in ipairs(list) do
    -- Group header row: label ── line ── count
    if proj.group ~= last_group then
      last_group = proj.group
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.Dummy(ctx, 0, 4)
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)

      local label = proj.group:upper()
      local cnt   = tostring(group_counts[proj.group] or 0)

      ImGui.SetCursorPosX(ctx, 10)
      push_mono()
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
      ImGui.Text(ctx, label)
      -- Get right edge of label text via SameLine trick
      ImGui.SameLine(ctx, 0, 0)
      local tx, ty = ImGui.GetCursorScreenPos(ctx)
      local wx0, _ = ImGui.GetWindowPos(ctx)
      local right_x = wx0 + ImGui.GetWindowWidth(ctx) - 8
      ImGui.DrawList_AddLine(dl, tx + 5, ty + 7, right_x - 24, ty + 7, C.border2, 1)
      ImGui.SetCursorPosX(ctx, ImGui.GetWindowWidth(ctx) - 26)
      ImGui.Text(ctx, cnt)
      ImGui.PopStyleColor(ctx)
      pop_mono()

      ImGui.Dummy(ctx, 0, 2)
    end

    -- Data row
    local is_sel = (ui.selected_paths[proj.path] == true)
    ImGui.TableNextRow(ctx, 0, row_h)
    ImGui.TableSetColumnIndex(ctx, 0)
    local cx, cy = ImGui.GetCursorPos(ctx)
    local sx, sy = ImGui.GetCursorScreenPos(ctx)

    -- Selectable hit area; is_sel drives Col_Header highlight
    ImGui.SetCursorPos(ctx, cx + 4, cy)
    local clicked = ImGui.Selectable(ctx, "##row_" .. proj.path, is_sel, SEL_SPAN, 0, row_h)
    if clicked then
      local ctrl  = (KEY_LCTRL  and ImGui.IsKeyDown(ctx, KEY_LCTRL))
                 or (KEY_RCTRL  and ImGui.IsKeyDown(ctx, KEY_RCTRL))
      local shift = (KEY_LSHIFT and ImGui.IsKeyDown(ctx, KEY_LSHIFT))
                 or (KEY_RSHIFT and ImGui.IsKeyDown(ctx, KEY_RSHIFT))

      if shift and ui.anchor_path then
        -- Range-select: find anchor and target in the current list, select all between
        local a_idx, b_idx
        for i, p in ipairs(list) do
          if p.path == ui.anchor_path then a_idx = i end
          if p.path == proj.path      then b_idx = i end
        end
        if a_idx and b_idx then
          if a_idx > b_idx then a_idx, b_idx = b_idx, a_idx end
          ui.selected_paths = {}
          for i = a_idx, b_idx do
            ui.selected_paths[list[i].path] = true
          end
        end
        ui.selected_path = proj.path
        -- anchor stays unchanged for chained shift-clicks
      elseif ctrl then
        if ui.selected_paths[proj.path] then
          ui.selected_paths[proj.path] = nil
        else
          ui.selected_paths[proj.path] = true
          ui.selected_path = proj.path
        end
        -- ctrl-click doesn't move the anchor
      else
        ui.selected_paths = { [proj.path] = true }
        ui.selected_path  = proj.path
        ui.anchor_path    = proj.path
      end
    end
    local row_hovered = ImGui.IsItemHovered(ctx)
    if row_hovered and ImGui.IsMouseDoubleClicked(ctx, 0) then
      open_project(proj.path)
    end
    if row_hovered and ImGui.IsMouseClicked(ctx, 1) then
      if not ui.selected_paths[proj.path] then
        ui.selected_paths = { [proj.path] = true }
        ui.selected_path  = proj.path
      end
      ui.ctx_menu_open = true
    end

    -- Content overlaid on the selectable
    ImGui.SameLine(ctx)
    local text_y = cy + (settings.density == "compact"
      and math.max(2, math.floor((row_h - 14) * 0.28))
      or 5)
    ImGui.SetCursorPos(ctx, cx + 14, text_y)

    if proj.pinned then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      ImGui.Text(ctx, "★")
      ImGui.PopStyleColor(ctx)
      ImGui.SameLine(ctx)
    end

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text)
    ImGui.Text(ctx, proj.name)
    ImGui.PopStyleColor(ctx)

    -- Second line: path (explicit Y so it stays inside the Selectable's area)
    if settings.density ~= "compact" and settings.show_path then
      ImGui.SetCursorPos(ctx, cx + 14, text_y + lh_sp)
      push_mono()
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
      ImGui.Text(ctx, proj.path)
      ImGui.PopStyleColor(ctx)
      pop_mono()
    end

    -- Third line: tags (explicit Y based on how many lines precede it)
    if settings.density == "detail" and settings.show_tags and #proj.tags > 0 then
      local path_lines = settings.show_path and 1 or 0
      ImGui.SetCursorPos(ctx, cx + 14, text_y + (1 + path_lines) * lh_sp)
      for j, tag in ipairs(proj.tags) do
        if j > 4 then break end
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, get_tag_color(tag))
        ImGui.Text(ctx, "● " .. tag)
        ImGui.PopStyleColor(ctx)
        ImGui.SameLine(ctx)
      end
    end

    -- Color stripe drawn last (on top of row bg, 3px wide, no text overlap at 14px indent)
    local stripe_c = tag_color_for(proj.tags)
    if not stripe_c and proj.pinned then stripe_c = C.accent end
    if stripe_c then
      ImGui.DrawList_AddRectFilled(dl, sx, sy, sx + 3, sy + row_h, stripe_c)
    end

    -- Subtle separator between rows
    ImGui.DrawList_AddLine(dl, win_sx, sy + row_h - 1, win_sx + win_sw, sy + row_h - 1, C.border, 1)

    -- Last opened column
    ImGui.TableSetColumnIndex(ctx, 1)
    push_mono()
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.Text(ctx, proj.last_str)
    ImGui.PopStyleColor(ctx)
    pop_mono()

    -- Actions column (reveal when row is hovered or selected)
    ImGui.TableSetColumnIndex(ctx, 2)
    if row_hovered or is_sel then
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 2, 0)
      push_btn(0x00000000, C.panel3, C.border)
      ImGui.SetCursorPosY(ctx, cy + math.max(2, math.floor((row_h - 16) * 0.5)))

      ImGui.PushStyleColor(ctx, ImGui.Col_Text, proj.pinned and C.accent or C.text3)
      if ImGui.SmallButton(ctx, (proj.pinned and "★" or "☆") .. "##pin_" .. proj.path) then
        if pinned[proj.path] then pinned[proj.path] = nil; proj.pinned = false
        else                      pinned[proj.path] = true; proj.pinned = true end
        save_pinned()
      end
      ImGui.PopStyleColor(ctx)
      ImGui.SameLine(ctx)

      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
      if ImGui.SmallButton(ctx, "⇱##rv_" .. proj.path) then reveal_path(proj.path) end
      ImGui.PopStyleColor(ctx)
      ImGui.SameLine(ctx)

      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      if ImGui.SmallButton(ctx, "▶##op_" .. proj.path) then open_project(proj.path) end
      ImGui.PopStyleColor(ctx)

      pop_btn()
      ImGui.PopStyleVar(ctx)
    end
  end

  ImGui.EndTable(ctx)

  -- Context menu (triggered by right-click in the row loop above)
  if ui.ctx_menu_open then
    ImGui.OpenPopup(ctx, "##proj_ctx")
    ui.ctx_menu_open = false
  end
  if ImGui.BeginPopup(ctx, "##proj_ctx") then
    local n = selection_count()
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.Text(ctx, n .. " project" .. (n ~= 1 and "s" or "") .. " selected")
    ImGui.PopStyleColor(ctx)
    ImGui.Separator(ctx)
    if ImGui.MenuItem(ctx, "Create new project set\xe2\x80\xa6") then
      set_popup.open        = true
      set_popup.name_buf    = ""
      set_popup.new_color   = C.accent
      set_popup.focus_input = true
      set_popup.skip_close  = true
    end
    if #sets_order > 0 then
      if ImGui.BeginMenu(ctx, "Add to existing set") then
        for _, id in ipairs(sets_order) do
          local s = project_sets[id]
          if ImGui.MenuItem(ctx, s.name .. "##addto_" .. id) then
            for path in pairs(ui.selected_paths) do
              local dup = false
              for _, p in ipairs(s.paths) do if p == path then dup = true; break end end
              if not dup then s.paths[#s.paths + 1] = path end
            end
            save_sets()
            ui.flash_msg = "Added to \"" .. s.name .. "\""
            ui.flash_t   = os.time()
          end
        end
        ImGui.EndMenu(ctx)
      end
    end
    ImGui.EndPopup(ctx)
  end
end

-- ── Render: filtered project list ─────────────────────────────────────
local function filtered_projects(source)
  local result = {}
  local q = ui.search:lower()
  for _, p in ipairs(source) do
    local name_match = q == "" or p.name:lower():find(q, 1, true)
    local path_match = q == "" or p.path:lower():find(q, 1, true)
    if (name_match or path_match) then
      if not ui.tag_filter then
        result[#result + 1] = p
      else
        for _, t in ipairs(p.tags) do
          if t == ui.tag_filter then
            result[#result + 1] = p
            break
          end
        end
      end
    end
  end
  return result
end

-- ── Render: recent panel ──────────────────────────────────────────────
local function render_recent_panel()
  local list = filtered_projects(projects)

  -- Resume card (with 10px left margin matching the project rows)
  if #projects > 0 and ui.search == "" and not ui.tag_filter then
    ImGui.Dummy(ctx, 0, 6)
    ImGui.SetCursorPosX(ctx, 10)
    render_resume_card(projects[1])
    ImGui.Dummy(ctx, 0, 4)
  end

  render_tag_bar()

  ImGui.Dummy(ctx, 0, 2)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
  ImGui.SetCursorPosX(ctx, 10)
  push_mono()
  ImGui.Text(ctx, #list .. " / " .. #projects .. " projects")
  pop_mono()
  ImGui.PopStyleColor(ctx)
  ImGui.Dummy(ctx, 0, 2)

  render_project_table(list)
end

-- ── Render: pinned panel ───────────────────────────────────────────────
local function render_pinned_panel()
  local pinned_src = {}
  for _, p in ipairs(projects) do
    if p.pinned then pinned_src[#pinned_src + 1] = p end
  end

  if #pinned_src == 0 then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.SetCursorPos(ctx, 10, 10)
    ImGui.TextWrapped(ctx, "No pinned projects. Click the ★ icon on any project row to pin it.")
    ImGui.PopStyleColor(ctx)
    return
  end

  render_project_table(filtered_projects(pinned_src))
end

-- ── Render: project sets panel ────────────────────────────────────────
local function render_sets_panel()
  ImGui.SetCursorPos(ctx, 10, 10)

  if #sets_order == 0 then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.TextWrapped(ctx, "No project sets yet.")
    ImGui.PopStyleColor(ctx)
    ImGui.Dummy(ctx, 0, 6)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
    ImGui.TextWrapped(ctx,
      "Select projects in the Recent or Pinned tab, then right-click \xe2\x86\x92 Create new project set.")
    ImGui.PopStyleColor(ctx)
    return
  end

  local row_h    = 36
  local tbl_flags = (rawget(ImGui, "TableFlags_BordersInnerV") or 0)
  if not ImGui.BeginTable(ctx, "##setstbl", 3, tbl_flags) then return end
  ImGui.TableSetupColumn(ctx, "##sname", ImGui.TableColumnFlags_WidthStretch)
  ImGui.TableSetupColumn(ctx, "##scnt",  ImGui.TableColumnFlags_WidthFixed, 64)
  ImGui.TableSetupColumn(ctx, "##sact",  ImGui.TableColumnFlags_WidthFixed, 56)

  local dl     = ImGui.GetWindowDrawList(ctx)
  local win_sx = select(1, ImGui.GetWindowPos(ctx))
  local win_sw = ImGui.GetWindowWidth(ctx)
  local to_delete = nil

  for _, id in ipairs(sets_order) do
    local s      = project_sets[id]
    if not s then goto continue_set_row end
    local is_sel = (ui.selected_set_id == id)

    ImGui.TableNextRow(ctx, 0, row_h)
    ImGui.TableSetColumnIndex(ctx, 0)
    local cx, cy = ImGui.GetCursorPos(ctx)
    local sx, sy = ImGui.GetCursorScreenPos(ctx)

    -- Color stripe
    local stripe_col = s.color or C.accent
    ImGui.DrawList_AddRectFilled(dl, sx, sy, sx + 3, sy + row_h, stripe_col)

    ImGui.SetCursorPos(ctx, cx + 4, cy)
    local clicked  = ImGui.Selectable(ctx, "##setrow_" .. id, is_sel, SEL_SPAN, 0, row_h)
    if clicked then
      ui.selected_set_id = id
      clear_selection()
    end
    local row_hovered = ImGui.IsItemHovered(ctx)
    if row_hovered and ImGui.IsMouseDoubleClicked(ctx, 0) then
      open_project_set(id)
    end

    ImGui.SameLine(ctx)
    ImGui.SetCursorPos(ctx, cx + 14, cy + math.max(2, math.floor((row_h - 14) * 0.3)))
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text)
    ImGui.Text(ctx, s.name)
    ImGui.PopStyleColor(ctx)

    ImGui.DrawList_AddLine(dl, win_sx, sy + row_h - 1, win_sx + win_sw, sy + row_h - 1, C.border, 1)

    ImGui.TableSetColumnIndex(ctx, 1)
    push_mono()
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.Text(ctx, tostring(#s.paths) .. " proj")
    ImGui.PopStyleColor(ctx)
    pop_mono()

    ImGui.TableSetColumnIndex(ctx, 2)
    if row_hovered or is_sel then
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 2, 0)
      push_btn(0x00000000, C.panel3, C.border)
      ImGui.SetCursorPosY(ctx, cy + math.max(2, math.floor((row_h - 16) * 0.5)))

      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      if ImGui.SmallButton(ctx, "\xe2\x96\xb6##ops_" .. id) then open_project_set(id) end
      ImGui.PopStyleColor(ctx)
      ImGui.SameLine(ctx)

      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.danger)
      if ImGui.SmallButton(ctx, "\xe2\x9c\x95##dls_" .. id) then to_delete = id end
      ImGui.PopStyleColor(ctx)

      pop_btn()
      ImGui.PopStyleVar(ctx)
    end
    ::continue_set_row::
  end

  ImGui.EndTable(ctx)

  if to_delete then
    for i, id in ipairs(sets_order) do
      if id == to_delete then table.remove(sets_order, i); break end
    end
    project_sets[to_delete] = nil
    if ui.selected_set_id == to_delete then ui.selected_set_id = nil end
    save_sets()
  end
end

-- ── Render: templates panel ────────────────────────────────────────────
local function render_templates_panel()
  ImGui.SetCursorPos(ctx, 10, 10)
  if #templates == 0 then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.TextWrapped(ctx, "No templates found in Reaper's ProjectTemplates folder.")
    ImGui.PopStyleColor(ctx)
    return
  end

  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 8)
  local card_w  = 210
  local card_h  = 100
  local avail_w, _ = ImGui.GetContentRegionAvail(ctx)
  local cols    = math.max(1, math.floor((avail_w + 8) / (card_w + 8)))
  local i = 0

  for _, t in ipairs(templates) do
    if i > 0 and i % cols ~= 0 then ImGui.SameLine(ctx) end

    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.panel2)
    local tcv = ImGui.BeginChild(ctx, "##tmpl_" .. t.name, card_w, card_h, CHILD_BORDER)
    if tcv then
      local tdl     = ImGui.GetWindowDrawList(ctx)
      local twx, twy = ImGui.GetWindowPos(ctx)

      -- 28×28 icon box (panel3 bg square)
      ImGui.DrawList_AddRectFilled(tdl, twx + 8, twy + 8, twx + 36, twy + 36, C.panel3)

      ImGui.SetCursorPos(ctx, 14, 14)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      ImGui.Text(ctx, "✦")
      ImGui.PopStyleColor(ctx)

      -- Name (to the right of icon box)
      ImGui.SetCursorPos(ctx, 44, 10)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text)
      ImGui.Text(ctx, t.name)
      ImGui.PopStyleColor(ctx)

      -- Filename (mono, below name)
      ImGui.SetCursorPos(ctx, 44, 27)
      push_mono()
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
      ImGui.Text(ctx, t.file)
      ImGui.PopStyleColor(ctx)
      pop_mono()

      -- "Use template" button pinned to card bottom
      ImGui.SetCursorPos(ctx, 8, card_h - 30)
      push_btn(C.accent2, C.accent, C.accent2)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xffffffff)
      if ImGui.Button(ctx, "Use template##t_" .. t.name, card_w - 16, 22) then
        open_project(t.path)
      end
      ImGui.PopStyleColor(ctx)
      pop_btn()

      ImGui.EndChild(ctx)
    end
    ImGui.PopStyleColor(ctx)

    i = i + 1
  end

  ImGui.PopStyleVar(ctx)
end

-- ── Render: folders panel ──────────────────────────────────────────────
local function render_folders_panel()
  ImGui.SetCursorPos(ctx, 10, 10)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 6, 6)

  local remove_idx = nil
  for fi, folder in ipairs(watched_folders) do
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.panel2)
    local fcv = ImGui.BeginChild(ctx, "##fld_" .. fi, 0, 30, CHILD_BORDER)
    if fcv then
      ImGui.SetCursorPos(ctx, 8, 7)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text2)
      ImGui.Text(ctx, folder.path)
      ImGui.PopStyleColor(ctx)
      ImGui.SameLine(ctx)
      -- Watch toggle
      local changed, new_watch = ImGui.Checkbox(ctx, "Watch##fw_" .. fi, folder.watch)
      if changed then
        folder.watch = new_watch
        save_watched_folders()
        build_project_list()
      end
      ImGui.SameLine(ctx)
      push_btn(0x00000000, C.panel3, C.border)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.danger)
      if ImGui.SmallButton(ctx, "✕##fr_" .. fi) then
        remove_idx = fi
      end
      ImGui.PopStyleColor(ctx)
      pop_btn()
      ImGui.EndChild(ctx)
    end
    ImGui.PopStyleColor(ctx)
  end

  if remove_idx then
    table.remove(watched_folders, remove_idx)
    save_watched_folders()
    build_project_list()
  end

  ImGui.Dummy(ctx, 0, 4)
  push_btn(C.panel2, C.panel3, C.border)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
  if ImGui.Button(ctx, "+ Add Folder…", 0, 0) then
    local ok, user_input = reaper.GetUserInputs("Add Watched Folder", 1, "Folder path:", "")
    if ok and user_input ~= "" then
      watched_folders[#watched_folders + 1] = { path = user_input, watch = true }
      save_watched_folders()
      build_project_list()
    end
  end
  ImGui.PopStyleColor(ctx)
  pop_btn()

  ImGui.PopStyleVar(ctx)
end

-- ── Render: settings panel ─────────────────────────────────────────────
local function render_settings_panel()
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 6, 4)
  ImGui.SetCursorPos(ctx, 14, 12)

  -- Section header
  local function section(label)
    local lx, ly = ImGui.GetCursorPos(ctx)
    ImGui.SetCursorPos(ctx, lx, ly + 2)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.Text(ctx, label)
    ImGui.PopStyleColor(ctx)
    local _, ny = ImGui.GetCursorPos(ctx)
    ImGui.SetCursorPos(ctx, lx, ny + 2)
  end

  -- Setting row: panel bg, name + description, pill toggle on right
  local function setting_tog(name, desc, val, key)
    ImGui.SetCursorPosX(ctx, 14)
    local lx, ly = ImGui.GetCursorPos(ctx)
    local sx, sy = ImGui.GetCursorScreenPos(ctx)
    local rw_avail, _ = ImGui.GetContentRegionAvail(ctx)
    local rw   = rw_avail - 4
    local row_h = desc ~= "" and 46 or 32

    ImGui.DrawList_AddRectFilled(dl, sx, sy, sx + rw, sy + row_h, C.panel)
    ImGui.DrawList_AddLine(dl, sx, sy + row_h, sx + rw, sy + row_h, C.border, 1)

    ImGui.SetCursorPos(ctx, lx + 10, ly + 8)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text)
    ImGui.Text(ctx, name)
    ImGui.PopStyleColor(ctx)

    if desc ~= "" then
      ImGui.SetCursorPos(ctx, lx + 10, ly + 26)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
      ImGui.Text(ctx, desc)
      ImGui.PopStyleColor(ctx)
    end

    -- Pill toggle (32×18)
    local tw, th = 32, 18
    local tog_lx = lx + rw - tw - 10
    local tog_ly = ly + math.floor((row_h - th) * 0.5)
    ImGui.SetCursorPos(ctx, tog_lx, tog_ly)
    local tsx, tsy = ImGui.GetCursorScreenPos(ctx)
    ImGui.InvisibleButton(ctx, "##tog_" .. key, tw, th)
    local toggled = ImGui.IsItemClicked(ctx)

    local bg_col = val and C.accent or C.panel3
    ImGui.DrawList_AddRectFilled(dl, tsx, tsy, tsx + tw, tsy + th, bg_col, th * 0.5)
    local knob_x = val and (tsx + tw - th * 0.5 - 2) or (tsx + th * 0.5 + 2)
    ImGui.DrawList_AddCircleFilled(dl, knob_x, tsy + th * 0.5, th * 0.5 - 2, 0xffffffff)

    ImGui.SetCursorPos(ctx, lx, ly + row_h + 4)

    if toggled then
      settings[key] = not val
      save_settings()
    end
  end

  section("BEHAVIOR")
  setting_tog("Open at startup",
    "Add this script to Options › Startup Actions in Reaper",
    settings.open_at_startup, "open_at_startup")
  setting_tog("Close on project load",
    "Automatically close ReaStart after opening a project",
    settings.close_on_open, "close_on_open")

  ImGui.Dummy(ctx, 0, 10)
  section("DISPLAY")

  -- Density row (combo instead of toggle)
  do
    ImGui.SetCursorPosX(ctx, 14)
    local lx, ly = ImGui.GetCursorPos(ctx)
    local sx, sy = ImGui.GetCursorScreenPos(ctx)
    local rw_avail, _ = ImGui.GetContentRegionAvail(ctx)
    local rw, row_h = rw_avail - 4, 46
    ImGui.DrawList_AddRectFilled(dl, sx, sy, sx + rw, sy + row_h, C.panel)
    ImGui.DrawList_AddLine(dl, sx, sy + row_h, sx + rw, sy + row_h, C.border, 1)

    ImGui.SetCursorPos(ctx, lx + 10, ly + 8)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text)
    ImGui.Text(ctx, "Row density")
    ImGui.PopStyleColor(ctx)

    ImGui.SetCursorPos(ctx, lx + 10, ly + 26)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.Text(ctx, "Compact, comfort, or detail view")
    ImGui.PopStyleColor(ctx)

    local density_opts = { "compact", "comfort", "detail" }
    local cur_idx = 0
    for i, d in ipairs(density_opts) do if d == settings.density then cur_idx = i - 1 end end
    local combo_w = 90
    ImGui.SetCursorPos(ctx, lx + rw - combo_w - 10, ly + math.floor((row_h - 22) * 0.5))
    ImGui.SetNextItemWidth(ctx, combo_w)
    local combo_chg, new_idx = ImGui.Combo(ctx, "##density", cur_idx, "compact\0comfort\0detail\0")
    if combo_chg then
      settings.density = density_opts[new_idx + 1]
      save_settings()
    end
    ImGui.SetCursorPos(ctx, lx, ly + row_h + 4)
  end

  setting_tog("Show file path",  "Display full path below project name", settings.show_path, "show_path")
  setting_tog("Show tag badges", "Show tag chips in detail density mode", settings.show_tags, "show_tags")

  ImGui.Dummy(ctx, 0, 10)
  section("ACCENT COLOR")

  local accents = {
    { "#9b8fc4", C.accent  },
    { "#c78a4a", C.orange  },
    { "#5fb09e", C.teal    },
    { "#6b8db8", C.info    },
    { "#b079a3", C.pink    },
    { "#c89a4a", C.warning },
  }
  ImGui.SetCursorPosX(ctx, 14)
  local _, ly_ac = ImGui.GetCursorPos(ctx)
  ImGui.SetCursorPos(ctx, 14, ly_ac + 4)
  for _, opt in ipairs(accents) do
    local ax, ay = ImGui.GetCursorScreenPos(ctx)
    local r = 10
    ImGui.DrawList_AddCircleFilled(dl, ax + r, ay + r, r, opt[2])
    if settings.accent == opt[1] then
      ImGui.DrawList_AddCircle(dl, ax + r, ay + r, r + 2, C.text2, 20, 1.5)
    end
    ImGui.InvisibleButton(ctx, "##ac_" .. opt[1], r * 2, r * 2)
    if ImGui.IsItemClicked(ctx) then
      settings.accent = opt[1]
      save_settings()
    end
    ImGui.SameLine(ctx, 0, 6)
  end

  ImGui.PopStyleVar(ctx)
end

-- ── Render: detail pane ────────────────────────────────────────────────
local function get_selected()
  if not ui.selected_path then return nil end
  for _, p in ipairs(projects) do
    if p.path == ui.selected_path then return p end
  end
  return nil
end

local function render_mini_wave(seed)
  local dl = ImGui.GetWindowDrawList(ctx)
  local ox, oy = ImGui.GetCursorScreenPos(ctx)
  local w  = ImGui.GetContentRegionAvail(ctx)
  local bw, gap = 3, 1
  local nb = math.floor(w / (bw + gap))
  local rng = function(i)
    local x = math.sin(seed * 9001 + i * 17.3) * 1000
    return x - math.floor(x)
  end
  for i = 0, nb - 1 do
    local v  = (math.sin(i / 4) * 0.5 + 0.5) * (0.4 + rng(i) * 0.6)
    local bh = math.max(3, v * 22)
    local bx = ox + i * (bw + gap)
    local by = oy + 11 - bh / 2
    local al = math.floor((0.3 + v * 0.65) * 255)
    ImGui.DrawList_AddRectFilled(dl, bx, by, bx + bw, by + bh,
      (C.accent & 0xffffff00) | al)
  end
  ImGui.Dummy(ctx, w, 22)
end

local function render_set_detail_pane()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing,    6,  4)

  local s = ui.selected_set_id and project_sets[ui.selected_set_id]
  if not s then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.Text(ctx, "SETS")
    ImGui.PopStyleColor(ctx)
    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 4)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
    ImGui.TextWrapped(ctx, "Select a set to see its projects.")
    ImGui.PopStyleColor(ctx)
    ImGui.PopStyleVar(ctx, 1)
    return
  end

  -- Set name header
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text)
  ImGui.TextWrapped(ctx, s.name)
  ImGui.PopStyleColor(ctx)
  push_mono()
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
  ImGui.Text(ctx, tostring(#s.paths) .. " project" .. (#s.paths ~= 1 and "s" or ""))
  ImGui.PopStyleColor(ctx)
  pop_mono()

  ImGui.Dummy(ctx, 0, 6)

  -- Open Set button (full width)
  if #s.paths > 0 then
    local aw = select(1, ImGui.GetContentRegionAvail(ctx))
    push_btn(C.accent2, C.accent, C.accent2)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xffffffff)
    if ImGui.Button(ctx, "\xe2\x96\xb6  Open Set##sd_open", aw, 24) then
      open_project_set(s.id)
    end
    ImGui.PopStyleColor(ctx)
    pop_btn()
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
    ImGui.TextWrapped(ctx, "Set is empty.")
    ImGui.PopStyleColor(ctx)
  end

  ImGui.Dummy(ctx, 0, 8)

  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
  ImGui.Text(ctx, "PROJECTS")
  ImGui.PopStyleColor(ctx)
  ImGui.Separator(ctx)
  ImGui.Dummy(ctx, 0, 2)

  local avail_h = select(2, ImGui.GetContentRegionAvail(ctx)) - 34
  if ImGui.BeginChild(ctx, "##sdprojlist", 0, math.max(avail_h, 0), 0) then
    local to_remove = nil
    for i, path in ipairs(s.paths) do
      local exists = reaper.file_exists(path)
      local name   = path_name(path)
      local avail  = select(1, ImGui.GetContentRegionAvail(ctx))

      ImGui.PushStyleColor(ctx, ImGui.Col_Text, exists and C.text or C.text4)
      ImGui.Text(ctx, name)
      ImGui.PopStyleColor(ctx)
      if not exists then
        ImGui.SameLine(ctx, 0, 4)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.danger)
        ImGui.Text(ctx, "\xe2\x9a\xa0")
        ImGui.PopStyleColor(ctx)
      end

      ImGui.SameLine(ctx)
      ImGui.SetCursorPosX(ctx, avail - 18)
      push_btn(0x00000000, C.panel3, C.border)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
      if ImGui.SmallButton(ctx, "\xc3\x97##rmfset_" .. i) then
        to_remove = i
      end
      ImGui.PopStyleColor(ctx)
      pop_btn()
    end
    if to_remove then
      table.remove(s.paths, to_remove)
      save_sets()
    end
    ImGui.EndChild(ctx)
  end

  ImGui.Dummy(ctx, 0, 4)
  local aw = select(1, ImGui.GetContentRegionAvail(ctx))
  push_btn(0x00000000, C.panel3, C.border)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.danger)
  if ImGui.Button(ctx, "Delete Set##sd_delete", aw, 26) then
    local del_id = s.id
    for i, id in ipairs(sets_order) do
      if id == del_id then table.remove(sets_order, i); break end
    end
    project_sets[del_id] = nil
    ui.selected_set_id   = nil
    save_sets()
  end
  ImGui.PopStyleColor(ctx)
  pop_btn()

  ImGui.PopStyleVar(ctx, 1)
end

local function render_detail_pane()
  -- Sets tab has its own detail pane
  if ui.tab == "sets" then render_set_detail_pane(); return end

  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing,    6,  4)

  local proj = get_selected()
  if not proj then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.Text(ctx, "PREVIEW")
    ImGui.PopStyleColor(ctx)
    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 4)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
    ImGui.TextWrapped(ctx, "Select a project to see details, notes, and quick actions.")
    ImGui.PopStyleColor(ctx)
    ImGui.PopStyleVar(ctx, 1)
    return
  end

  -- Name + path
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text)
  ImGui.TextWrapped(ctx, proj.name)
  ImGui.PopStyleColor(ctx)
  push_mono()
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
  ImGui.TextWrapped(ctx, proj.path)
  ImGui.PopStyleColor(ctx)
  pop_mono()

  ImGui.Dummy(ctx, 0, 4)

  -- Action buttons
  local aw = ImGui.GetContentRegionAvail(ctx)
  push_btn(C.accent2, C.accent, C.accent2)
  if ImGui.Button(ctx, "▶  Open##d_open", aw - 60, 22) then
    open_project(proj.path)
  end
  pop_btn()
  ImGui.SameLine(ctx)
  push_btn(C.panel2, C.panel3, C.border)
  if ImGui.Button(ctx, "⇱##d_rev", 24, 22) then reveal_path(proj.path) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, (proj.pinned and "★" or "☆") .. "##d_pin", 24, 22) then
    if pinned[proj.path] then
      pinned[proj.path] = nil; proj.pinned = false
    else
      pinned[proj.path] = true; proj.pinned = true
    end
    save_pinned()
  end
  pop_btn()

  ImGui.Dummy(ctx, 0, 6)

  -- Mini waveform
  local seed = 0
  for c in proj.name:gmatch(".") do seed = seed + string.byte(c) end
  render_mini_wave(seed)

  ImGui.Dummy(ctx, 0, 6)

  -- Metadata grid
  local meta = parse_rpp(proj.path) or {}
  if ImGui.BeginTable(ctx, "##meta", 2, 0) then
    ImGui.TableSetupColumn(ctx, "##mk", ImGui.TableColumnFlags_WidthFixed, 96)
    ImGui.TableSetupColumn(ctx, "##mv", ImGui.TableColumnFlags_WidthStretch)
    local rows = {
      { "Last opened", proj.last_str },
      { "File size",   proj.size_str },
      { "Tracks",      meta.tracks and tostring(meta.tracks) or "—" },
      { "BPM",         meta.bpm and meta.bpm > 0 and string.format("%.0f", meta.bpm) or "—" },
      { "Sample rate", meta.sr and string.format("%.1f kHz", meta.sr / 1000) or "—" },
      { "Pinned",      proj.pinned and "yes" or "no" },
    }
    for _, row in ipairs(rows) do
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
      ImGui.Text(ctx, row[1])
      ImGui.PopStyleColor(ctx)
      ImGui.TableSetColumnIndex(ctx, 1)
      push_mono()
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text)
      ImGui.Text(ctx, row[2])
      ImGui.PopStyleColor(ctx)
      pop_mono()
    end
    ImGui.EndTable(ctx)
  end

  ImGui.Dummy(ctx, 0, 4)

  -- Tags
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
  ImGui.Text(ctx, "TAGS")
  ImGui.PopStyleColor(ctx)
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetWindowWidth(ctx) - 94)
  push_btn(0x00000000, C.panel3, C.border)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
  if ImGui.SmallButton(ctx, "+ Add / Edit##open_tp") then
    tag_popup.open       = true
    tag_popup.skip_close = true
    tag_popup.proj_key   = proj.key
    tag_popup.proj_path  = proj.path
    tag_popup.creating   = false
  end
  ImGui.PopStyleColor(ctx)
  pop_btn()
  ImGui.Separator(ctx)

  local ptags = project_tags[proj.key] or {}
  if #ptags == 0 then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
    ImGui.Text(ctx, "No tags")
    ImGui.PopStyleColor(ctx)
  else
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 3, 3)
    for _, tag in ipairs(ptags) do
      local tc = get_tag_color(tag)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, tc)
      ImGui.Text(ctx, "●")
      ImGui.PopStyleColor(ctx)
      ImGui.SameLine(ctx, 0, 3)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text2)
      ImGui.Text(ctx, tag)
      ImGui.PopStyleColor(ctx)
      ImGui.SameLine(ctx, 0, 2)
      push_btn(0x00000000, C.panel3, 0x00000000)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
      if ImGui.SmallButton(ctx, "x##rtag_" .. tag) then
        remove_project_tag(proj.key, tag)
        for _, p in ipairs(projects) do
          if p.key == proj.key then p.tags = project_tags[p.key] or {} end
        end
        save_project_data(proj.path)
        rebuild_all_tags()
      end
      ImGui.PopStyleColor(ctx)
      pop_btn()
    end
    ImGui.PopStyleVar(ctx)
  end

  ImGui.Dummy(ctx, 0, 4)

  -- Notes
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
  ImGui.Text(ctx, "NOTES")
  ImGui.PopStyleColor(ctx)
  ImGui.Separator(ctx)

  local nbuf_key = proj.path
  if not notes_buf[nbuf_key] then
    notes_buf[nbuf_key] = project_notes[proj.key] or ""
  end
  local _, note_h_avail = ImGui.GetContentRegionAvail(ctx)
  local note_h = math.max(48, note_h_avail - 6)
  local note_chg, new_note = ImGui.InputTextMultiline(ctx, "##notes_" .. proj.key,
    notes_buf[nbuf_key], 4096, -1, note_h)
  if note_chg then
    notes_buf[nbuf_key] = new_note
    project_notes[proj.key] = new_note
    save_project_data(proj.path)
  end

  ImGui.PopStyleVar(ctx, 1)
end

-- ── Render: tag popup ────────────────────────────────────────────────
local function render_tag_popup()
  if not tag_popup.open then return end

  local pw     = 320
  local ph     = tag_popup.creating and 640 or 320
  local cx     = ui.win_x + math.floor((ui.win_w - pw) / 2)
  local cy     = ui.win_y + math.floor((ui.win_h - ph) / 2)
  ImGui.SetNextWindowPos(ctx, cx, cy, ImGui.Cond_Always)
  ImGui.SetNextWindowSize(ctx, pw, ph, ImGui.Cond_Always)

  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, C.panel2)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border,   C.border2)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding,  10, 10)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding,  4)

  local pop_flags = ImGui.WindowFlags_NoCollapse
                  | ImGui.WindowFlags_NoResize
                  | ImGui.WindowFlags_NoTitleBar
                  | ImGui.WindowFlags_NoScrollbar
  local visible = ImGui.Begin(ctx, "##tagpopup", true, pop_flags)
  if visible then
    -- Capture actual rendered bounds now (SetNextWindowPos may have been clamped)
    local wpx, wpy = ImGui.GetWindowPos(ctx)
    local wpw      = ImGui.GetWindowWidth(ctx)
    local wph      = ImGui.GetWindowHeight(ctx)

    -- ── Header ──────────────────────────────────────────────────────
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.Text(ctx, "TAGS")
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    ImGui.SetCursorPosX(ctx, ImGui.GetWindowWidth(ctx) - 22)
    push_btn(0x00000000, C.panel3, C.border)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    if ImGui.SmallButton(ctx, "x##tp_close") then
      tag_popup.open = false; tag_popup.creating = false
    end
    ImGui.PopStyleColor(ctx)
    pop_btn()
    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 2)

    -- ── Scrollable tag list ──────────────────────────────────────────
    local list_h = tag_popup.creating and 148 or (ph - 96)
    if ImGui.BeginChild(ctx, "##tplist", 0, list_h, 0) then
      local sorted = {}
      for name in pairs(tag_registry) do sorted[#sorted+1] = name end
      table.sort(sorted)

      if #sorted == 0 then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
        ImGui.Text(ctx, "No tags yet — create one below.")
        ImGui.PopStyleColor(ctx)
      else
        local dl2 = ImGui.GetWindowDrawList(ctx)
        local tbl_f = rawget(ImGui, "TableFlags_NoPadOuterX") or 0
        local tag_to_delete = nil
        if ImGui.BeginTable(ctx, "##tptbl", 1, tbl_f) then
          ImGui.TableSetupColumn(ctx, "##tptc", ImGui.TableColumnFlags_WidthStretch)
          for _, tag_name in ipairs(sorted) do
            ImGui.TableNextRow(ctx, 0, 26)
            ImGui.TableSetColumnIndex(ctx, 0)
            local lx, ly    = ImGui.GetCursorPos(ctx)
            local avail_w   = select(1, ImGui.GetContentRegionAvail(ctx))
            local row_right = lx + avail_w
            local is_on     = has_tag(tag_popup.proj_key, tag_name)
            local tag_col   = get_tag_color(tag_name)

            ImGui.PushStyleColor(ctx, ImGui.Col_Header,        is_on and C.sel or 0x00000000)
            ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, C.panel3)
            local clicked = ImGui.Selectable(ctx, "##tprow_"..tag_name, is_on, SEL_SPAN, 0, 26)
            ImGui.PopStyleColor(ctx, 2)

            if clicked then
              toggle_project_tag(tag_popup.proj_key, tag_name)
              for _, p in ipairs(projects) do
                if p.key == tag_popup.proj_key then
                  p.tags = project_tags[p.key] or {}
                end
              end
              save_project_data(tag_popup.proj_path)
              rebuild_all_tags()
            end

            -- Overlay: dot + name + checkmark + delete button
            ImGui.SameLine(ctx)
            ImGui.SetCursorPos(ctx, lx + 8, ly + 6)
            local dx, dy = ImGui.GetCursorScreenPos(ctx)
            ImGui.DrawList_AddCircleFilled(dl2, dx + 4, dy + 5, 5, tag_col)
            ImGui.SetCursorPos(ctx, lx + 24, ly + 6)
            ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text)
            ImGui.Text(ctx, tag_name)
            ImGui.PopStyleColor(ctx)
            if is_on then
              ImGui.SetCursorPos(ctx, row_right - 42, ly + 6)
              ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
              ImGui.Text(ctx, "✓")
              ImGui.PopStyleColor(ctx)
            end
            -- Delete button
            ImGui.SetCursorPos(ctx, row_right - 24, ly + 4)
            push_btn(0x00000000, 0x00000000, 0x00000000)
            ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
            if ImGui.SmallButton(ctx, "×##tpdel_"..tag_name) then
              tag_to_delete = tag_name
              tag_popup.skip_close = true
            end
            ImGui.PopStyleColor(ctx)
            pop_btn()
          end
          ImGui.EndTable(ctx)
        end

        -- Process deletion outside the loop so we don't mutate while iterating
        if tag_to_delete then
          tag_registry[tag_to_delete] = nil
          save_tag_registry()
          -- Strip the deleted tag from every project that carries it and persist
          for key, tags in pairs(project_tags) do
            for i = #tags, 1, -1 do
              if tags[i] == tag_to_delete then table.remove(tags, i) end
            end
            es_set("tags/" .. key, table.concat(tags, ","))
          end
          local ti = {}
          for key in pairs(project_tags) do ti[#ti+1] = key end
          es_set("tags_index", table.concat(ti, "\n"))
          -- Sync in-memory project objects
          for _, p in ipairs(projects) do p.tags = project_tags[p.key] or {} end
          rebuild_all_tags()
        end
      end
    end
    ImGui.EndChild(ctx)

    ImGui.Dummy(ctx, 0, 4)
    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 6)

    -- ── Create new tag form ──────────────────────────────────────────
    if not tag_popup.creating then
      push_btn(0x00000000, C.panel3, C.border)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      if ImGui.Button(ctx, "+ Create new tag…##tp_new", -1, 24) then
        tag_popup.creating    = true
        tag_popup.skip_close  = true   -- suppress close-check on this transition frame
        tag_popup.focus_input = true
        tag_popup.new_name    = ""
        tag_popup.new_color   = C.accent
      end
      ImGui.PopStyleColor(ctx)
      pop_btn()
    else
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
      ImGui.Text(ctx, "NEW TAG")
      ImGui.PopStyleColor(ctx)
      ImGui.Dummy(ctx, 0, 4)

      -- Name
      if tag_popup.focus_input then
        ImGui.SetKeyboardFocusHere(ctx)
        tag_popup.focus_input = false
      end
      ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,        C.bg)
      ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, C.panel)
      ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive,  C.panel)
      ImGui.SetNextItemWidth(ctx, -1)
      local nc, nn = ImGui.InputText(ctx, "##tp_name", tag_popup.new_name)
      if nc then tag_popup.new_name = nn end
      ImGui.PopStyleColor(ctx, 3)

      ImGui.Dummy(ctx, 0, 6)

      -- Color picker
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
      ImGui.Text(ctx, "Color")
      ImGui.PopStyleColor(ctx)
      local pick_flags = rawget(ImGui, "ColorEditFlags_PickerHueBar") or 0
      local col_chg, new_col = ImGui.ColorPicker4(ctx, "##tp_color", tag_popup.new_color, pick_flags)
      if col_chg then
        tag_popup.new_color = (new_col & 0xFFFFFF00) | 0xFF
      end

      ImGui.Dummy(ctx, 0, 8)

      -- Create / Cancel
      local can_save = tag_popup.new_name ~= "" and not tag_registry[tag_popup.new_name]
      push_btn(can_save and C.accent2 or C.panel3,
               can_save and C.accent  or C.panel3, C.border)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, can_save and 0xffffffff or C.text4)
      local created = ImGui.Button(ctx, "Create##tp_create", -1, 26)
      ImGui.PopStyleColor(ctx)
      pop_btn()
      if created and can_save then
        tag_registry[tag_popup.new_name] = tag_popup.new_color
        save_tag_registry()
        tag_popup.creating   = false
        tag_popup.skip_close = true
        tag_popup.new_name   = ""
      end
      ImGui.Dummy(ctx, 0, 2)
      push_btn(0x00000000, C.panel3, C.border)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
      if ImGui.Button(ctx, "Cancel##tp_cancel", -1, 24) then
        tag_popup.creating   = false
        tag_popup.skip_close = true
      end
      ImGui.PopStyleColor(ctx)
      pop_btn()
    end

    -- Click outside to close.
    -- Use IsMouseReleased (not IsMouseClicked) so the check fires on the same
    -- frame as Button activation — any internal button sets skip_close=true
    -- before we reach here, guaranteeing it wins the race.
    -- wpx/wpy/wpw/wph are the actual rendered window bounds captured above.
    if tag_popup.skip_close then
      tag_popup.skip_close = false
    elseif ImGui.IsMouseReleased(ctx, 0) then
      local mx, my = ImGui.GetMousePos(ctx)
      if mx < wpx or mx > wpx + wpw or my < wpy or my > wpy + wph then
        tag_popup.open = false; tag_popup.creating = false
      end
    end
    -- Escape closes creation form (or popup if form not open)
    if KEY_ESCAPE and ImGui.IsKeyPressed(ctx, KEY_ESCAPE) then
      if tag_popup.creating then tag_popup.creating = false
      else tag_popup.open = false end
    end
  end
  ImGui.End(ctx)
  ImGui.PopStyleVar(ctx, 2)
  ImGui.PopStyleColor(ctx, 2)
end

-- ── Render: set creation popup ───────────────────────────────────────
local function render_set_popup()
  if not set_popup.open then return end

  local pw, ph = 320, 420
  local cx = ui.win_x + math.floor((ui.win_w - pw) / 2)
  local cy = ui.win_y + math.floor((ui.win_h - ph) / 2)
  ImGui.SetNextWindowPos(ctx, cx, cy, ImGui.Cond_Always)
  ImGui.SetNextWindowSize(ctx, pw, ph, ImGui.Cond_Always)

  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, C.panel2)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border,   C.border2)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding,  10, 10)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding,  4)

  local pop_flags = ImGui.WindowFlags_NoCollapse
                  | ImGui.WindowFlags_NoResize
                  | ImGui.WindowFlags_NoTitleBar
                  | ImGui.WindowFlags_NoScrollbar
  local visible = ImGui.Begin(ctx, "##setpopup", true, pop_flags)
  if visible then
    local wpx, wpy = ImGui.GetWindowPos(ctx)
    local wpw      = ImGui.GetWindowWidth(ctx)
    local wph      = ImGui.GetWindowHeight(ctx)

    -- Header
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.Text(ctx, "NEW PROJECT SET")
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    ImGui.SetCursorPosX(ctx, wpw - 22)
    push_btn(0x00000000, C.panel3, C.border)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    if ImGui.SmallButton(ctx, "x##sp_close") then
      set_popup.open = false
      set_popup.skip_close = true
    end
    ImGui.PopStyleColor(ctx)
    pop_btn()

    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 4)

    -- Name input
    if set_popup.focus_input then
      ImGui.SetKeyboardFocusHere(ctx)
      set_popup.focus_input = false
    end
    ImGui.SetNextItemWidth(ctx, -1)
    local nc, nn = ImGui.InputText(ctx, "##sp_name", set_popup.name_buf)
    if nc then set_popup.name_buf = nn end

    ImGui.Dummy(ctx, 0, 6)

    -- Color picker
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text3)
    ImGui.Text(ctx, "Color")
    ImGui.PopStyleColor(ctx)
    local pick_flags = rawget(ImGui, "ColorEditFlags_PickerHueBar") or 0
    local col_chg, new_col = ImGui.ColorPicker4(ctx, "##sp_color", set_popup.new_color, pick_flags)
    if col_chg then
      set_popup.new_color = (new_col & 0xFFFFFF00) | 0xFF
    end

    ImGui.Dummy(ctx, 0, 6)

    -- Confirm button
    local n_sel     = selection_count()
    local can_create = set_popup.name_buf ~= "" and n_sel > 0
    local btn_label = "Create (" .. n_sel .. " project" .. (n_sel ~= 1 and "s" or "") .. ")##sp_ok"
    if can_create then
      push_btn(C.accent2, C.accent, C.accent2)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xffffffff)
    else
      push_btn(C.panel3, C.panel3, C.panel3)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
    end
    local do_create = ImGui.Button(ctx, btn_label, -1, 26) and can_create
    ImGui.PopStyleColor(ctx)
    pop_btn()

    -- Enter key also triggers creation
    if KEY_ENTER and ImGui.IsKeyPressed(ctx, KEY_ENTER) and can_create then
      do_create = true
    end

    if do_create then
      local id = new_set_id()
      project_sets[id] = { id = id, name = set_popup.name_buf, paths = selection_list(), color = set_popup.new_color }
      sets_order[#sets_order + 1] = id
      save_sets()
      ui.selected_set_id = id
      ui.tab             = "sets"
      set_popup.open     = false
      set_popup.skip_close = true
      ui.flash_msg = "Created set \"" .. project_sets[id].name .. "\""
      ui.flash_t   = os.time()
    end

    -- Click-outside closes (same skip_close race-condition guard as tag_popup)
    if set_popup.skip_close then
      set_popup.skip_close = false
    elseif ImGui.IsMouseReleased(ctx, 0) then
      local mx, my = ImGui.GetMousePos(ctx)
      if mx < wpx or mx > wpx + wpw or my < wpy or my > wpy + wph then
        set_popup.open = false
      end
    end
    if KEY_ESCAPE and ImGui.IsKeyPressed(ctx, KEY_ESCAPE) then
      set_popup.open = false
    end
  end
  ImGui.End(ctx)
  ImGui.PopStyleVar(ctx, 2)
  ImGui.PopStyleColor(ctx, 2)
end

-- ── Render: command palette ────────────────────────────────────────────
local function render_palette()
  local pw, ph = 500, 300
  local cx = ui.win_x + math.floor((ui.win_w - pw) / 2)
  local cy = ui.win_y + math.floor((ui.win_h - ph) / 2)
  ImGui.SetNextWindowPos(ctx, cx, cy, ImGui.Cond_Always)
  ImGui.SetNextWindowSize(ctx, pw, ph, ImGui.Cond_Always)

  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, C.panel2)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border,   C.accent2)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 10, 10)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, 4)

  local pal_flags = ImGui.WindowFlags_NoCollapse
                  | ImGui.WindowFlags_NoResize
                  | ImGui.WindowFlags_NoTitleBar
  local visible, pal_open = ImGui.Begin(ctx, "##palette", true, pal_flags)
  if visible then
    -- Focus on first open
    if ui.palette_focus then
      ImGui.SetKeyboardFocusHere(ctx)
      ui.palette_focus = false
    end
    ImGui.SetNextItemWidth(ctx, -1)
    local qc, new_q = ImGui.InputText(ctx, "##palq", ui.palette_q, 256)
    if qc then ui.palette_q = new_q; ui.palette_sel = 1 end

    ImGui.Dummy(ctx, 0, 2)
    ImGui.Separator(ctx)
    ImGui.Dummy(ctx, 0, 2)

    -- Filter
    local matches = {}
    local ql = ui.palette_q:lower()
    for _, p in ipairs(projects) do
      if ql == "" or p.name:lower():find(ql, 1, true) or p.path:lower():find(ql, 1, true) then
        matches[#matches + 1] = p
        if #matches >= 8 then break end
      end
    end

    -- Keyboard nav
    if KEY_UP   and ImGui.IsKeyPressed(ctx, KEY_UP)   then
      ui.palette_sel = math.max(1, ui.palette_sel - 1)
    end
    if KEY_DOWN and ImGui.IsKeyPressed(ctx, KEY_DOWN) then
      ui.palette_sel = math.min(#matches, ui.palette_sel + 1)
    end
    if KEY_ENTER and ImGui.IsKeyPressed(ctx, KEY_ENTER) then
      if matches[ui.palette_sel] then
        open_project(matches[ui.palette_sel].path)
        ui.palette_open = false
      end
    end
    if KEY_ESCAPE and ImGui.IsKeyPressed(ctx, KEY_ESCAPE) then
      ui.palette_open = false
    end

    -- Results
    for i, p in ipairs(matches) do
      local is_sel = (i == ui.palette_sel)
      ImGui.PushStyleColor(ctx, ImGui.Col_Header,        C.sel)
      ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, C.sel)
      if ImGui.Selectable(ctx, "##pm_" .. p.path, is_sel, 0, 0, 24) then
        ui.palette_sel = i
        if ImGui.IsMouseDoubleClicked(ctx, 0) then
          open_project(p.path)
          ui.palette_open = false
        end
      end
      ImGui.PopStyleColor(ctx, 2)
      ImGui.SameLine(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text)
      ImGui.Text(ctx, p.name)
      ImGui.PopStyleColor(ctx)
      ImGui.SameLine(ctx)
      push_mono()
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
      ImGui.Text(ctx, p.last_str)
      ImGui.PopStyleColor(ctx)
      pop_mono()
    end

    -- Click outside → close
    if ImGui.IsMouseClicked(ctx, 0) and not ImGui.IsWindowHovered(ctx) then
      ui.palette_open = false
    end
  end
  ImGui.End(ctx)
  ImGui.PopStyleVar(ctx, 2)
  ImGui.PopStyleColor(ctx, 2)
end

-- ── Render: custom tab bar ────────────────────────────────────────────
local function render_tabbar()
  local n_pinned = 0
  for _, p in ipairs(projects) do if p.pinned then n_pinned = n_pinned + 1 end end

  local tab_defs = {
    { id = "recent",    label = "Recent",    count = #projects        },
    { id = "pinned",    label = "Pinned",    count = n_pinned         },
    { id = "sets",      label = "Sets",      count = #sets_order      },
    { id = "templates", label = "Templates", count = #templates       },
    { id = "folders",   label = "Folders",   count = #watched_folders },
    { id = "settings",  label = "Settings",  count = nil              },
  }

  local bar_h = 34
  local pad_x = 14   -- horizontal padding each side of label
  local lh    = ImGui.GetTextLineHeight(ctx)

  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.bg)
  local tbv = ImGui.BeginChild(ctx, "##tabbar_custom", 0, bar_h, 0)
  if tbv then
    local dl     = ImGui.GetWindowDrawList(ctx)
    local bx, by = ImGui.GetWindowPos(ctx)
    local bw     = ImGui.GetWindowWidth(ctx)

    -- Bottom hairline separator
    ImGui.DrawList_AddLine(dl, bx, by + bar_h - 1, bx + bw, by + bar_h - 1, C.border, 1)

    local cur_x = 8
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 0, 0)

    for _, tab in ipairs(tab_defs) do
      local is_active = (ui.tab == tab.id)
      local cnt_str   = tab.count and tostring(tab.count) or nil

      local lw  = ImGui.CalcTextSize(ctx, tab.label)
      local cw  = cnt_str and ImGui.CalcTextSize(ctx, cnt_str) or 0
      local gap = cnt_str and 6 or 0
      local btn_w = math.ceil(lw + cw + gap + pad_x * 2)

      -- Invisible hit area
      ImGui.SetCursorPos(ctx, cur_x, 0)
      ImGui.InvisibleButton(ctx, "##ctab_" .. tab.id, btn_w, bar_h)
      local hovered = ImGui.IsItemHovered(ctx)
      if ImGui.IsItemClicked(ctx) then ui.tab = tab.id end

      -- Hover fill
      if hovered and not is_active then
        ImGui.DrawList_AddRectFilled(dl, bx + cur_x, by, bx + cur_x + btn_w, by + bar_h - 1, C.hover)
      end

      -- Text colors
      local col_label = is_active and C.text or (hovered and C.text2 or C.text3)
      local col_count = is_active and C.text3 or C.text4
      local text_y    = by + math.floor((bar_h - lh) * 0.5) - 1

      -- Label
      ImGui.DrawList_AddText(dl, bx + cur_x + pad_x, text_y, col_label, tab.label)
      -- Count badge
      if cnt_str then
        ImGui.DrawList_AddText(dl, bx + cur_x + pad_x + lw + gap, text_y, col_count, cnt_str)
      end

      -- Active underline (2px, inset 4px each side)
      if is_active then
        ImGui.DrawList_AddRectFilled(dl,
          bx + cur_x + 4, by + bar_h - 2,
          bx + cur_x + btn_w - 4, by + bar_h,
          C.accent)
      end

      ImGui.SameLine(ctx, 0, 0)
      cur_x = cur_x + btn_w
    end

    ImGui.PopStyleVar(ctx)
    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleColor(ctx)
end

-- ── Render: status bar ────────────────────────────────────────────────
local function render_statusbar()
  local pad_x, pad_y = 10, 4
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.bg)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
  if ImGui.BeginChild(ctx, "##statusbar", 0, 22, 0) then
    local ox, oy = ImGui.GetCursorPos(ctx)
    push_mono()
    local now = os.time()
    ImGui.SetCursorPos(ctx, ox + pad_x, oy + pad_y)
    if ui.flash_msg and os.difftime(now, ui.flash_t) < 3 then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.teal)
      ImGui.Text(ctx, ui.flash_msg)
      ImGui.PopStyleColor(ctx)
    else
      if ui.flash_msg then ui.flash_msg = nil end
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
      ImGui.Text(ctx, string.format("%d projects", #projects))
      ImGui.PopStyleColor(ctx)
    end
    -- Keyboard hint (right side)
    local hint = "Ctrl+K  quick open"
    ImGui.SetCursorPos(ctx, ImGui.GetWindowWidth(ctx) - (#hint * 6.5) - pad_x, oy + pad_y)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.text4)
    ImGui.Text(ctx, hint)
    ImGui.PopStyleColor(ctx)
    pop_mono()
  end
  ImGui.EndChild(ctx)
  ImGui.PopStyleVar(ctx)
  ImGui.PopStyleColor(ctx)
end

-- ── Main loop ─────────────────────────────────────────────────────────
local function loop()
  local base_nc, base_nv = theme.Push(ctx)
  push_rs_theme()

  ImGui.SetNextWindowSize(ctx, 900, 650, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "ReaStart — Project Launcher", true, WIN_FLAGS)

  if visible then
    -- Save window position for palette centering
    ui.win_x, ui.win_y = ImGui.GetWindowPos(ctx)
    ui.win_w, ui.win_h = ImGui.GetWindowSize(ctx)

    render_topbar()
    render_tabbar()

    -- Body
    local avail_w, avail_h = ImGui.GetContentRegionAvail(ctx)
    local show_detail = (ui.tab == "recent" or ui.tab == "pinned" or ui.tab == "sets")
    local detail_w    = show_detail and 290 or 0
    local list_w      = show_detail and (avail_w - detail_w - 1) or -1

    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.bg)
    if ImGui.BeginChild(ctx, "##main_pane", list_w, avail_h - 24, 0) then
      if     ui.tab == "recent"    then render_recent_panel()
      elseif ui.tab == "pinned"    then render_pinned_panel()
      elseif ui.tab == "sets"      then render_sets_panel()
      elseif ui.tab == "templates" then render_templates_panel()
      elseif ui.tab == "folders"   then render_folders_panel()
      elseif ui.tab == "settings"  then render_settings_panel()
      end
    end
    ImGui.EndChild(ctx)
    ImGui.PopStyleColor(ctx)

    if show_detail then
      ImGui.SameLine(ctx)
      local dl = ImGui.GetWindowDrawList(ctx)
      local dx, dy = ImGui.GetCursorScreenPos(ctx)
      ImGui.DrawList_AddLine(dl, dx, dy, dx, dy + avail_h, C.border, 1)
      ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.panel)
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
      if ImGui.BeginChild(ctx, "##detail_pane", detail_w, avail_h - 24, 0) then
        local pad = 10
        local ox, oy = ImGui.GetCursorPos(ctx)
        ImGui.SetCursorPos(ctx, ox + pad, oy + pad)
        local cw, ch = ImGui.GetContentRegionAvail(ctx)
        ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
        if ImGui.BeginChild(ctx, "##detail_inner", cw - pad, ch - pad, 0) then
          render_detail_pane()
        end
        ImGui.EndChild(ctx)
        ImGui.PopStyleVar(ctx)
      end
      ImGui.EndChild(ctx)
      ImGui.PopStyleVar(ctx)
      ImGui.PopStyleColor(ctx)
    end

    render_statusbar()
  end

  ImGui.End(ctx)
  pop_rs_theme()
  theme.Pop(ctx, base_nc, base_nv)

  -- Palette overlay
  if ui.palette_open then
    push_rs_theme()
    render_palette()
    pop_rs_theme()
  end

  -- Tag popup overlay
  if tag_popup.open then
    push_rs_theme()
    render_tag_popup()
    pop_rs_theme()
  end

  -- Set creation popup overlay
  if set_popup.open then
    push_rs_theme()
    render_set_popup()
    pop_rs_theme()
  end

  -- Global keyboard: Ctrl+K, Escape
  if not ImGui.IsAnyItemActive(ctx) then
    local ctrl = (KEY_LCTRL and ImGui.IsKeyDown(ctx, KEY_LCTRL))
              or (KEY_RCTRL and ImGui.IsKeyDown(ctx, KEY_RCTRL))
    if ctrl and KEY_K and ImGui.IsKeyPressed(ctx, KEY_K) then
      ui.palette_open  = true
      ui.palette_q     = ""
      ui.palette_sel   = 1
      ui.palette_focus = true
    end
    if not ui.palette_open and KEY_ESCAPE and ImGui.IsKeyPressed(ctx, KEY_ESCAPE) then
      -- Could close window if desired
    end
  end

  if open and not ui.close_requested then reaper.defer(loop) end
end

-- ── Init ──────────────────────────────────────────────────────────────
load_all_state()
templates = get_templates()
build_project_list()

reaper.atexit(function()
  -- Flush live notes buffers then write data file once
  local dirty = false
  for path, buf in pairs(notes_buf) do
    project_notes[path_key(path)] = buf
    dirty = true
  end
  if dirty then save_all_state() end
end)

reaper.defer(loop)
