-- @description Smart Export Selected Items (GUI)
-- @version 1.36
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
--   08/22/26 v1.36 - Moved the Render button's purple/bold/oversized style
--                    into the shared theme as theme.PrimaryButton(ctx,
--                    label, width, height) (ReaImGuiTheme.lua v1.7), so
--                    other scripts can reuse the same "main action" button
--                    look. Render button here now just calls it.

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
  render_format          = "wav",
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
  f:write("render_format         = " .. string.format("%q", t.render_format)         .. "\n")
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
-- Render format registry. RENDER_FORMAT blob layout is per Ultraschall's
-- documented REAPER render-config format (dc-runtime/misc_docs/
-- RENDER_How_RenderCFG-Base64-strings_are_encoded.txt): 4-byte fourCC
-- (literal on-disk byte order, e.g. WAV is "evaw") followed by format-
-- specific bytes, base64-encoded. Formats with a real PCM bit-depth option
-- get a precomputed blob per depth (bytes beyond the depth byte use the
-- doc's documented "off/default" values -- 0 = unchecked/none, or the doc's
-- own stated default like FLAC's compression=5 -- same low-risk approach
-- already used for WAV's blobs, cross-checked against this machine's own
-- saved presets in reaper-render.ini). Formats without a bit-depth control
-- get just the bare 4-byte fourCC, which REAPER documents as valid for
-- "use this format's default settings" -- avoids hand-encoding MP3/OGG's
-- bitrate/quality floats or ffmpeg/AVF's many codec/resolution sub-fields,
-- which the same doc flags as complex or only partially documented.
local SAMPLE_RATE_OPTIONS = {44100, 48000, 88200, 96000, 176400, 192000}

local BIT_DEPTH_LABELS_PCM   = {[16] = "16-bit", [24] = "24-bit", [32] = "32-bit"}
local BIT_DEPTH_LABELS_FLOAT = {[16] = "16-bit", [24] = "24-bit", [32] = "32-bit Float"}

local RENDER_FORMATS = {
  wav = {
    label = "WAV", file_ext = ".wav",
    bit_depths = {16, 24, 32}, bit_depth_labels = BIT_DEPTH_LABELS_FLOAT,
    blobs = {[16] = "ZXZhdxAGAA==", [24] = "ZXZhdxgGAA==", [32] = "ZXZhdyAGAA=="},
  },
  aiff = {
    label = "AIFF", file_ext = ".aiff",
    bit_depths = {16, 24, 32}, bit_depth_labels = BIT_DEPTH_LABELS_PCM,
    blobs = {[16] = "ZmZpYRAAAA==", [24] = "ZmZpYRgAAA==", [32] = "ZmZpYSAAAA=="},
  },
  caf = {
    label = "CAF", file_ext = ".caf",
    bit_depths = {16, 24, 32}, bit_depth_labels = BIT_DEPTH_LABELS_FLOAT,
    blobs = {[16] = "ZmZhYxAAAA==", [24] = "ZmZhYxgAAA==", [32] = "ZmZhYyAAAA=="},
  },
  flac = {
    label = "FLAC", file_ext = ".flac",
    bit_depths = {16, 24}, bit_depth_labels = BIT_DEPTH_LABELS_PCM,
    blobs = {[16] = "Y2FsZhAAAAAFAAAA", [24] = "Y2FsZhgAAAAFAAAA"},
  },
  wavpack = {
    label = "WavPack", file_ext = ".wv",
    bit_depths = {16, 24, 32}, bit_depth_labels = BIT_DEPTH_LABELS_FLOAT,
    blobs = {
      [16] = "a3B2dwAAAAAAAAAAAAAAAAA=",
      [24] = "a3B2dwAAAAABAAAAAAAAAAA=",
      [32] = "a3B2dwAAAAADAAAAAAAAAAA=",
    },
  },
  mp3 = { label = "MP3", file_ext = ".mp3", fourcc = "l3pm" },
  opus = { label = "OGG Opus", file_ext = ".opus", fourcc = "SggO" },
  vorbis = { label = "OGG Vorbis", file_ext = ".ogg", fourcc = "vggo" },
  -- Video formats: extension is a best guess -- REAPER's actual output
  -- container/extension depends on its own remembered per-format defaults
  -- since we don't override sub-codec/container options here.
  ffmpeg = { label = "Video (FFmpeg)", file_ext = ".mp4", fourcc = "PMFF" },
  avf = { label = "Video (AVF)", file_ext = ".mov", fourcc = "FVAX" },
}

-- Declaration order = dropdown order.
local RENDER_FORMAT_ORDER = {
  "wav", "aiff", "caf", "flac", "mp3", "opus", "vorbis", "wavpack", "ffmpeg", "avf",
}

local function render_format_blob(format_id, bit_depth)
  local fmt = RENDER_FORMATS[format_id] or RENDER_FORMATS.wav
  if fmt.blobs then
    return fmt.blobs[bit_depth] or fmt.blobs[24] or fmt.blobs[fmt.bit_depths[1]]
  end
  return fmt.fourcc
end

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

  local format_blob = render_format_blob(t.render_format, t.bit_depth)
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
-- Approximates how a handful of the most common wildcards
-- ($item/$project/$projectdirectory/$user/$date) will resolve, for display
-- only -- REAPER itself resolves the real render pattern (including every
-- other wildcard offered in the Wildcards menu) at render time. Any token
-- not specifically handled below is left as literal text in the preview.
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
  -- $projectdirectory must be substituted before $project since the latter
  -- is a prefix of the former.
  resolved = resolved:gsub("%$projectdirectory", (proj_path:gsub("%%", "%%%%")))
  resolved = resolved:gsub("%$project",          (proj_name:gsub("%%", "%%%%")))
  resolved = resolved:gsub("%$item",             (item_name:gsub("%%", "%%%%")))
  resolved = resolved:gsub("%$user",             (user:gsub("%%", "%%%%")))
  resolved = resolved:gsub("%$date",             date)
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
local function build_preview_rows(dir, pattern, mono_en, threshold, file_ext)
  local resolved_dir = dir ~= "" and dir or reaper.GetProjectPath()
  local infos = get_selected_item_infos()
  local mono_flags = get_preview_mono_flags(infos, mono_en, threshold)

  local rows = {}
  local mono_total = 0
  for i = 1, math.min(#infos, PREVIEW_MAX_ROWS) do
    local info = infos[i]
    local full_path = resolved_dir .. PATH_SEP .. resolve_preview_pattern(pattern, info.name) .. file_ext
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
-- Render filename wildcards
-- Full token list + one-line descriptions, grouped under the same category
-- names REAPER's own render-pattern Wildcards menu uses. There's no
-- ReaScript API to query REAPER's wildcard list, so these were extracted
-- from the strings embedded in the shipped REAPER binary itself (its
-- Wildcard Help dialog text) rather than guessed -- this is also how the
-- earlier "$projectpath" token (never a real REAPER wildcard -- the actual
-- token is "$projectdirectory") was caught and fixed.
-- Each entry is {token, description} or {token, description, insert} when
-- what should be inserted into the pattern differs from the display token
-- (the three Logic/Control Flow wildcards take a user-typed argument, so
-- only their "$name(" prefix is inserted).
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
    name = "Track Information",
    tokens = {
      {"$track", "Track name"},
      {"$trackname", "Track name, including slash characters"},
      {"$tracknumber", "1 for the first track, 2 for the second..."},
      {"$tracknameornumber", "Track name if it has one, otherwise \"Track N\""},
      {"$parenttrack", "Parent track name"},
      {"$seltrack", "First selected unmuted track"},
      {"$folders", "Track folder structure"},
      {"$fx", "FX list"},
    },
  },
  {
    name = "Media Item Information",
    tokens = {
      {"$item", "Media item take name"},
      {"$itemnumber", "1 for the first media item on a track, 2 for the second..."},
      {"$itemnotes", "Media item notes"},
      {"$takemarker", "Media item take marker (first take marker within the item)"},
      {"$lane", "Media item lane number"},
      {"$trackitem", "Currently-playing media item on selected track"},
      {"$selitem", "Selected media item, blank if multiple selected"},
      {"$note", "Note name (C0 for the first file rendered, C#0 for the second...)"},
      {"$natural", "Note name using only natural notes (C0, D0, ...)"},
    },
  },
  {
    name = "Regions/Markers",
    tokens = {
      {"$region", "Region name or ID number"},
      {"$regionname", "Region name"},
      {"$regionnumber", "Region ID number"},
      {"$regionpos", "Time position within region"},
      {"$regionprev", "Previous region"},
      {"$regionnext", "Next region"},
      {"$regioncountdown", "Count down N beats until next region, then display it"},
      {"$marker", "Marker name or ID number"},
      {"$markername", "Marker name"},
      {"$markernumber", "Marker ID number"},
      {"$markerpos", "Time position since last marker"},
      {"$markerprev", "Previous marker"},
      {"$markernext", "Next marker"},
      {"$markercountdown", "Count down N beats until next marker, then display it"},
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
      {"$startframes", "Start time as absolute frames"},
      {"$endframes", "End time as absolute frames"},
      {"$lengthframes", "Length as absolute frames"},
      {"$startseconds", "Start time as total seconds"},
      {"$endseconds", "End time as total seconds"},
      {"$lengthseconds", "Length as total seconds"},
      {"$lenhh", "Length as hours"},
      {"$lenmm", "Length as minutes modulo hours"},
      {"$lenss", "Length as seconds modulo minutes"},
      {"$lentt", "Length as milliseconds modulo seconds"},
      {"$projectpos", "Project time position, ruler time format"},
      {"$projectlength", "Project length, ruler time format"},
      {"$timesel", "Project time selection, ruler time format"},
      {"$preroll", "Current pre-roll in beats"},
    },
  },
  {
    name = "Output Format",
    tokens = {
      {"$format", "Render format (example: wav)"},
      {"$samplerate", "Sample rate in Hz"},
      {"$sampleratek", "Sample rate in kHz"},
      {"$bitdepth", "Bit depth, if available"},
      {"$channels", "Number of render channels"},
      {"$chid", "Render channel number (or e.g. $chid(L,R,C,LFE,Ls,Rs))"},
      {"$filenumber", "1 for the first file rendered, 2 for the second..."},
      {"$filecount", "The total number of rendered files"},
      {"$namenumber", "1 for the first region/item with the same name, 2 for the second..."},
      {"$timelineorder", "1 for the first item/region on the timeline, 2 for the second..."},
      {"$timelineorder_track", "Same as $timelineorder, but numbered per-track"},
    },
  },
  {
    name = "Date/Time",
    tokens = {
      {"$date", "Date"},
      {"$time", "Time"},
      {"$datetime", "Date and time"},
      {"$year", "Year"},
      {"$year2", "Last 2 digits of the year"},
      {"$month", "Month number"},
      {"$monthname", "Month name"},
      {"$day", "Day of the month"},
      {"$dayname", "Day of the week"},
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
  {
    name = "Logic/Control Flow",
    tokens = {
      {"$ifprev(text)", "\"text\" if the previous wildcard resolves to anything", "$ifprev("},
      {"$ifnext(text)", "\"text\" if the following wildcard resolves to anything", "$ifnext("},
      {"$ifboth(text)", "\"text\" if the previous and following wildcards both resolve", "$ifboth("},
    },
  },
}

-- ============================================================
-- ImGui context
-- ============================================================
local script_title = "SMART EXPORT ITEMS"
local ctx = ImGui.CreateContext(script_title)

-- CreateFont(family, flags) -- size is chosen per-use via PushFont's own
-- size argument, not baked in here. (The Render button's bold font is
-- owned by theme.PrimaryButton, which creates and caches it per-ctx.)
local mono_font_name = reaper.GetOS():find("Win") and "Consolas" or "Menlo"
local mono_font = ImGui.CreateFont(mono_font_name)
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
local render_format   = "wav"
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
  render_format   = t.render_format
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
  t.render_format          = render_format
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

  local WIN_W = 950
  ImGui.SetNextWindowSizeConstraints(ctx, 630, 0, 3000, 10000)
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
    local LEFT_COL_W     = 270
    local LEFT_PAD       = 10  -- breathing room between the rail's edges and its content
    local TOP_PAD        = 8   -- matching breathing room above the first row
    local LEFT_CONTENT_W = LEFT_COL_W - LEFT_PAD * 2
    local CTL_W          = 150  -- fixed control width; label column stretches to fill the rest

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
    -- Indent shifts every subsequent item's left edge by LEFT_PAD; paired
    -- with sizing content to LEFT_CONTENT_W (LEFT_COL_W minus padding on
    -- both sides) instead of the full rail width, so nothing touches the
    -- rail's edges. Must be un-indented before EndGroup below.
    ImGui.Indent(ctx, LEFT_PAD)
    ImGui.Dummy(ctx, 0, TOP_PAD)

    -- outer_size_w pins each table to LEFT_CONTENT_W -- without it, a table
    -- with a WidthStretch column stretches to fill the *whole window* (a
    -- BeginGroup doesn't constrain child width), shoving the right column
    -- off past the window edge and making the preview text wrap to
    -- near-zero width.
    local function begin_field_table(id)
      local ok = ImGui.BeginTable(ctx, id, 2, 0, LEFT_CONTENT_W, 0)
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
      local fmt = RENDER_FORMATS[render_format] or RENDER_FORMATS.wav

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      if ImGui.BeginCombo(ctx, "##render_format", fmt.label, 0) then
        for _, fid in ipairs(RENDER_FORMAT_ORDER) do
          local opt = RENDER_FORMATS[fid]
          if ImGui.Selectable(ctx, opt.label, render_format == fid, 0) then
            render_format = fid
            fmt = opt
            -- Clamp bit depth to a valid option for the newly selected
            -- format (e.g. switching WAV[32] -> FLAC, which tops out at 24).
            -- Every bit-depth-capable format includes 24, so that's always
            -- a safe fallback.
            if fmt.bit_depths then
              local valid = false
              for _, bd in ipairs(fmt.bit_depths) do if bd == bit_depth then valid = true end end
              if not valid then bit_depth = 24 end
            end
          end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Format")

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

      if fmt.bit_depths then
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.SetNextItemWidth(ctx, -1)
        local bd_labels = fmt.bit_depth_labels
        if ImGui.BeginCombo(ctx, "##bit_depth", bd_labels[bit_depth] or (bit_depth .. "-bit"), 0) then
          for _, bd in ipairs(fmt.bit_depths) do
            if ImGui.Selectable(ctx, bd_labels[bd], bit_depth == bd, 0) then bit_depth = bd end
          end
          ImGui.EndCombo(ctx)
        end
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, "Bit Depth")
      end

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

    -- Separator above the Render button -- drawn manually at LEFT_CONTENT_W
    -- rather than via ImGui.Separator(), which (like Button/Table before it)
    -- spans the *window's* full content width inside a bare BeginGroup, not
    -- the rail's intended width.
    ImGui.Spacing(ctx)
    do
      local sx, sy = ImGui.GetCursorScreenPos(ctx)
      local draw_list = ImGui.GetWindowDrawList(ctx)
      ImGui.DrawList_AddRectFilled(draw_list, sx, sy, sx + LEFT_CONTENT_W, sy + 1, 0x3A3F45FF)
    end
    ImGui.Dummy(ctx, 0, 1)
    ImGui.Spacing(ctx)

    -- Render button -- only the click is captured here; the actual
    -- run_export() call is deferred until after the right column has been
    -- fully drawn, so REAPER's native render engine never runs mid-frame
    -- with more ImGui widgets still queued behind it. Width is explicit
    -- (LEFT_CONTENT_W) rather than -1, which -- like Table/Separator above --
    -- would fill to the window's edge instead of the rail's padded width.
    local no_items = n_items == 0
    if no_items then ImGui.BeginDisabled(ctx, true) end
    local do_render = theme.PrimaryButton(ctx, "Render", LEFT_CONTENT_W, 0)
      or (not no_items and (
            ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
            or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)))
    if no_items then ImGui.EndDisabled(ctx) end

    local status_text = ("%d %s selected"):format(n_items, n_items == 1 and "item" or "items")
    local status_w = ImGui.CalcTextSize(ctx, status_text)
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + (LEFT_CONTENT_W - status_w) / 2)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, status_text)
    ImGui.PopStyleColor(ctx)

    local _, footer_bottom_y = ImGui.GetCursorScreenPos(ctx)
    left_footer_h = footer_bottom_y - footer_top_y

    ImGui.Unindent(ctx, LEFT_PAD)
    ImGui.EndGroup(ctx)

    -- ── Right column: output dir/filename + live preview ────
    -- Gap is 20 + LEFT_PAD: the left group's measured bounding box now ends
    -- LEFT_PAD short of the tint rect's actual right edge (content is
    -- inset), so SameLine's offset (measured from that bounding box) needs
    -- the extra LEFT_PAD to keep a consistent 20px gap from the visible rail.
    ImGui.SameLine(ctx, 0, 20 + LEFT_PAD)

    ImGui.BeginGroup(ctx)
    ImGui.Dummy(ctx, 0, TOP_PAD)  -- keeps this column's content aligned with the left rail's

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
        for _, cat in ipairs(WILDCARD_CATEGORIES) do
          if ImGui.BeginMenu(ctx, cat.name) then
            for _, tok in ipairs(cat.tokens) do
              local display, desc, insert = tok[1], tok[2], tok[3]
              if ImGui.MenuItem(ctx, display) then
                pattern_buf = pattern_buf .. (insert or display)
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

    local mono_threshold = tonumber(mono_thresh_buf) or 0.9
    local preview_file_ext = (RENDER_FORMATS[render_format] or RENDER_FORMATS.wav).file_ext
    local preview_rows, preview_total, preview_mono_total =
      build_preview_rows(dir_buf, pattern_buf, mono_downmix_en, mono_threshold, preview_file_ext)

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
