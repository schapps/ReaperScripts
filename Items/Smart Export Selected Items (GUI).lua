-- @description Smart Export Selected Items (GUI)
-- @version 1.29
-- @about
--   ReaImGUI render-template dialog for Smart Export Selected Items.
--   Supports multiple named render templates (tabs), normalization controls,
--   folder browsing, and per-template auto-downmix of highly-correlated
--   stereo items to mono before export.
--   Note: the companion "Smart Export Selected Items" (headless) script no
--   longer reads templates set here -- as of its v2.3 it only uses its own
--   sidecar config file (see "Smart Export Selected Items - Configure").
--   SWS extension is required.
-- @author Stephen Schappler
-- @link https://www.stephenschappler.com
-- @changelog
--   08/22/26 v1.25 - Added per-template "Close Smart Export After Render"
--                    checkbox (default on, matching prior behavior). When
--                    off, the dialog stays open after rendering instead of
--                    closing.
--   08/22/26 v1.26 - Directory and Filename inputs now use the monospace
--                    font too, matching the resolved-path preview rows.
--   08/22/26 v1.27 - Added per-template Sample Rate (44.1/48/88.2/96/176.4/
--                    192kHz, default 96kHz) and Bit Depth (16/24/32-bit
--                    float, default 24-bit) dropdowns at the top of the
--                    RENDER section, replacing the previously hardcoded
--                    96kHz/24-bit. Bit depth is applied via a per-depth
--                    RENDER_FORMAT blob (byte layout confirmed against
--                    Ultraschall's documented REAPER render-config format
--                    and cross-checked against this machine's own saved
--                    render presets in reaper-render.ini, which use the
--                    same 24-bit blob this script already hardcoded).
--   08/22/26 v1.28 - Added per-template "2nd Pass Render" checkbox (default
--                    off) after Render via Master, mapping to RENDER_SETTINGS
--                    bit 0x800 -- confirmed against Ultraschall's documented
--                    render-preset bitfield (various_checkboxes2 &2048).
--   08/22/26 v1.29 - Added a "Color" submenu to the tab right-click context
--                    menu (alongside Rename/Delete): an embedded ColorPicker3
--                    plus "Clear Color", persisted per-template. Colored
--                    templates get a thin accent bar on the tab's left edge
--                    (visible whether or not the tab is active) so they stay
--                    identifiable at a glance.

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
local tpl_dir     = script_dir .. "Smart Export Templates" .. (reaper.GetOS():find("Win") and "\\" or "/")

local theme_path = script_dir .. "Common/ReaImGuiTheme.lua"
if not reaper.file_exists(theme_path) then
  theme_path = script_dir .. "../Common/ReaImGuiTheme.lua"
end
local theme = dofile(theme_path)

-- ============================================================
-- Template I/O
-- ============================================================
local DEFAULTS = {
  name                   = "Default",
  render_output_dir      = "",
  render_output_pattern  = "$project\\$item",
  normalize_enabled      = false,
  normalize_mode         = "lufs_i",
  normalize_target_db    = -24.0,
  sample_rate            = 96000,
  bit_depth              = 24,
  tail_ms                = 0,
  mono_downmix_enabled   = true,
  mono_downmix_threshold = 0.9,
  mono_downmix_mode      = "left",
  open_folder_after      = false,
  render_via_master      = true,
  second_pass_render     = false,
  close_after_render     = true,
  tab_color              = 0,
}

-- I_CHANMODE values for each mono downmix mode option
local MONO_DOWNMIX_CHANMODE = {
  left     = 3,
  right    = 4,
  downmix  = 2,
}

local function ensure_tpl_dir()
  reaper.RecursiveCreateDirectory(tpl_dir, 0)
end

local function save_template(t)
  ensure_tpl_dir()
  local path = tpl_dir .. t.name .. ".lua"
  local f = io.open(path, "w")
  if not f then
    reaper.ShowMessageBox("Could not write template:\n" .. path, "Smart Export", 0)
    return
  end
  f:write("-- Smart Export Template\n")
  f:write("name                  = " .. string.format("%q", t.name)                  .. "\n")
  f:write("render_output_dir     = " .. string.format("%q", t.render_output_dir)     .. "\n")
  f:write("render_output_pattern = " .. string.format("%q", t.render_output_pattern) .. "\n")
  f:write("normalize_enabled     = " .. tostring(t.normalize_enabled)                .. "\n")
  f:write("normalize_mode        = " .. string.format("%q", t.normalize_mode)        .. "\n")
  f:write("normalize_target_db   = " .. tostring(t.normalize_target_db)              .. "\n")
  f:write("sample_rate           = " .. tostring(t.sample_rate)                      .. "\n")
  f:write("bit_depth             = " .. tostring(t.bit_depth)                        .. "\n")
  f:write("tail_ms               = " .. tostring(t.tail_ms)                          .. "\n")
  f:write("mono_downmix_enabled   = " .. tostring(t.mono_downmix_enabled)             .. "\n")
  f:write("mono_downmix_threshold = " .. tostring(t.mono_downmix_threshold)           .. "\n")
  f:write("mono_downmix_mode      = " .. string.format("%q", t.mono_downmix_mode)     .. "\n")
  f:write("open_folder_after      = " .. tostring(t.open_folder_after)                .. "\n")
  f:write("render_via_master      = " .. tostring(t.render_via_master)                .. "\n")
  f:write("second_pass_render     = " .. tostring(t.second_pass_render)               .. "\n")
  f:write("close_after_render     = " .. tostring(t.close_after_render)               .. "\n")
  f:write("tab_color              = " .. tostring(t.tab_color)                        .. "\n")
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

-- ============================================================
-- Normalize helpers
-- ============================================================
local function db_to_linear(db) return 10 ^ (db / 20) end

local function normalize_bits(t)
  if not t.normalize_enabled then return 0 end
  local bits = 0x1  -- enable
  if t.normalize_mode == "lufs_m" then bits = bits | 0x8 end
  return bits
end

-- ============================================================
-- Stereo correlation / mono downmix
-- ============================================================
local CORRELATION_ANALYSIS_SAMPLERATE = 8000
local CORRELATION_BLOCK_FRAMES        = 8192
local CORRELATION_DEBUG_LOG           = false  -- prints correlation results to the ReaScript console; set to true to debug

-- Returns Pearson correlation coefficient (-1..1) of L/R channels across the
-- full range of audio available from the take's audio accessor, or nil if it
-- couldn't be computed.
local function compute_stereo_correlation(take)
  local accessor = reaper.CreateTakeAudioAccessor(take)
  if not accessor then return nil end

  -- Query the accessor's own valid time range rather than assuming it lines up
  -- with the item's project-time D_POSITION/D_LENGTH -- passing project-time
  -- positions directly yields 0 samples every call.
  local start_pos = reaper.GetAudioAccessorStartTime(accessor)
  local end_pos    = reaper.GetAudioAccessorEndTime(accessor)

  if CORRELATION_DEBUG_LOG then
    reaper.ShowConsoleMsg(string.format("[Smart Export]   accessor range: %.3fs - %.3fs\n", start_pos, end_pos))
  end

  local samplerate   = CORRELATION_ANALYSIS_SAMPLERATE
  local num_channels  = 2
  local block_frames  = CORRELATION_BLOCK_FRAMES
  local samplebuffer  = reaper.new_array(block_frames * num_channels)

  local sum_l, sum_r, sum_l2, sum_r2, sum_lr, n = 0.0, 0.0, 0.0, 0.0, 0.0, 0
  local pos = start_pos

  while pos < end_pos do
    samplebuffer.clear()
    local ret = reaper.GetAudioAccessorSamples(accessor, samplerate, num_channels, pos, block_frames, samplebuffer)
    if ret == -1 then break end
    if ret == 1 then
      -- GetAudioAccessorSamples' return value is a status flag (0/1/-1), NOT a
      -- frame count, so clamp how many frames of this block fall inside our
      -- analysis window ourselves.
      local frames_in_range = math.min(block_frames, math.floor((end_pos - pos) * samplerate))
      if frames_in_range > 0 then
        local buf = samplebuffer.table()
        for f = 0, frames_in_range - 1 do
          local l = buf[f * num_channels + 1]
          local r = buf[f * num_channels + 2]
          sum_l  = sum_l  + l
          sum_r  = sum_r  + r
          sum_l2 = sum_l2 + l * l
          sum_r2 = sum_r2 + r * r
          sum_lr = sum_lr + l * r
          n = n + 1
        end
      end
    end
    pos = pos + (block_frames / samplerate)
  end

  reaper.DestroyAudioAccessor(accessor)

  if n < 2 then return nil end

  local denom_l = n * sum_l2 - sum_l * sum_l
  local denom_r = n * sum_r2 - sum_r * sum_r
  local denom = math.sqrt(denom_l * denom_r)
  if denom == 0 then
    -- Both channels constant (e.g. silence/DC): identical constants = fully
    -- correlated, differing constants = uncorrelated.
    return (denom_l == 0 and denom_r == 0) and 1.0 or 0.0
  end
  return (n * sum_lr - sum_l * sum_r) / denom
end

-- ============================================================
-- Bootstrap: seed a Default template on first run
-- ============================================================
local function bootstrap_default_template()
  ensure_tpl_dir()
  local t = {}
  for k, v in pairs(DEFAULTS) do t[k] = v end

  -- Seed from existing user config file if it exists
  local config_path = script_dir .. "Smart Export Selected Items - User Config.lua"
  if reaper.file_exists(config_path) then
    local cfg = load_template_file(config_path)
    if cfg then
      t.render_output_dir     = cfg.render_output_dir     or t.render_output_dir
      t.render_output_pattern = cfg.render_output_pattern or t.render_output_pattern
    end
  end

  save_template(t)
  return t
end

-- ============================================================
-- Render settings + export
-- ============================================================
-- Base64-encoded RENDER_FORMAT blobs for WAV output at each supported bit
-- depth. Layout (per Ultraschall's documented REAPER render-config format):
-- bytes 1-4 "evaw" (WAV fourCC reversed), byte 5 = bit depth (16/24/32,
-- where 32 means 32-bit float per REAPER's own WAV encoder), byte 6 = 0x06
-- (BWF chunk + project filename in BWF data), byte 7 = 0 (force WAV, not
-- RF64/Wave64). Only byte 5 varies with bit depth; bytes 6-7 match this
-- script's original fixed 24-bit default so behavior otherwise doesn't change.
local RENDER_FORMAT_BLOBS = {
  [16] = "ZXZhdxAGAA==",
  [24] = "ZXZhdxgGAA==",
  [32] = "ZXZhdyAGAA==",
}

local SAMPLE_RATE_OPTIONS = {44100, 48000, 88200, 96000, 176400, 192000}
local BIT_DEPTH_OPTIONS = {16, 24, 32}
local BIT_DEPTH_LABELS = {[16] = "16-bit", [24] = "24-bit", [32] = "32-bit Float"}

local function apply_render_settings(t)
  local SETTINGS_MASK = 0x7FFF
  -- multichannel tracks to multichannel files (0x4) + mono media to mono files (0x10)
  -- + embed metadata (0x200)
  local BASE_RENDER_SETTINGS = 0x4 | 0x10 | 0x200
  local SOURCE_SELECTED_ITEMS             = 0x20  -- selected media items
  local SOURCE_SELECTED_ITEMS_VIA_MASTER  = 0x40  -- selected media items via master
  local SECOND_PASS_RENDER                = 0x800 -- 2nd pass render
  local source_bit = t.render_via_master and SOURCE_SELECTED_ITEMS_VIA_MASTER or SOURCE_SELECTED_ITEMS
  local render_settings = BASE_RENDER_SETTINGS | source_bit
  if t.second_pass_render then render_settings = render_settings | SECOND_PASS_RENDER end

  local format_blob = RENDER_FORMAT_BLOBS[t.bit_depth] or RENDER_FORMAT_BLOBS[24]
  reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT',  format_blob, true)
  reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT2', '',             true)
  reaper.GetSetProjectInfo(0, 'RENDER_SRATE',    t.sample_rate, true)
  reaper.GetSetProjectInfo(0, 'RENDER_CHANNELS', 2,     true)
  reaper.GetSetProjectInfo(0, 'RENDER_DITHER',   0,     true)

  local cur = reaper.GetSetProjectInfo(0, 'RENDER_SETTINGS', 0, false)
  reaper.GetSetProjectInfo(0, 'RENDER_SETTINGS',
    (render_settings & SETTINGS_MASK) | (cur & ~SETTINGS_MASK), true)

  reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 4,        true)
  reaper.GetSetProjectInfo(0, 'RENDER_STARTPOS',   0,        true)
  reaper.GetSetProjectInfo(0, 'RENDER_ENDPOS',     0,        true)
  reaper.GetSetProjectInfo(0, 'RENDER_TAILFLAG',   0,        true)
  reaper.GetSetProjectInfo(0, 'RENDER_TAILMS',     t.tail_ms, true)

  reaper.GetSetProjectInfo(0, 'RENDER_NORMALIZE',        normalize_bits(t),                  true)
  reaper.GetSetProjectInfo(0, 'RENDER_NORMALIZE_TARGET', db_to_linear(t.normalize_target_db), true)
  reaper.GetSetProjectInfo(0, 'RENDER_BRICKWALL', 1, true)

  reaper.GetSetProjectInfo(0, 'RENDER_FADEIN',       0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEOUT',      0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEINSHAPE',  1, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEOUTSHAPE', 1, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TRIMSTART',    0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TRIMEND',      0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_PADSTART',     0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_PADEND',       0, true)

  reaper.GetSetProjectInfo_String(0, 'RENDER_FILE',    t.render_output_dir,     true)
  reaper.GetSetProjectInfo_String(0, 'RENDER_PATTERN', t.render_output_pattern, true)

  reaper.SNM_SetIntConfigVar('projrenderlimit',        0)
  reaper.SNM_SetIntConfigVar('projrenderrateinternal', 1)
  reaper.SNM_SetIntConfigVar('projrenderresample',     10)
end

local function run_export(t)
  local num_selected = reaper.CountSelectedMediaItems(0)
  if num_selected == 0 then
    reaper.ShowMessageBox('No media items selected.', 'Error', 0)
    return
  end

  reaper.Undo_BeginBlock()  -- moved earlier so chanmode writes below are bundled

  local selected_guids = {}
  for i = 0, num_selected - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    table.insert(selected_guids, reaper.BR_GetMediaItemGUID(item))
  end

  local item_list = {}
  local mismatches = {}
  for i = 0, num_selected - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local source = reaper.GetMediaItemTake_Source(take)
      local src_ch = reaper.GetMediaSourceNumChannels(source)
      local track = reaper.GetMediaItem_Track(item)
      local trk_ch = track and reaper.GetMediaTrackInfo_Value(track, "I_NCHAN") or 0
      if src_ch > 2 and trk_ch ~= src_ch then
        local _, trk_name = reaper.GetTrackName(track)
        trk_name = (trk_name ~= "" and trk_name) or "(unnamed track)"
        local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        take_name = (take_name ~= "" and take_name) or "(untitled take)"
        table.insert(mismatches, ("Track '%s' has %d ch, item '%s' has %d ch."):format(
          trk_name, trk_ch, take_name, src_ch))
      end
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

      if t.mono_downmix_enabled and src_ch == 2 then
        local corr = compute_stereo_correlation(take)
        if CORRELATION_DEBUG_LOG then
          local _, dbg_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
          reaper.ShowConsoleMsg(string.format(
            "[Smart Export] '%s' @ %.3fs: correlation = %s (threshold %.2f)%s\n",
            dbg_name ~= "" and dbg_name or "(untitled take)",
            pos,
            corr and string.format("%.4f", corr) or "nil (accessor/analysis failed)",
            t.mono_downmix_threshold,
            (corr and corr >= t.mono_downmix_threshold) and "  -> DOWNMIXING TO MONO" or ""
          ))
        end
        if corr and corr >= t.mono_downmix_threshold then
          local chanmode = MONO_DOWNMIX_CHANMODE[t.mono_downmix_mode] or MONO_DOWNMIX_CHANMODE.left
          reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", chanmode)
        end
      end

      local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      table.insert(item_list, {
        item = item, take = take,
        start_pos = pos, end_pos = pos + len,
        name = name, source_num_channels = src_ch,
      })
    else
      reaper.ShowMessageBox(
        'No active take or take is MIDI for item at position '
          .. reaper.GetMediaItemInfo_Value(item, 'D_POSITION'), 'Error', 0)
    end
  end

  if #mismatches > 0 then
    reaper.ShowMessageBox(
      table.concat(mismatches, "\n")
        .. "\n\nSet the track channel count to match multichannel items before exporting.",
      "Item/Track Channel Mismatch", 0)
    reaper.Undo_EndBlock('Smart Render Selected Items (aborted)', -1)
    return
  end

  local by_name = {}
  for _, info in ipairs(item_list) do
    local n = info.name or ""
    if not by_name[n] then by_name[n] = {} end
    table.insert(by_name[n], info)
  end

  local overlap_groups, solo_items = {}, {}
  for _, items in pairs(by_name) do
    local checked = {}
    for i, a in ipairs(items) do
      if not checked[a] then
        local grp = {a}; checked[a] = true
        for j = i + 1, #items do
          local b = items[j]
          if not checked[b] and a.start_pos < b.end_pos and b.start_pos < a.end_pos then
            table.insert(grp, b); checked[b] = true
          end
        end
        if #grp > 1 then table.insert(overlap_groups, grp)
        else              table.insert(solo_items, a) end
      end
    end
  end

  for _, grp in ipairs(overlap_groups) do
    reaper.Main_OnCommand(40289, 0)
    for _, info in ipairs(grp) do reaper.SetMediaItemSelected(info.item, true) end
    reaper.Main_OnCommand(41588, 0)
    local glued = reaper.GetSelectedMediaItem(0, 0)
    if glued then
      local glued_take = reaper.GetActiveTake(glued)
      reaper.GetSetMediaItemTakeInfo_String(glued_take, "P_NAME", grp[1].name, true)
      apply_render_settings(t)
      reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true)
      reaper.Main_OnCommand(41824, 0)
      reaper.Undo_DoUndo2(0)
    end
  end

  if #solo_items > 0 then
    apply_render_settings(t)
    reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true)
    reaper.Main_OnCommand(40289, 0)
    for _, info in ipairs(solo_items) do reaper.SetMediaItemSelected(info.item, true) end
    reaper.Main_OnCommand(41824, 0)
  end

  reaper.Main_OnCommand(40289, 0)
  for _, guid in ipairs(selected_guids) do
    local item = reaper.BR_GetMediaItemByGUID(0, guid)
    if item then reaper.SetMediaItemSelected(item, true) end
  end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Smart Render Selected Items', -1)
end

-- ============================================================
-- Export path preview
-- Approximates how $item/$project/$projectpath/$user/$date will
-- resolve, for display only -- REAPER itself resolves the real
-- render pattern at render time.
-- ============================================================
local PATH_SEP = reaper.GetOS():find("Win") and "\\" or "/"
local PREVIEW_MAX_ROWS = 25

local function get_preview_project_tokens()
  local proj_fn = reaper.GetProjectName(0, "")
  local proj_name = proj_fn ~= "" and (proj_fn:gsub("%.[Rr][Pp][Pp]$", "")) or "untitled"
  local proj_path = reaper.GetProjectPath()
  return proj_name, proj_path
end

local function resolve_preview_pattern(pattern, item_name)
  local proj_name, proj_path = get_preview_project_tokens()
  local user = os.getenv("USER") or os.getenv("USERNAME") or ""
  local date = os.date("%Y-%m-%d")
  local resolved = pattern
  resolved = resolved:gsub("%$projectpath", (proj_path:gsub("%%", "%%%%")))
  resolved = resolved:gsub("%$project",     (proj_name:gsub("%%", "%%%%")))
  resolved = resolved:gsub("%$item",        (item_name:gsub("%%", "%%%%")))
  resolved = resolved:gsub("%$user",        (user:gsub("%%", "%%%%")))
  resolved = resolved:gsub("%$date",        date)
  return resolved
end

local function get_selected_item_infos()
  local infos = {}
  local n = reaper.CountSelectedMediaItems(0)
  for i = 0, n - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      local source = reaper.GetMediaItemTake_Source(take)
      table.insert(infos, {
        name   = name ~= "" and name or "(untitled take)",
        take   = take,
        src_ch = source and reaper.GetMediaSourceNumChannels(source) or 0,
        guid   = reaper.BR_GetMediaItemGUID(item),
      })
    end
  end
  return infos
end

-- Abbreviates a resolved directory to "…/<parent>/<last>/" so preview rows
-- stay short without wrapping (matches the design's ellipsis-truncated dir).
local function shorten_dir_for_preview(dir)
  local segments = {}
  for seg in dir:gmatch("[^/\\]+") do segments[#segments + 1] = seg end
  if #segments == 0 then return "" end
  local tail_n = math.min(2, #segments)
  local parts = {}
  for i = #segments - tail_n + 1, #segments do parts[#parts + 1] = segments[i] end
  return "\u{2026}" .. PATH_SEP .. table.concat(parts, PATH_SEP) .. PATH_SEP
end

-- Mono-downmix prediction cache: correlation analysis is real audio work
-- (CreateTakeAudioAccessor + block reads), so it's only recomputed when the
-- previewed selection/threshold actually change, and only for the rows
-- actually shown (PREVIEW_MAX_ROWS) -- never every frame, and never for a
-- huge selection -- so the live preview can't hitch.
local preview_mono_sig   = nil
local preview_mono_cache = {}

local function get_preview_mono_flags(infos, mono_en, threshold)
  if not mono_en then return {} end
  local sig_parts = { tostring(threshold) }
  for i = 1, math.min(#infos, PREVIEW_MAX_ROWS) do
    sig_parts[#sig_parts + 1] = infos[i].guid
  end
  local sig = table.concat(sig_parts, "|")
  if sig == preview_mono_sig then return preview_mono_cache end

  local flags = {}
  for i = 1, math.min(#infos, PREVIEW_MAX_ROWS) do
    local info = infos[i]
    if info.src_ch == 2 then
      local corr = compute_stereo_correlation(info.take)
      flags[i] = corr ~= nil and corr >= threshold
    else
      flags[i] = false
    end
  end
  preview_mono_sig   = sig
  preview_mono_cache = flags
  return flags
end

-- Splits a full resolved path into (dir, filename+ext) on the last separator
-- -- the resolved pattern can itself contain separators (e.g. the default
-- "$project\$item" pattern nests into a subfolder), and REAPER render
-- patterns may mix '/' and '\' regardless of OS.
local function split_preview_path(full_path)
  local last_sep = nil
  for j = #full_path, 1, -1 do
    local c = full_path:sub(j, j)
    if c == "/" or c == "\\" then last_sep = j break end
  end
  if not last_sep then return "", full_path end
  return full_path:sub(1, last_sep - 1), full_path:sub(last_sep + 1)
end

-- Returns (rows, total_item_count, mono_total) where rows is capped at
-- PREVIEW_MAX_ROWS. Each row is {dir_short, filename, ext, ch} where ch is
-- the channel count the exported file is expected to have -- 1 if the mono
-- downmix prediction applies, otherwise the source's own channel count.
local function build_preview_rows(dir, pattern, mono_en, threshold)
  local resolved_dir = dir ~= "" and dir or reaper.GetProjectPath()
  local infos = get_selected_item_infos()
  local mono_flags = get_preview_mono_flags(infos, mono_en, threshold)

  local rows = {}
  local mono_total = 0
  for i = 1, math.min(#infos, PREVIEW_MAX_ROWS) do
    local info = infos[i]
    local full_path = resolved_dir .. PATH_SEP .. resolve_preview_pattern(pattern, info.name) .. ".wav"
    local dir_part, file_part = split_preview_path(full_path)
    local fname, ext = file_part:match("^(.-)(%.[^.]*)$")
    local is_mono = mono_flags[i] or false
    if is_mono then mono_total = mono_total + 1 end
    table.insert(rows, {
      dir_short = shorten_dir_for_preview(dir_part),
      filename  = fname or file_part,
      ext       = ext or "",
      ch        = is_mono and 1 or (info.src_ch > 0 and info.src_ch or 2),
    })
  end

  return rows, #infos, mono_total
end

-- Channel-count chip styling (text color, border color) per output channel
-- count -- purple/blue/orange/green/yellow for mono/stereo/quad/5.1/7.1,
-- with a neutral gray fallback for anything else. Rendered via the shared
-- theme.Chip primitive.
local CHANNEL_CHIP_STYLES = {
  [1] = { label = "MONO",   text = 0xA08FE2FF, border = 0x4A4160FF },
  [2] = { label = "STEREO", text = 0x6FA8E8FF, border = 0x2E3F58FF },
  [4] = { label = "QUAD",   text = 0xE2A25FFF, border = 0x5A4530FF },
  [6] = { label = "5.1",    text = 0x7FC98CFF, border = 0x33472FFF },
  [8] = { label = "7.1",    text = 0xE0D46AFF, border = 0x55502AFF },
}

local function channel_chip_style(ch)
  return CHANNEL_CHIP_STYLES[ch] or { label = ch .. "CH", text = 0xA0A0A0FF, border = 0x3A3F45FF }
end

-- ============================================================
-- ImGui context
-- ============================================================
local script_title = "SMART EXPORT ITEMS"
local ctx = ImGui.CreateContext(script_title)

local mono_font_name = reaper.GetOS():find("Win") and "Consolas" or "Menlo"
local mono_font = ImGui.CreateFont(mono_font_name, 13)
ImGui.Attach(ctx, mono_font)

local WIN_FLAGS = ImGui.WindowFlags_NoCollapse

-- ============================================================
-- Template state
-- ============================================================
local templates     = {}
local active_idx    = 1

-- Live edit buffers (synced from/to active template)
local dir_buf         = ""
local pattern_buf     = ""
local norm_en         = false
local norm_mode       = "lufs_i"
local norm_db_buf     = "-24.0"
local sample_rate     = 96000
local bit_depth       = 24
local tail_buf        = "0"
local mono_downmix_en = true
local mono_thresh_buf = "0.9"
local mono_downmix_mode = "left"
local open_folder_en  = false
local render_via_master_en = true
local second_pass_render_en = false
local close_after_render_en = true

-- Rename modal state
local rename_pending    = false
local rename_focus_next = false  -- call SetKeyboardFocusHere exactly once when modal opens
local rename_idx        = 1
local rename_buf        = ""
local rename_dup_err    = false

-- Pending delete (deferred one frame to avoid mid-render table mutation)
local delete_pending = false
local delete_idx     = 1

local last_active_idx = 0  -- sentinel; forces first-frame buffer sync
local open = true

-- Height of the left rail's "status text + Render button" footer block,
-- measured one frame late so the spacer above it can push it flush to the
-- bottom of the rail (matches the design, where Render always sits at the
-- rail's bottom edge regardless of window height).
local left_footer_h = 0

-- ============================================================
-- Buffer helpers
-- ============================================================
local function sync_buffers_from(t)
  dir_buf         = t.render_output_dir
  pattern_buf     = t.render_output_pattern
  norm_en         = t.normalize_enabled
  norm_mode       = t.normalize_mode
  norm_db_buf     = tostring(t.normalize_target_db)
  sample_rate     = t.sample_rate
  bit_depth       = t.bit_depth
  tail_buf        = tostring(t.tail_ms)
  mono_downmix_en   = t.mono_downmix_enabled
  mono_thresh_buf   = tostring(t.mono_downmix_threshold)
  mono_downmix_mode = t.mono_downmix_mode
  open_folder_en    = t.open_folder_after
  render_via_master_en = t.render_via_master
  second_pass_render_en = t.second_pass_render
  close_after_render_en = t.close_after_render
end

local function flush_buffers_to(t)
  t.render_output_dir      = dir_buf
  t.render_output_pattern  = pattern_buf
  t.normalize_enabled      = norm_en
  t.normalize_mode         = norm_mode
  t.normalize_target_db    = tonumber(norm_db_buf)   or t.normalize_target_db
  t.sample_rate            = sample_rate
  t.bit_depth              = bit_depth
  t.tail_ms                = tonumber(tail_buf)      or t.tail_ms
  t.mono_downmix_enabled   = mono_downmix_en
  t.mono_downmix_threshold = tonumber(mono_thresh_buf) or t.mono_downmix_threshold
  t.mono_downmix_mode      = mono_downmix_mode
  t.open_folder_after      = open_folder_en
  t.render_via_master      = render_via_master_en
  t.second_pass_render     = second_pass_render_en
  t.close_after_render     = close_after_render_en
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

  local saved_name = reaper.GetExtState("SmartExport", "active_template")
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
  -- Flatten the active tab into the panel below it (instead of the shared
  -- theme's teal fill, which never actually applied here -- see below) with
  -- a purple accent line on top, closer to the design's minimal tab
  -- treatment. Scoped to this script only.
  --
  -- This build of ReaImGui renamed the tab color enums (Col_TabActive ->
  -- Col_TabSelected, Col_TabUnfocused -> Col_TabDimmed, etc.) and added a
  -- native Col_TabSelectedOverline for the accent line -- ReaImGuiTheme.lua
  -- still pushes the *old* names via the same rawget guard used here, which
  -- means they've been silently no-op'ing and every tab has been rendering
  -- in Dear ImGui's default blue. Try the current name first, fall back to
  -- the old one for older ReaImGui installs.
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

  local WIN_W = 920
  ImGui.SetNextWindowSizeConstraints(ctx, 600, 0, 3000, 10000)
  ImGui.SetNextWindowSize(ctx, WIN_W, 0, ImGui.Cond_FirstUseEver)
  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then

    -- ── Tab bar ─────────────────────────────────────────────
    if ImGui.BeginTabBar(ctx, "##templates", ImGui.TabBarFlags_AutoSelectNewTabs) then

      for i, t in ipairs(templates) do
        -- tab_visible = this tab's content should be drawn this frame
        -- new_open    = false when the user clicks the × close button
        local tab_visible, new_open = ImGui.BeginTabItem(ctx, t.name, true, 0)

        -- GetItemRectMin/Max here refer to the tab item itself, so both
        -- accent draws below must run immediately after BeginTabItem.
        local tab_min_x, tab_min_y = ImGui.GetItemRectMin(ctx)
        local tab_max_x, tab_max_y = ImGui.GetItemRectMax(ctx)
        local draw_list = ImGui.GetWindowDrawList(ctx)

        -- Per-template custom color: a thin bar along the tab's left edge,
        -- visible whether or not the tab is active, so templates stay
        -- identifiable by color even when not selected.
        if t.tab_color ~= 0 then
          ImGui.DrawList_AddRectFilled(draw_list, tab_min_x, tab_min_y, tab_min_x + 3, tab_max_y, t.tab_color)
        end

        -- Accent top-border on the active tab -- only needed as a fallback
        -- when this ReaImGui build has no native Col_TabSelectedOverline
        -- (pushed above), which already draws this for us.
        if tab_visible and not col_tab_overline then
          ImGui.DrawList_AddRectFilled(draw_list, tab_min_x, tab_min_y, tab_max_x, tab_min_y + 2, 0xA08FE2FF)
        end

        -- Right-click → context menu (must be called right after BeginTabItem)
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

        -- Handle close-button click (× on the tab)
        if not new_open and #templates > 1 then
          delete_pending = true
          delete_idx     = i
        end

        if tab_visible then
          -- Switching tabs: flush old, sync new
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

      -- "+" button: create a new template (TabItemButton = clickable, doesn't steal content area)
      if ImGui.TabItemButton(ctx, "+", ImGui.TabItemFlags_Trailing) then
        flush_buffers_to(templates[active_idx])

        local base = "New Template"
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

        -- Open rename modal immediately so the user can name it
        rename_pending    = true
        rename_focus_next = true
        rename_idx        = active_idx
        rename_buf        = new_name
        rename_dup_err    = false
      end

      ImGui.EndTabBar(ctx)
    end

    -- ── Left column: settings rail ───────────────────────────
    local LEFT_COL_W = 240
    local CTL_W       = 150  -- fixed control width; label column stretches to fill the rest

    -- avail_h is "from here to the bottom of the window at its current size"
    -- -- used to stretch both the rail background and the field/footer split
    -- all the way down, instead of just wrapping tightly around content.
    local _, avail_h = ImGui.GetContentRegionAvail(ctx)
    local lx0, ly0 = ImGui.GetCursorScreenPos(ctx)
    do
      local draw_list = ImGui.GetWindowDrawList(ctx)
      ImGui.DrawList_AddRectFilled(draw_list, lx0, ly0, lx0 + LEFT_COL_W, ly0 + avail_h, 0x222222FF, 4)
    end

    ImGui.BeginGroup(ctx)

    -- outer_size_w pins each table to LEFT_COL_W -- without it, a table with
    -- a WidthStretch column stretches to fill the *whole window* (a
    -- BeginGroup doesn't constrain child width), shoving the right column
    -- off past the window edge and making the preview text wrap to
    -- near-zero width.
    local function begin_field_table(id)
      local ok = ImGui.BeginTable(ctx, id, 2, 0, LEFT_COL_W, 0)
      if ok then
        ImGui.TableSetupColumn(ctx, "##ctl",   ImGui.TableColumnFlags_WidthFixed, CTL_W)
        ImGui.TableSetupColumn(ctx, "##label", ImGui.TableColumnFlags_WidthStretch)
      end
      return ok
    end

    -- NORMALIZE section
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xC8C8C8FF)
    local _, new_norm_en = ImGui.Checkbox(ctx, "NORMALIZE", norm_en)
    ImGui.PopStyleColor(ctx)
    norm_en = new_norm_en

    if not norm_en then ImGui.BeginDisabled(ctx, true) end
    if begin_field_table("##norm_fields") then
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local mode_label = norm_mode == "lufs_m" and "LUFS-M" or "LUFS-I"
      ImGui.SetNextItemWidth(ctx, -1)
      if ImGui.BeginCombo(ctx, "##norm_mode", mode_label, 0) then
        if ImGui.Selectable(ctx, "LUFS-I", norm_mode == "lufs_i", 0) then norm_mode = "lufs_i" end
        if ImGui.Selectable(ctx, "LUFS-M", norm_mode == "lufs_m", 0) then norm_mode = "lufs_m" end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Mode")

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, new_db = ImGui.InputText(ctx, "##norm_db", norm_db_buf,
        ImGui.InputTextFlags_CharsDecimal)
      norm_db_buf = new_db
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Target dB")

      ImGui.EndTable(ctx)
    end
    if not norm_en then ImGui.EndDisabled(ctx) end

    ImGui.Spacing(ctx)

    -- MONO DOWNMIX section
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xC8C8C8FF)
    local _, new_mono_en = ImGui.Checkbox(ctx, "MONO DOWNMIX", mono_downmix_en)
    ImGui.PopStyleColor(ctx)
    mono_downmix_en = new_mono_en
    if ImGui.IsItemHovered(ctx) then
      ImGui.BeginTooltip(ctx)
      ImGui.PushTextWrapPos(ctx, ImGui.GetFontSize(ctx) * 30)
      ImGui.Text(ctx,
        "Before export, checks each stereo item's L/R correlation. If it meets or "
        .. "exceeds the threshold (channels are near-identical, e.g. a mono source "
        .. "recorded to a stereo pair), the take's channel mode is switched to the "
        .. "selected mono option below so it renders as mono instead of true stereo.")
      ImGui.PopTextWrapPos(ctx)
      ImGui.EndTooltip(ctx)
    end

    if not mono_downmix_en then ImGui.BeginDisabled(ctx, true) end
    if begin_field_table("##mono_fields") then
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, new_thresh = ImGui.InputText(ctx, "##mono_thresh", mono_thresh_buf,
        ImGui.InputTextFlags_CharsDecimal)
      mono_thresh_buf = new_thresh
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Threshold")

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local mono_mode_label = ({
        left    = "Take Left Channel",
        right   = "Take Right Channel",
        downmix = "Downmix",
      })[mono_downmix_mode] or "Take Left Channel"
      ImGui.SetNextItemWidth(ctx, -1)
      if ImGui.BeginCombo(ctx, "##mono_mode", mono_mode_label, 0) then
        if ImGui.Selectable(ctx, "Take Left Channel",  mono_downmix_mode == "left",    0) then mono_downmix_mode = "left"    end
        if ImGui.Selectable(ctx, "Take Right Channel", mono_downmix_mode == "right",   0) then mono_downmix_mode = "right"   end
        if ImGui.Selectable(ctx, "Downmix",            mono_downmix_mode == "downmix", 0) then mono_downmix_mode = "downmix" end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Mode")

      ImGui.EndTable(ctx)
    end
    if not mono_downmix_en then ImGui.EndDisabled(ctx) end

    ImGui.Spacing(ctx)

    -- RENDER section (plain divider -- not a toggle)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, "RENDER")
    ImGui.PopStyleColor(ctx)

    if begin_field_table("##render_fields") then
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      if ImGui.BeginCombo(ctx, "##sample_rate", ("%d Hz"):format(sample_rate), 0) then
        for _, sr in ipairs(SAMPLE_RATE_OPTIONS) do
          if ImGui.Selectable(ctx, ("%d Hz"):format(sr), sample_rate == sr, 0) then sample_rate = sr end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Sample Rate")

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      if ImGui.BeginCombo(ctx, "##bit_depth", BIT_DEPTH_LABELS[bit_depth] or (bit_depth .. "-bit"), 0) then
        for _, bd in ipairs(BIT_DEPTH_OPTIONS) do
          if ImGui.Selectable(ctx, BIT_DEPTH_LABELS[bd], bit_depth == bd, 0) then bit_depth = bd end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Bit Depth")

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, new_tail = ImGui.InputText(ctx, "##tail", tail_buf,
        ImGui.InputTextFlags_CharsDecimal)
      tail_buf = new_tail
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Tail (ms)")

      ImGui.EndTable(ctx)
    end

    local _, new_via_master = ImGui.Checkbox(ctx, "Render via Master", render_via_master_en)
    render_via_master_en = new_via_master
    if ImGui.IsItemHovered(ctx) then
      ImGui.BeginTooltip(ctx)
      ImGui.PushTextWrapPos(ctx, ImGui.GetFontSize(ctx) * 30)
      ImGui.Text(ctx,
        "When checked, selected items are rendered through the master bus (and any "
        .. "master track processing/FX). When unchecked, items are rendered directly, "
        .. "bypassing the master bus.")
      ImGui.PopTextWrapPos(ctx)
      ImGui.EndTooltip(ctx)
    end

    local _, new_second_pass_render_en = ImGui.Checkbox(ctx, "2nd Pass Render", second_pass_render_en)
    second_pass_render_en = new_second_pass_render_en
    if ImGui.IsItemHovered(ctx) then
      ImGui.BeginTooltip(ctx)
      ImGui.PushTextWrapPos(ctx, ImGui.GetFontSize(ctx) * 30)
      ImGui.Text(ctx,
        "Renders each item twice and keeps the second pass. Fixes plugins with lookahead "
        .. "or adaptive processing that sound different (or wrong) on a cold first render.")
      ImGui.PopTextWrapPos(ctx)
      ImGui.EndTooltip(ctx)
    end

    local _, new_open_folder_en = ImGui.Checkbox(ctx, "Open Folder After Render", open_folder_en)
    open_folder_en = new_open_folder_en

    local _, new_close_after_render_en = ImGui.Checkbox(ctx, "Close Smart Export After Render", close_after_render_en)
    close_after_render_en = new_close_after_render_en

    -- Spacer pushes the Render button + status flush to the rail's bottom
    -- edge (matches the design, where Render always sits at the bottom
    -- regardless of window height) using last frame's measured footer
    -- height -- known up front this frame, unlike the old right-panel tint,
    -- so no one-frame lag is visible here.
    local n_items = reaper.CountSelectedMediaItems(0)
    local _, fields_bottom_y = ImGui.GetCursorScreenPos(ctx)
    local spacer_h = avail_h - (fields_bottom_y - ly0) - left_footer_h
    if spacer_h > 0 then ImGui.Dummy(ctx, 0, spacer_h) end

    local _, footer_top_y = ImGui.GetCursorScreenPos(ctx)

    -- Separator above the Render button -- drawn manually at LEFT_COL_W
    -- rather than via ImGui.Separator(), which (like Button/Table before it)
    -- spans the *window's* full content width inside a bare BeginGroup, not
    -- the rail's intended width.
    ImGui.Spacing(ctx)
    do
      local sx, sy = ImGui.GetCursorScreenPos(ctx)
      local draw_list = ImGui.GetWindowDrawList(ctx)
      ImGui.DrawList_AddRectFilled(draw_list, sx, sy, sx + LEFT_COL_W, sy + 1, 0x3A3F45FF)
    end
    ImGui.Dummy(ctx, 0, 1)
    ImGui.Spacing(ctx)

    -- Render button -- only the click is captured here; the actual
    -- run_export() call is deferred until after the right column has been
    -- fully drawn, so REAPER's native render engine never runs mid-frame
    -- with more ImGui widgets still queued behind it.
    local no_items = n_items == 0
    if no_items then ImGui.BeginDisabled(ctx, true) end
    local BTN_PAD_X = 4
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + BTN_PAD_X)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0xA08FE2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0xB3A6E8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x8D7ACCFF)
    ImGui.PushFont(ctx, nil, ImGui.GetFontSize(ctx) * 1.3)
    local do_render = ImGui.Button(ctx, "Render", LEFT_COL_W - BTN_PAD_X * 2, 0)
      or (not no_items and (
            ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
            or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)))
    ImGui.PopFont(ctx)
    ImGui.PopStyleColor(ctx, 3)
    if no_items then ImGui.EndDisabled(ctx) end

    local status_text = ("%d %s selected"):format(n_items, n_items == 1 and "item" or "items")
    local status_w = ImGui.CalcTextSize(ctx, status_text)
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + (LEFT_COL_W - status_w) / 2)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, status_text)
    ImGui.PopStyleColor(ctx)

    local _, footer_bottom_y = ImGui.GetCursorScreenPos(ctx)
    left_footer_h = footer_bottom_y - footer_top_y

    ImGui.EndGroup(ctx)

    -- ── Right column: output dir/filename + live preview ────
    ImGui.SameLine(ctx, 0, 20)

    ImGui.BeginGroup(ctx)

    local has_browse = reaper.JS_Dialog_BrowseForFolder ~= nil

    -- Directory / File name rows -- input | action button | right-aligned
    -- label, sized to whatever width remains in the window (no outer_size_w:
    -- unlike the left column's tables, nothing follows this on the line, so
    -- "available width" here already stops at the window edge).
    if ImGui.BeginTable(ctx, "##right_top", 3) then
      ImGui.TableSetupColumn(ctx, "##input", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableSetupColumn(ctx, "##btn",   ImGui.TableColumnFlags_WidthFixed, 80)
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
        if ImGui.Button(ctx, "Browse\u{2026}", -1, 0) then
          local ok, folder = reaper.JS_Dialog_BrowseForFolder("Select Export Folder", dir_buf)
          if ok == 1 then dir_buf = folder end
        end
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
      if ImGui.Button(ctx, "Wildcards", -1, 0) then
        ImGui.OpenPopup(ctx, "##wildcards_popup")
      end
      if ImGui.BeginPopup(ctx, "##wildcards_popup") then
        for _, tok in ipairs({"$item", "$project", "$projectpath", "$user", "$date"}) do
          if ImGui.Selectable(ctx, tok, false, 0) then
            pattern_buf = pattern_buf .. tok
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

    local mono_threshold = tonumber(mono_thresh_buf) or 0.9
    local preview_rows, preview_total, preview_mono_total =
      build_preview_rows(dir_buf, pattern_buf, mono_downmix_en, mono_threshold)

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, "RESOLVED PATHS")
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x6E6E6EFF)
    local count_str = tostring(preview_total)
    if mono_downmix_en and preview_mono_total > 0 then
      count_str = ("%s  \u{00B7}  %d will downmix to mono"):format(count_str, preview_mono_total)
    end
    ImGui.Text(ctx, count_str)
    ImGui.PopStyleColor(ctx)

    -- Plain in-window rows (not a child window) -- avoids nesting a
    -- BeginChild/EndChild pair, which triggered a ReaImGui window-stack
    -- assertion here. Directories are abbreviated (shorten_dir_for_preview)
    -- rather than wrapped, so mixed-color rows never need to wrap mid-line.
    if #preview_rows == 0 then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
      ImGui.Text(ctx, "No items selected.")
      ImGui.PopStyleColor(ctx)
    else
      for _, row in ipairs(preview_rows) do
        ImGui.PushFont(ctx, mono_font, 13)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
        ImGui.Text(ctx, row.dir_short)
        ImGui.PopStyleColor(ctx)
        ImGui.SameLine(ctx, 0, 0)
        ImGui.Text(ctx, row.filename)
        ImGui.SameLine(ctx, 0, 0)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
        ImGui.Text(ctx, row.ext)
        ImGui.PopStyleColor(ctx)
        ImGui.PopFont(ctx)
        ImGui.SameLine(ctx)
        local chip = channel_chip_style(row.ch)
        theme.Chip(ctx, chip.label, chip.text, chip.border)
      end
      if preview_total > #preview_rows then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
        ImGui.Text(ctx, ("...and %d more"):format(preview_total - #preview_rows))
        ImGui.PopStyleColor(ctx)
      end
    end

    ImGui.EndGroup(ctx)

    -- The actual render call, deferred until every other widget this frame
    -- (including everything in the right column above) has already been
    -- drawn -- see the Render button comment in the left column above.
    if do_render then
      flush_buffers_to(templates[active_idx])
      local t = templates[active_idx]
      save_template(t)
      reaper.SetExtState("SmartExport", "active_template", t.name, true)
      if t.close_after_render then open = false end
      run_export(t)
      if t.open_folder_after then
        local folder = t.render_output_dir ~= "" and t.render_output_dir or reaper.GetProjectPath()
        reaper.CF_ShellExecute(folder)
      end
    end

    ImGui.End(ctx)
  end

  -- ── Rename modal ─────────────────────────────────────────
  if rename_pending then
    ImGui.OpenPopup(ctx, "Rename Template##modal")
    rename_pending    = false
    rename_focus_next = true
  end

  if ImGui.BeginPopupModal(ctx, "Rename Template##modal", nil,
      ImGui.WindowFlags_AlwaysAutoResize) then
    ImGui.Text(ctx, "Template name:")
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
          -- If this was the active template, update ExtState
          if rename_idx == active_idx then
            reaper.SetExtState("SmartExport", "active_template", rename_buf, true)
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
      ('Delete template "%s"? This cannot be undone.'):format(name),
      "Smart Export", 4)  -- 4 = Yes/No buttons
    if answer == 6 then   -- 6 = Yes
      delete_template(name)
      table.remove(templates, delete_idx)
      if active_idx > delete_idx then
        active_idx = active_idx - 1
      end
      active_idx      = math.max(1, math.min(active_idx, #templates))
      last_active_idx = 0  -- force buffer resync next frame
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
