-- @description Export Time Selection as Video (GUI)
-- @version 1.1
-- @about
--   ReaImGui dialog that renders the current time selection to a video file
--   using REAPER's native video render formats (AVFoundation, FFmpeg/libav,
--   GIF, LCF), with full control over each format's options (container,
--   codec, bitrate/quality, size, framerate, etc). Supports multiple named
--   presets (tabs), same as Smart Export Selected Items (GUI).
--   SWS extension is required (render-quality config vars).
-- @author Stephen Schappler
-- @link https://www.stephenschappler.com
-- @provides
--   [nomain] ../Common/VideoRenderFormat.lua > Common/VideoRenderFormat.lua
-- @changelog
--   08/23/26 v1.1 - Removed ReaImGuiTheme.lua from @provides: it's already
--                   a separately-installed shared "Common" package with its
--                   own Fonts/ dependency, and re-providing it here made
--                   ReaPack materialize an incomplete copy alongside this
--                   script (missing Fonts/fa-solid-900.ttf), which this
--                   script's own Common/-first lookup then preferred over
--                   the real, complete install -- causing "Could not load
--                   font file!" on ImGui_PushFont.
--   08/23/26 v1.0 - Initial release

-- ============================================================
-- Dependency checks
-- ============================================================
if not reaper.SNM_SetIntConfigVar then
  reaper.ShowMessageBox(
    "The SWS extension is required but not installed.\nDownload it from https://www.sws-extension.org",
    "Missing dependency", 0)
  return
end

if not reaper.ImGui_GetBuiltinPath then
  reaper.ShowMessageBox("ReaImGui is required for this script.", "Missing Dependency", 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

-- ============================================================
-- Paths
-- ============================================================
local script_path = ({reaper.get_action_context()})[2]
local script_dir  = script_path:match("^(.*[/\\])")
local tpl_dir     = script_dir .. "Video Export Templates" .. (reaper.GetOS():find("Win") and "\\" or "/")

local function require_common(filename)
  local path = script_dir .. "Common/" .. filename
  if not reaper.file_exists(path) then
    path = script_dir .. "../Common/" .. filename
  end
  return dofile(path)
end

local theme = require_common("ReaImGuiTheme.lua")
local VF    = require_common("VideoRenderFormat.lua")

-- ============================================================
-- Template I/O
-- ============================================================
local DEFAULTS = {
  name                    = "Default",
  tab_color               = 0,
  render_output_dir       = "",
  render_output_pattern   = "$project $date $hour12_$minute",
  -- Defaults to FFmpeg/libav, H.264 in a QT/MOV/MP4 container, 24-bit PCM
  -- audio -- the one combination that renders identically on both Mac and
  -- Windows (AVFoundation is Mac-only; most other FFmpeg codec choices are
  -- flagged Windows-only in the format's own docs).
  format_id               = "ffmpeg", -- "avf" | "ffmpeg" | "gif" | "lcf"
  container               = 3,        -- ffmpeg: QT/MOV/MP4
  video_codec             = 0,        -- ffmpeg/QT-MOV-MP4: H.264
  video_bitrate_kbps      = 6000,
  video_quality           = 95,
  audio_codec             = 3,        -- ffmpeg/QT-MOV-MP4: 24-bit PCM
  audio_bitrate_kbps      = 320,
  width                   = 1920,
  height                  = 1080,
  framerate               = 60,
  preserve_aspect         = true,
  gif_ignore_bits         = 0,
  gif_encode_transparency = false,
  lcf_tweak               = "t20 x128 y16",
  open_folder_after       = true,
  close_after_render      = false,
}

local function ensure_tpl_dir()
  reaper.RecursiveCreateDirectory(tpl_dir, 0)
end

local function save_template(t)
  ensure_tpl_dir()
  local path = tpl_dir .. t.name .. ".lua"
  local f = io.open(path, "w")
  if not f then
    reaper.ShowMessageBox("Could not write template:\n" .. path, "Export Video", 0)
    return
  end
  f:write("-- Export Video Template\n")
  f:write("name                    = " .. string.format("%q", t.name)                  .. "\n")
  f:write("tab_color               = " .. tostring(t.tab_color)                        .. "\n")
  f:write("render_output_dir       = " .. string.format("%q", t.render_output_dir)     .. "\n")
  f:write("render_output_pattern   = " .. string.format("%q", t.render_output_pattern) .. "\n")
  f:write("format_id               = " .. string.format("%q", t.format_id)             .. "\n")
  f:write("container               = " .. tostring(t.container)                        .. "\n")
  f:write("video_codec             = " .. tostring(t.video_codec)                      .. "\n")
  f:write("video_bitrate_kbps      = " .. tostring(t.video_bitrate_kbps)                .. "\n")
  f:write("video_quality           = " .. tostring(t.video_quality)                     .. "\n")
  f:write("audio_codec             = " .. tostring(t.audio_codec)                      .. "\n")
  f:write("audio_bitrate_kbps      = " .. tostring(t.audio_bitrate_kbps)                .. "\n")
  f:write("width                   = " .. tostring(t.width)                             .. "\n")
  f:write("height                  = " .. tostring(t.height)                            .. "\n")
  f:write("framerate               = " .. tostring(t.framerate)                         .. "\n")
  f:write("preserve_aspect         = " .. tostring(t.preserve_aspect)                   .. "\n")
  f:write("gif_ignore_bits         = " .. tostring(t.gif_ignore_bits)                   .. "\n")
  f:write("gif_encode_transparency = " .. tostring(t.gif_encode_transparency)           .. "\n")
  f:write("lcf_tweak               = " .. string.format("%q", t.lcf_tweak)              .. "\n")
  f:write("open_folder_after       = " .. tostring(t.open_folder_after)                 .. "\n")
  f:write("close_after_render      = " .. tostring(t.close_after_render)                .. "\n")
  f:close()
end

local function load_template_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*all")
  f:close()
  local t = {}
  local env = setmetatable({}, {
    __index    = _G,
    __newindex = function(_, k, v) t[k] = v end,
  })
  local chunk
  if _VERSION == "Lua 5.1" then
    chunk = loadstring(content) -- luacheck: ignore
    if chunk then setfenv(chunk, env) end -- luacheck: ignore
  else
    chunk = load(content, "template", "t", env)
  end
  if not chunk then return nil end
  pcall(chunk)
  for k, v in pairs(DEFAULTS) do
    if t[k] == nil then t[k] = v end
  end
  return t
end

local function list_templates()
  local list = {}
  local i = 0
  while true do
    local file = reaper.EnumerateFiles(tpl_dir, i)
    if not file then break end
    if file:match("%.lua$") and not file:match("^%.") then
      local name = file:gsub("%.lua$", "")
      local t = load_template_file(tpl_dir .. file)
      if t then
        t.name = name
        table.insert(list, t)
      end
    end
    i = i + 1
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

local function delete_template(name)
  os.remove(tpl_dir .. name .. ".lua")
end

local function rename_template_file(old_name, new_name)
  local t = load_template_file(tpl_dir .. old_name .. ".lua")
  if not t then return false end
  t.name = new_name
  save_template(t)
  delete_template(old_name)
  return true
end

local function bootstrap_default_template()
  ensure_tpl_dir()
  local t = {}
  for k, v in pairs(DEFAULTS) do t[k] = v end
  save_template(t)
  return t
end

-- ============================================================
-- Format/codec option helpers (data-driven from VideoRenderFormat.lua)
-- ============================================================
local function containers_for(format_id)
  if format_id == "avf" then return VF.AVF_CONTAINERS end
  if format_id == "ffmpeg" then return VF.FFMPEG_CONTAINERS end
  return nil
end

local function video_codecs_for(format_id, container)
  if format_id == "avf" then return VF.AVF_VIDEO_CODECS[container] or VF.AVF_VIDEO_CODECS.DEFAULT end
  if format_id == "ffmpeg" then return VF.FFMPEG_VIDEO_CODECS[container] end
  return nil
end

local function audio_codecs_for(format_id, container)
  if format_id == "avf" then return VF.AVF_AUDIO_CODECS[container] or VF.AVF_AUDIO_CODECS.DEFAULT end
  if format_id == "ffmpeg" then return VF.FFMPEG_AUDIO_CODECS[container] end
  return nil
end

local function find_by_id(list, id)
  if not list then return nil end
  for _, opt in ipairs(list) do
    if opt.id == id then return opt end
  end
  return nil
end

-- Clamps container/video_codec/audio_codec to valid entries for t.format_id,
-- called whenever format_id or container changes. Mirrors the bit_depth
-- clamp-on-format-change pattern in Smart Export Selected Items (GUI).lua.
local function clamp_video_options(t)
  local containers = containers_for(t.format_id)
  if containers and not find_by_id(containers, t.container) then
    t.container = containers[1].id
  end
  local vcodecs = video_codecs_for(t.format_id, t.container)
  if vcodecs and not find_by_id(vcodecs, t.video_codec) then
    t.video_codec = vcodecs[1].id
  end
  local acodecs = audio_codecs_for(t.format_id, t.container)
  if acodecs and not find_by_id(acodecs, t.audio_codec) then
    t.audio_codec = acodecs[1].id
  end
end

-- Best-guess file extension for the preview/status area -- REAPER's actual
-- output extension depends on its own per-format remembered defaults.
local function file_ext_for(t)
  if t.format_id == "gif" then return ".gif" end
  if t.format_id == "lcf" then return ".lcf" end
  if t.format_id == "avf" then
    if t.container == 2 then return ".mov" end
    if t.container == 3 then return ".m4a" end
    return ".mp4"
  end
  if t.format_id == "ffmpeg" then
    local ext_by_container = { [0] = ".avi", [1] = ".mpg", [2] = ".mpg", [3] = ".mp4", [4] = ".mkv", [5] = ".flv", [6] = ".webm" }
    return ext_by_container[t.container] or ".mp4"
  end
  return ""
end

-- ============================================================
-- Render
-- ============================================================
local function build_render_format_blob(t)
  if t.format_id == "avf" then return VF.encode_avf(t) end
  if t.format_id == "ffmpeg" then return VF.encode_ffmpeg(t) end
  if t.format_id == "gif" then return VF.encode_gif(t) end
  if t.format_id == "lcf" then return VF.encode_lcf(t) end
  return VF.encode_avf(t)
end

local function run_export(t)
  local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if end_time <= start_time then
    reaper.ShowMessageBox("No time selection. Make a time selection before exporting.", "Export Video", 0)
    return
  end

  reaper.Undo_BeginBlock()

  local _, original_cfg = reaper.GetSetProjectInfo_String(0, 'RENDER_CFG', '', false)
  local original_boundsflag = reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 0, false)

  local blob = build_render_format_blob(t)
  reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT', blob, true)
  reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT2', '', true)

  reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true) -- Time selection
  reaper.GetSetProjectInfo(0, 'RENDER_STARTPOS', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_ENDPOS', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TAILFLAG', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TAILMS', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_DITHER', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_NORMALIZE', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_BRICKWALL', 1, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEIN', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEOUT', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEINSHAPE', 1, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEOUTSHAPE', 1, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TRIMSTART', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TRIMEND', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_PADSTART', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_PADEND', 0, true)

  -- Source: leave whatever it currently is, minus Smart Export's "selected
  -- media items (via master)" bits, which would otherwise silently restrict
  -- this time-selection render to an item selection left over from a
  -- previous Smart Export run in this project session.
  local SOURCE_SELECTED_ITEMS            = 0x20
  local SOURCE_SELECTED_ITEMS_VIA_MASTER = 0x40
  local cur_settings = reaper.GetSetProjectInfo(0, 'RENDER_SETTINGS', 0, false)
  reaper.GetSetProjectInfo(0, 'RENDER_SETTINGS',
    cur_settings & ~(SOURCE_SELECTED_ITEMS | SOURCE_SELECTED_ITEMS_VIA_MASTER), true)

  reaper.GetSetProjectInfo_String(0, 'RENDER_FILE',    t.render_output_dir,     true)
  reaper.GetSetProjectInfo_String(0, 'RENDER_PATTERN', t.render_output_pattern, true)

  reaper.SNM_SetIntConfigVar('projrenderlimit',        0)
  reaper.SNM_SetIntConfigVar('projrenderrateinternal', 1)
  reaper.SNM_SetIntConfigVar('projrenderresample',     10)

  reaper.Main_OnCommand(41824, 0) -- Render project, using the most recent render settings, auto-close

  reaper.GetSetProjectInfo_String(0, 'RENDER_CFG', original_cfg, true)
  reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', original_boundsflag, true)

  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Export Time Selection as Video', -1)

  if t.open_folder_after then
    local folder = t.render_output_dir ~= "" and t.render_output_dir or reaper.GetProjectPath()
    reaper.CF_ShellExecute(folder)
  end
end

-- ============================================================
-- Output path preview
-- Approximates how a handful of the most common wildcards resolve, for
-- display only -- REAPER itself resolves the real render pattern (including
-- every wildcard in the Wildcards menu) at render time.
-- ============================================================
local PATH_SEP = reaper.GetOS():find("Win") and "\\" or "/"

local function get_preview_project_tokens()
  local proj_fn = reaper.GetProjectName(0, "")
  local proj_name = proj_fn ~= "" and (proj_fn:gsub("%.[Rr][Pp][Pp]$", "")) or "untitled"
  local proj_path = reaper.GetProjectPath()
  return proj_name, proj_path
end

local function resolve_preview_pattern(pattern)
  local proj_name, proj_path = get_preview_project_tokens()
  local user = os.getenv("USER") or os.getenv("USERNAME") or ""
  local date = os.date("%Y-%m-%d")
  local resolved = pattern
  -- $projectdirectory must be substituted before $project since the latter
  -- is a prefix of the former.
  resolved = resolved:gsub("%$projectdirectory", (proj_path:gsub("%%", "%%%%")))
  resolved = resolved:gsub("%$project",          (proj_name:gsub("%%", "%%%%")))
  resolved = resolved:gsub("%$user",             (user:gsub("%%", "%%%%")))
  resolved = resolved:gsub("%$date",             date)
  return resolved
end

local function build_preview_path(dir, pattern, file_ext)
  local resolved_dir = dir ~= "" and dir or reaper.GetProjectPath()
  return resolved_dir .. PATH_SEP .. resolve_preview_pattern(pattern) .. file_ext
end

local function split_preview_path(full_path)
  local last_sep = nil
  for j = #full_path, 1, -1 do
    local c = full_path:sub(j, j)
    if c == "/" or c == "\\" then last_sep = j break end
  end
  if not last_sep then return "", full_path end
  return full_path:sub(1, last_sep - 1), full_path:sub(last_sep + 1)
end

-- ============================================================
-- Render filename wildcards -- same token set as Smart Export Selected
-- Items (GUI).lua (format-agnostic; extracted from REAPER's own Wildcard
-- Help dialog text since there's no ReaScript API to query it).
-- ============================================================
local WILDCARD_CATEGORIES = {
  {
    name = "Project Information",
    tokens = {
      {"$project", "Project name"},
      {"$title", "Project title (from Project Settings/Notes dialog)"},
      {"$author", "Project author (from Project Settings/Notes dialog)"},
      {"$projectnotes", "Project notes (from Project Settings/Notes dialog)"},
      {"$projectdirectory", "Project directory on disk"},
      {"$tempo", "Project tempo"},
      {"$timesignature", "Project time signature, formatted as 4/4"},
      {"$playrate", "Project play rate"},
    },
  },
  {
    name = "Regions/Markers",
    tokens = {
      {"$region", "Region name or ID number"},
      {"$regionname", "Region name"},
      {"$regionnumber", "Region ID number"},
      {"$marker", "Marker name or ID number"},
      {"$markername", "Marker name"},
      {"$markernumber", "Marker ID number"},
    },
  },
  {
    name = "Position/Length",
    tokens = {
      {"$start", "Start time, ruler time format"},
      {"$end", "End time, ruler time format"},
      {"$length", "Length, ruler time format"},
      {"$startbeats", "Start time as measures.beats"},
      {"$endbeats", "End time as measures.beats"},
      {"$lengthbeats", "Length as measures.beats"},
      {"$starttc", "Start time as HH.MM.SS.FF"},
      {"$endtc", "End time as HH.MM.SS.FF"},
      {"$timesel", "Project time selection, ruler time format"},
    },
  },
  {
    name = "Output Format",
    tokens = {
      {"$format", "Render format (example: wav)"},
      {"$samplerate", "Sample rate in Hz"},
      {"$channels", "Number of render channels"},
    },
  },
  {
    name = "Date/Time",
    tokens = {
      {"$date", "Date"},
      {"$time", "Time"},
      {"$datetime", "Date and time"},
      {"$year", "Year"},
      {"$month", "Month number"},
      {"$day", "Day of the month"},
      {"$hour", "Hour of the day, 24-hour format"},
      {"$hour12", "Hour of the day, 12-hour format"},
      {"$ampm", "\"am\" if before noon, \"pm\" if after noon"},
      {"$minute", "Minute of the hour"},
      {"$second", "Second of the minute"},
      {"$uniqueid", "N-character random hexadecimal string (N between 8 and 16)"},
    },
  },
  {
    name = "Computer Information",
    tokens = {
      {"$user", "User name"},
      {"$computer", "Computer name"},
    },
  },
}

local FORMAT_OPTIONS = {
  { id = "avf",    label = "AVFoundation (MPEG-4, MOV)" },
  { id = "ffmpeg", label = "FFmpeg/libav (video, compressed audio)" },
  { id = "gif",    label = "GIF (video only)" },
  { id = "lcf",    label = "LCF (video only)" },
}

-- ============================================================
-- ImGui context
-- ============================================================
local script_title = "EXPORT VIDEO"
local ctx = ImGui.CreateContext(script_title)

local mono_font_name = reaper.GetOS():find("Win") and "Consolas" or "Menlo"
local mono_font = ImGui.CreateFont(mono_font_name)
ImGui.Attach(ctx, mono_font)

local WIN_FLAGS = ImGui.WindowFlags_NoCollapse

-- ============================================================
-- Template state
-- ============================================================
local templates  = {}
local active_idx = 1

-- Live edit buffers (synced from/to active template)
local dir_buf, pattern_buf
local format_id, container, video_codec, audio_codec
local video_bitrate_buf, video_quality_buf, audio_bitrate_buf
local width_buf, height_buf, framerate_buf
local preserve_aspect
local gif_ignore_bits_buf, gif_encode_transparency
local lcf_tweak_buf
local open_folder_en, close_after_render_en

local rename_pending    = false
local rename_focus_next = false
local rename_idx        = 1
local rename_buf        = ""
local rename_dup_err    = false

local delete_pending = false
local delete_idx     = 1

local last_active_idx = 0
local open = true
local left_footer_h = 0

-- ============================================================
-- Buffer helpers
-- ============================================================
local function sync_buffers_from(t)
  dir_buf     = t.render_output_dir
  pattern_buf = t.render_output_pattern
  format_id   = t.format_id
  container   = t.container
  video_codec = t.video_codec
  audio_codec = t.audio_codec
  video_bitrate_buf = tostring(t.video_bitrate_kbps)
  video_quality_buf = tostring(t.video_quality)
  audio_bitrate_buf = tostring(t.audio_bitrate_kbps)
  width_buf     = tostring(t.width)
  height_buf    = tostring(t.height)
  framerate_buf = tostring(t.framerate)
  preserve_aspect = t.preserve_aspect
  gif_ignore_bits_buf = tostring(t.gif_ignore_bits)
  gif_encode_transparency = t.gif_encode_transparency
  lcf_tweak_buf = t.lcf_tweak
  open_folder_en = t.open_folder_after
  close_after_render_en = t.close_after_render
end

local function flush_buffers_to(t)
  t.render_output_dir     = dir_buf
  t.render_output_pattern = pattern_buf
  t.format_id = format_id
  t.container = container
  t.video_codec = video_codec
  t.audio_codec = audio_codec
  t.video_bitrate_kbps = tonumber(video_bitrate_buf) or t.video_bitrate_kbps
  t.video_quality      = tonumber(video_quality_buf) or t.video_quality
  t.audio_bitrate_kbps = tonumber(audio_bitrate_buf) or t.audio_bitrate_kbps
  t.width     = tonumber(width_buf)     or t.width
  t.height    = tonumber(height_buf)    or t.height
  t.framerate = tonumber(framerate_buf) or t.framerate
  t.preserve_aspect = preserve_aspect
  t.gif_ignore_bits = tonumber(gif_ignore_bits_buf) or t.gif_ignore_bits
  t.gif_encode_transparency = gif_encode_transparency
  t.lcf_tweak = lcf_tweak_buf
  t.open_folder_after  = open_folder_en
  t.close_after_render = close_after_render_en
end

-- ============================================================
-- Init templates
-- ============================================================
local function name_in_use(name, exclude_idx)
  for i, t in ipairs(templates) do
    if t.name == name and i ~= (exclude_idx or -1) then return true end
  end
  return false
end

local function init_templates()
  ensure_tpl_dir()
  templates = list_templates()
  if #templates == 0 then
    table.insert(templates, bootstrap_default_template())
  end

  local saved_name = reaper.GetExtState("ExportVideo", "active_template")
  active_idx = 1
  if saved_name ~= "" then
    for i, t in ipairs(templates) do
      if t.name == saved_name then active_idx = i; break end
    end
  end

  sync_buffers_from(templates[active_idx])
  last_active_idx = active_idx
end

init_templates()

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  local color_count, var_count = theme.Push(ctx)

  local col_tab_selected = rawget(ImGui, "Col_TabSelected") or rawget(ImGui, "Col_TabActive")
  if col_tab_selected then
    ImGui.PushStyleColor(ctx, col_tab_selected, 0x282828FF)
    color_count = color_count + 1
  end
  local col_tab_overline = rawget(ImGui, "Col_TabSelectedOverline")
  if col_tab_overline then
    ImGui.PushStyleColor(ctx, col_tab_overline, 0xA08FE2FF)
    color_count = color_count + 1
  end

  local WIN_W = 950
  ImGui.SetNextWindowSizeConstraints(ctx, 630, 0, 3000, 10000)
  ImGui.SetNextWindowSize(ctx, WIN_W, 0, ImGui.Cond_FirstUseEver)
  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then

    -- ── Tab bar ─────────────────────────────────────────────
    if ImGui.BeginTabBar(ctx, "##templates", ImGui.TabBarFlags_AutoSelectNewTabs) then

      for i, t in ipairs(templates) do
        local tab_visible, new_open = ImGui.BeginTabItem(ctx, t.name, true, 0)

        local tab_min_x, tab_min_y = ImGui.GetItemRectMin(ctx)
        local tab_max_x, tab_max_y = ImGui.GetItemRectMax(ctx)
        local draw_list = ImGui.GetWindowDrawList(ctx)

        if t.tab_color ~= 0 then
          ImGui.DrawList_AddRectFilled(draw_list, tab_min_x, tab_min_y, tab_min_x + 3, tab_max_y, t.tab_color)
        end

        if tab_visible and not col_tab_overline then
          ImGui.DrawList_AddRectFilled(draw_list, tab_min_x, tab_min_y, tab_max_x, tab_min_y + 2, 0xA08FE2FF)
        end

        if ImGui.BeginPopupContextItem(ctx, "##ctx_" .. i) then
          if ImGui.MenuItem(ctx, "Rename\u{2026}") then
            rename_pending  = true
            rename_idx      = i
            rename_buf      = t.name
            rename_dup_err  = false
          end
          if ImGui.BeginMenu(ctx, "Color") then
            local rgb = (t.tab_color >> 8) & 0xFFFFFF
            local color_changed, new_rgb = ImGui.ColorPicker3(ctx, "##tab_color_picker", rgb)
            if color_changed then
              t.tab_color = (new_rgb << 8) | 0xFF
              save_template(t)
            end
            ImGui.Separator(ctx)
            if ImGui.MenuItem(ctx, "Clear Color", nil, false, t.tab_color ~= 0) then
              t.tab_color = 0
              save_template(t)
            end
            ImGui.EndMenu(ctx)
          end
          local can_delete = #templates > 1
          if not can_delete then ImGui.BeginDisabled(ctx, true) end
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF5555FF)
          if ImGui.MenuItem(ctx, "Delete") then
            delete_pending = true
            delete_idx     = i
          end
          ImGui.PopStyleColor(ctx)
          if not can_delete then ImGui.EndDisabled(ctx) end
          ImGui.EndPopup(ctx)
        end

        if not new_open and #templates > 1 then
          delete_pending = true
          delete_idx     = i
        end

        if tab_visible then
          if i ~= last_active_idx then
            if last_active_idx >= 1 and last_active_idx <= #templates then
              flush_buffers_to(templates[last_active_idx])
            end
            active_idx      = i
            last_active_idx = i
            sync_buffers_from(t)
          end
          ImGui.EndTabItem(ctx)
        end
      end

      if ImGui.TabItemButton(ctx, "+", ImGui.TabItemFlags_Trailing) then
        flush_buffers_to(templates[active_idx])

        local base = "New Preset"
        local new_name = base
        local suffix = 2
        while name_in_use(new_name) do
          new_name = base .. " " .. suffix; suffix = suffix + 1
        end

        local src = templates[active_idx]
        local new_t = {}
        for k, v in pairs(src) do new_t[k] = v end
        new_t.name = new_name
        save_template(new_t)
        table.insert(templates, new_t)

        active_idx      = #templates
        last_active_idx = #templates
        sync_buffers_from(new_t)

        rename_pending    = true
        rename_focus_next = true
        rename_idx        = active_idx
        rename_buf        = new_name
        rename_dup_err    = false
      end

      ImGui.EndTabBar(ctx)
    end

    -- ── Left column: settings rail ───────────────────────────
    local LEFT_COL_W     = 280
    local LEFT_PAD       = 10
    local TOP_PAD        = 8
    local LEFT_CONTENT_W = LEFT_COL_W - LEFT_PAD * 2
    local CTL_W          = 150

    local _, avail_h = ImGui.GetContentRegionAvail(ctx)
    local lx0, ly0 = ImGui.GetCursorScreenPos(ctx)
    do
      local draw_list = ImGui.GetWindowDrawList(ctx)
      ImGui.DrawList_AddRectFilled(draw_list, lx0, ly0, lx0 + LEFT_COL_W, ly0 + avail_h, 0x222222FF, 4)
    end

    ImGui.BeginGroup(ctx)
    ImGui.Indent(ctx, LEFT_PAD)
    ImGui.Dummy(ctx, 0, TOP_PAD)

    local function begin_field_table(id)
      local ok = ImGui.BeginTable(ctx, id, 2, 0, LEFT_CONTENT_W, 0)
      if ok then
        ImGui.TableSetupColumn(ctx, "##ctl",   ImGui.TableColumnFlags_WidthFixed, CTL_W)
        ImGui.TableSetupColumn(ctx, "##label", ImGui.TableColumnFlags_WidthStretch)
      end
      return ok
    end

    -- widget_id (optional) disambiguates the ImGui widget ID from the
    -- visible label text -- several rows share a label across sections
    -- (e.g. "Codec"/"Bitrate (kbps)" appear under both VIDEO and AUDIO),
    -- which would otherwise collide on the same "##<label>" ImGui ID.
    local function combo_row(label, current_id, options, on_pick, widget_id)
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local cur_opt = find_by_id(options, current_id)
      ImGui.SetNextItemWidth(ctx, -1)
      if ImGui.BeginCombo(ctx, "##" .. (widget_id or label), cur_opt and cur_opt.label or tostring(current_id), 0) then
        for _, opt in ipairs(options) do
          if ImGui.Selectable(ctx, opt.label, current_id == opt.id, 0) then
            on_pick(opt.id)
          end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, label)
    end

    local function text_row(label, buf, flags, widget_id)
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, new_val = ImGui.InputText(ctx, "##" .. (widget_id or label), buf, flags or ImGui.InputTextFlags_CharsDecimal)
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, label)
      return new_val
    end

    -- FORMAT section
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, "FORMAT")
    ImGui.PopStyleColor(ctx)

    if begin_field_table("##format_fields") then
      combo_row("Format", format_id, FORMAT_OPTIONS, function(id)
        format_id = id
        local tmp = { format_id = format_id, container = container, video_codec = video_codec, audio_codec = audio_codec }
        clamp_video_options(tmp)
        container, video_codec, audio_codec = tmp.container, tmp.video_codec, tmp.audio_codec
      end)

      local containers = containers_for(format_id)
      if containers then
        combo_row("Container", container, containers, function(id)
          container = id
          local tmp = { format_id = format_id, container = container, video_codec = video_codec, audio_codec = audio_codec }
          clamp_video_options(tmp)
          video_codec, audio_codec = tmp.video_codec, tmp.audio_codec
        end)
      end

      ImGui.EndTable(ctx)
    end

    -- Container 3 ("MPEG-4 Audio") on AVFoundation produces no video at
    -- all -- hide every video-specific control in that case.
    local is_audio_only = (format_id == "avf" and container == 3)

    if not is_audio_only then
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
      ImGui.Text(ctx, "VIDEO")
      ImGui.PopStyleColor(ctx)

      if begin_field_table("##video_fields") then
        local vcodecs = video_codecs_for(format_id, container)
        local vcodec_opt = vcodecs and find_by_id(vcodecs, video_codec)

        if vcodecs then
          combo_row("Codec", video_codec, vcodecs, function(id) video_codec = id end, "video_codec")
        end

        if vcodec_opt and vcodec_opt.rate_mode == "bitrate" then
          video_bitrate_buf = text_row("Bitrate (kbps)", video_bitrate_buf, nil, "video_bitrate")
        elseif vcodec_opt and vcodec_opt.rate_mode == "quality" then
          video_quality_buf = text_row("Quality", video_quality_buf, nil, "video_quality")
        end

        width_buf  = text_row("Width", width_buf)
        height_buf = text_row("Height", height_buf)
        framerate_buf = text_row((format_id == "gif" or format_id == "lcf") and "Max Framerate" or "Framerate", framerate_buf, ImGui.InputTextFlags_CharsDecimal)

        ImGui.EndTable(ctx)
      end

      local _, new_aspect = ImGui.Checkbox(ctx, "Preserve Aspect Ratio", preserve_aspect)
      preserve_aspect = new_aspect
    end

    -- AUDIO section -- audio_codecs_for only returns a list for avf/ffmpeg,
    -- nil for gif/lcf ("(video only)" formats with no audio track at all).
    local acodecs = audio_codecs_for(format_id, container)
    if acodecs then
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
      ImGui.Text(ctx, "AUDIO")
      ImGui.PopStyleColor(ctx)

      if begin_field_table("##audio_fields") then
        local acodec_opt = find_by_id(acodecs, audio_codec)
        combo_row("Codec", audio_codec, acodecs, function(id) audio_codec = id end, "audio_codec")
        local is_pcm_or_none = acodec_opt and (acodec_opt.label:find("PCM") or acodec_opt.label == "None")
        if not is_pcm_or_none then
          audio_bitrate_buf = text_row("Bitrate (kbps)", audio_bitrate_buf, nil, "audio_bitrate")
        end
        ImGui.EndTable(ctx)
      end
    end

    -- GIF-specific
    if format_id == "gif" then
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
      ImGui.Text(ctx, "GIF OPTIONS")
      ImGui.PopStyleColor(ctx)
      if begin_field_table("##gif_fields") then
        gif_ignore_bits_buf = text_row("Ignore Low Bits (0-7)", gif_ignore_bits_buf)
        ImGui.EndTable(ctx)
      end
      local _, new_transparency = ImGui.Checkbox(ctx, "Encode Transparency", gif_encode_transparency)
      gif_encode_transparency = new_transparency
    end

    -- LCF-specific
    if format_id == "lcf" then
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
      ImGui.Text(ctx, "LCF OPTIONS")
      ImGui.PopStyleColor(ctx)
      if begin_field_table("##lcf_fields") then
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.SetNextItemWidth(ctx, -1)
        local _, new_tweak = ImGui.InputText(ctx, "##lcf_tweak", lcf_tweak_buf)
        lcf_tweak_buf = new_tweak
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, "Options Tweak")
        ImGui.EndTable(ctx)
      end
    end

    ImGui.Spacing(ctx)

    local _, new_open_folder_en = ImGui.Checkbox(ctx, "Open Folder After Render", open_folder_en)
    open_folder_en = new_open_folder_en

    local _, new_close_after_render_en = ImGui.Checkbox(ctx, "Close Export Video After Render", close_after_render_en)
    close_after_render_en = new_close_after_render_en

    -- Spacer pushes the Render button + status flush to the rail's bottom
    -- edge (matches Smart Export's layout), using last frame's measured
    -- footer height.
    local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local has_time_sel = end_time > start_time
    local _, fields_bottom_y = ImGui.GetCursorScreenPos(ctx)
    local spacer_h = avail_h - (fields_bottom_y - ly0) - left_footer_h
    if spacer_h > 0 then ImGui.Dummy(ctx, 0, spacer_h) end

    local _, footer_top_y = ImGui.GetCursorScreenPos(ctx)

    ImGui.Spacing(ctx)
    do
      local sx, sy = ImGui.GetCursorScreenPos(ctx)
      local draw_list = ImGui.GetWindowDrawList(ctx)
      ImGui.DrawList_AddRectFilled(draw_list, sx, sy, sx + LEFT_CONTENT_W, sy + 1, 0x3A3F45FF)
    end
    ImGui.Dummy(ctx, 0, 1)
    ImGui.Spacing(ctx)

    if not has_time_sel then ImGui.BeginDisabled(ctx, true) end
    local do_render = theme.PrimaryButton(ctx, "Render", LEFT_CONTENT_W, 0, nil, theme.Icons.VIDEO)
      or (has_time_sel and (
            ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
            or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)))
    if not has_time_sel then ImGui.EndDisabled(ctx) end

    local status_text
    if has_time_sel then
      status_text = ("%.2fs selected"):format(end_time - start_time)
    else
      status_text = "No time selection"
    end
    local status_w = ImGui.CalcTextSize(ctx, status_text)
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + (LEFT_CONTENT_W - status_w) / 2)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, status_text)
    ImGui.PopStyleColor(ctx)

    local _, footer_bottom_y = ImGui.GetCursorScreenPos(ctx)
    left_footer_h = footer_bottom_y - footer_top_y

    ImGui.Unindent(ctx, LEFT_PAD)
    ImGui.EndGroup(ctx)

    -- ── Right column: output dir/filename + resolved preview ─
    ImGui.SameLine(ctx, 0, 20 + LEFT_PAD)

    ImGui.BeginGroup(ctx)
    ImGui.Dummy(ctx, 0, TOP_PAD)

    local has_browse = reaper.JS_Dialog_BrowseForFolder ~= nil
    local action_icon_size = ImGui.GetFontSize(ctx)
    local action_btn_w = theme.IconButtonSize(ctx, action_icon_size)

    if ImGui.BeginTable(ctx, "##right_top", 3) then
      ImGui.TableSetupColumn(ctx, "##input", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableSetupColumn(ctx, "##btn",   ImGui.TableColumnFlags_WidthFixed, action_btn_w)
      ImGui.TableSetupColumn(ctx, "##lbl",   ImGui.TableColumnFlags_WidthFixed, 72)

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      ImGui.PushFont(ctx, mono_font, 13)
      local _, new_dir = ImGui.InputText(ctx, "##dir", dir_buf)
      ImGui.PopFont(ctx)
      dir_buf = new_dir
      ImGui.TableSetColumnIndex(ctx, 1)
      if has_browse then
        if theme.IconButton(ctx, theme.Icons.FOLDER_OPEN .. "##browse_dir", nil, nil, action_icon_size) then
          local ok, folder = reaper.JS_Dialog_BrowseForFolder("Select Export Folder", dir_buf)
          if ok == 1 then dir_buf = folder end
        end
        if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Browse\u{2026}") end
      end
      ImGui.TableSetColumnIndex(ctx, 2)
      ImGui.Text(ctx, "Directory")

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      ImGui.PushFont(ctx, mono_font, 13)
      local _, new_pat = ImGui.InputText(ctx, "##pattern", pattern_buf)
      ImGui.PopFont(ctx)
      pattern_buf = new_pat
      ImGui.TableSetColumnIndex(ctx, 1)
      if theme.IconButton(ctx, theme.Icons.DOLLAR_SIGN .. "##wildcards_btn", nil, nil, action_icon_size) then
        ImGui.OpenPopup(ctx, "##wildcards_popup")
      end
      if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Wildcards") end
      if ImGui.BeginPopup(ctx, "##wildcards_popup") then
        for _, cat in ipairs(WILDCARD_CATEGORIES) do
          if ImGui.BeginMenu(ctx, cat.name) then
            for _, tok in ipairs(cat.tokens) do
              local display, desc = tok[1], tok[2]
              if ImGui.MenuItem(ctx, display) then
                pattern_buf = pattern_buf .. display
              end
              if ImGui.IsItemHovered(ctx) then
                ImGui.SetTooltip(ctx, desc)
              end
            end
            ImGui.EndMenu(ctx)
          end
        end
        ImGui.EndPopup(ctx)
      end
      ImGui.TableSetColumnIndex(ctx, 2)
      ImGui.Text(ctx, "File name")

      ImGui.EndTable(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, "RESOLVED PATH")
    ImGui.PopStyleColor(ctx)

    local preview_file_ext = file_ext_for({ format_id = format_id, container = container })
    local full_path = build_preview_path(dir_buf, pattern_buf, preview_file_ext)
    local dir_part, file_part = split_preview_path(full_path)

    ImGui.PushFont(ctx, mono_font, 13)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, dir_part .. PATH_SEP)
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx, 0, 0)
    ImGui.Text(ctx, file_part)
    ImGui.PopFont(ctx)

    ImGui.EndGroup(ctx)

    -- The actual render call, deferred until every other widget this frame
    -- has already been drawn, same rationale as Smart Export's Render
    -- button (REAPER's native render engine shouldn't run mid-frame with
    -- more ImGui widgets still queued behind it).
    if do_render then
      flush_buffers_to(templates[active_idx])
      local t = templates[active_idx]
      save_template(t)
      reaper.SetExtState("ExportVideo", "active_template", t.name, true)
      if t.close_after_render then open = false end
      run_export(t)
    end

    ImGui.End(ctx)
  end

  -- ── Rename modal ─────────────────────────────────────────
  if rename_pending then
    ImGui.OpenPopup(ctx, "Rename Preset##modal")
    rename_pending    = false
    rename_focus_next = true
  end

  if ImGui.BeginPopupModal(ctx, "Rename Preset##modal", nil,
      ImGui.WindowFlags_AlwaysAutoResize) then
    ImGui.Text(ctx, "Preset name:")
    ImGui.SetNextItemWidth(ctx, 280)
    if rename_focus_next then
      ImGui.SetKeyboardFocusHere(ctx)
      rename_focus_next = false
    end
    local _, new_rb = ImGui.InputText(ctx, "##rename_val", rename_buf,
      ImGui.InputTextFlags_AutoSelectAll)
    rename_buf = new_rb

    if rename_dup_err then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF5555FF)
      ImGui.Text(ctx, "Name already in use.")
      ImGui.PopStyleColor(ctx)
    end

    ImGui.Spacing(ctx)

    local confirm = ImGui.Button(ctx, "OK", 130, 0)
      or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
      or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)

    ImGui.SameLine(ctx)

    if ImGui.Button(ctx, "Cancel", 130, 0) or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      ImGui.CloseCurrentPopup(ctx)
      rename_dup_err = false
    elseif confirm and rename_buf ~= "" then
      if name_in_use(rename_buf, rename_idx) then
        rename_dup_err = true
      else
        local old_name = templates[rename_idx].name
        if old_name ~= rename_buf then
          rename_template_file(old_name, rename_buf)
          if rename_idx == active_idx then
            reaper.SetExtState("ExportVideo", "active_template", rename_buf, true)
          end
        end
        templates[rename_idx].name = rename_buf
        ImGui.CloseCurrentPopup(ctx)
        rename_dup_err = false
      end
    end

    ImGui.EndPopup(ctx)
  end

  -- ── Pending delete ────────────────────────────────────────
  if delete_pending then
    delete_pending = false
    local name = templates[delete_idx] and templates[delete_idx].name or "?"
    local answer = reaper.ShowMessageBox(
      ('Delete preset "%s"? This cannot be undone.'):format(name),
      "Export Video", 4)
    if answer == 6 then
      delete_template(name)
      table.remove(templates, delete_idx)
      if active_idx > delete_idx then
        active_idx = active_idx - 1
      end
      active_idx      = math.max(1, math.min(active_idx, #templates))
      last_active_idx = 0
    end
  end

  theme.Pop(ctx, color_count, var_count)

  if still_open and open then
    reaper.defer(loop)
  end
end

-- ============================================================
-- Entry point
-- ============================================================
reaper.defer(loop)
