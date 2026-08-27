-- @description Text Overlay (GUI)
-- @author Stephen Schappler
-- @version 1.1
-- @link https://www.stephenschappler.com
-- @about
--   ReaImGui live-editing front end for a custom Video processor text/
--   timecode overlay effect (a modified version of REAPER's built-in
--   "Text/timecode overlay" preset with full RGB color and a drop shadow
--   added). Select an overlay item (or create a new one on a dedicated
--   "Text Overlay" track) and every field -- text, XY position, size,
--   text/background color, shadow, ignore input, timecode -- pushes
--   straight to the item in real time, no digging through the native FX
--   window's raw parameter list required. Save named styles to reuse a
--   look with one click, and batch-apply style changes across multiple
--   selected overlay items at once (each item's own text is always left
--   untouched).
-- @changelog
--   08/27/26 v0.2 - Replaced REAPER's stock grayscale-only overlay preset
--                   with a custom variant adding full RGB text/background
--                   color and a drop shadow (enable + X/Y offset + alpha
--                   scale). Existing items created with v1.0 use the old
--                   preset and won't be recognized by this version.
--   08/27/26 v0.1 - Initial release

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
local PATH_SEP    = reaper.GetOS():find("Win") and "\\" or "/"
local style_dir   = script_dir .. "Text Overlay Styles" .. PATH_SEP

local function require_common(filename)
  local path = script_dir .. "Common/" .. filename
  if not reaper.file_exists(path) then
    path = script_dir .. "../Common/" .. filename
  end
  return dofile(path)
end

local theme = require_common("ReaImGuiTheme.lua")

-- ============================================================
-- Embedded preset JSFX source: a custom variant of REAPER's built-in
-- "Overlay: Text/Timecode" Video processor preset, adding full RGB text/
-- background color (the stock preset is grayscale-only) and a drop shadow.
-- Embedded here (rather than read from an external .txt/.RTrackTemplate
-- asset) so this script is fully self-contained.
-- ============================================================
local PRESET_NAME = "Text Overlay Plus (Custom)"

local PRESET_CODE_BLOCK = [[<TAKEFX
  SHOW 0
  LASTSEL 0
  DOCKED 0
  BYPASS 0 0 0
  <VIDEO_EFFECT "Video processor" ""
    <CODE
      |// Text/timecode overlay plus
      |#text="Caption"; // set to string to override
      |font="Arial";
      |
      |//@param1:size 'text height' 0.05 0.01 0.2 0.1 0.001
      |//@param2:ypos 'y position' 0.95 0 1 0.5 0.01
      |//@param3:xpos 'x position' 0.5 0 1 0.5 0.01
      |//@param4:border 'bg pad' 0.1 0 1 0.5 0.01
      |//@param5:fgr 'text red' 1.0 0 1 0.5 0.01
      |//@param6:fgg 'text green' 1.0 0 1 0.5 0.01
      |//@param7:fgb 'text blue' 1.0 0 1 0.5 0.01
      |//@param8:fga 'text alpha' 1.0 0 1 0.5 0.01
      |
      |//@param9:bgR 'bg red' 0.0 0 1 0.5 0.01
      |//@param10:bgG 'bg green' 0.0 0 1 0.5 0.01
      |//@param11:bgB 'bg blue' 0.0 0 1 0.5 0.01
      |//@param12:bga 'bg alpha' 0.5 0 1 0.5 0.01
      |//@param13:bgfit 'fit bg to text' 0 0 1 0.5 1
      |
      |//@param14:shadow 'enable shadow' 1 0 1 0.5 1
      |//@param15:shad_x 'shadow X offset (px)' 2 0 10 2 0.1
      |//@param16:shad_y 'shadow Y offset (px)' 2 0 10 2 0.1
      |//@param17:shad_alpha 'shadow alpha scale' 0.6 0 1 0.5 0.01
      |
      |//@param18:ignoreinput 'ignore input' 0 0 1 0.5 1
      |//@param19:tc 'show timecode' 0 0 1 0.5 1
      |//@param20:tcdf 'dropframe timecode' 0 0 1 0.5 1
      |
      |input = ignoreinput ? -2 : 0;
      |project_wh_valid===0 ? input_info(input,project_w,project_h);
      |gfx_a2=0;
      |gfx_blit(input,1);
      |gfx_setfont(size*project_h,font);
      |
      |tc>0.5 ? (
      |  t = floor((project_time + project_timeoffs) * framerate + 0.0000001);
      |  f = ceil(framerate);
      |  tcdf > 0.5 && f != framerate ? (
      |    period = floor(framerate * 600);
      |    ds = floor(framerate * 60);
      |    ds > 0 ? t += 18 * ((t / period)|0) + ((((t%period)-2)/ds)|0)*2;
      |  );
      |  sprintf(#text,"%02d:%02d:%02d:%02d",(t/(f*3600))|0,(t/(f*60))%60,(t/f)%60,t%f);
      |) : strcmp(#text,"")==0 ? input_get_name(-1,#text);
      |
      |gfx_str_measure(#text,txtw,txth);
      |b = (border*txth)|0;
      |yt = ((project_h - txth - b*2)*ypos)|0;
      |xp = (xpos * (project_w-txtw))|0;
      |
      |gfx_set(bgR, bgG, bgB, bga);
      |bga>0 ? gfx_fillrect(
      |  bgfit ? xp - b : 0,
      |  yt,
      |  bgfit ? txtw + b*2 : project_w,
      |  txth + b*2
      |);
      |
      |shadow > 0.5 ? (
      |  gfx_set(0, 0, 0, fga * shad_alpha);
      |  gfx_str_draw(#text, xp + shad_x, yt + b + shad_y);
      |);
      |
      |gfx_set(fgr,fgg,fgb,fga);
      |gfx_str_draw(#text,xp,yt+b);
    >
    CODEPARM 0.05 0.95 0.5 0.1 1 1 1 1 0 0 0 0.5 0 1 2 2 0.6 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  >
  PRESETNAME "Text Overlay Plus (Custom)"
  WAK 0 0
>
]]

-- Real 0-based TakeFX_SetParam/GetParam slot indices, matching the @paramN
-- declaration order above (sequential here, no gaps).
local PARAM = {
  SIZE         = 0,
  YPOS         = 1,
  XPOS         = 2,
  BORDER       = 3,
  TEXT_R       = 4,
  TEXT_G       = 5,
  TEXT_B       = 6,
  TEXT_ALPHA   = 7,
  BG_R         = 8,
  BG_G         = 9,
  BG_B         = 10,
  BG_ALPHA     = 11,
  BG_FIT       = 12,
  SHADOW       = 13,
  SHADOW_X     = 14,
  SHADOW_Y     = 15,
  SHADOW_ALPHA = 16,
  IGNORE_INPUT = 17,
  SHOW_TC      = 18,
  DROPFRAME_TC = 19,
}

local DEFAULT_DURATION = 4.0

local DEFAULT_STYLE = {
  name         = "Default",
  text         = "Caption",
  font         = "Arial",
  duration     = DEFAULT_DURATION,
  size         = 0.05,
  xpos         = 0.5,
  ypos         = 0.95,
  border       = 0.1,
  text_r       = 1.0,
  text_g       = 1.0,
  text_b       = 1.0,
  text_alpha   = 1.0,
  bg_r         = 0.0,
  bg_g         = 0.0,
  bg_b         = 0.0,
  bg_alpha     = 0.5,
  bg_fit       = false,
  shadow       = true,
  shadow_x     = 2.0,
  shadow_y     = 2.0,
  shadow_alpha = 0.6,
  ignore_input = false,
  show_tc      = false,
  dropframe_tc = false,
}

-- ============================================================
-- FX detection / chunk helpers
-- ============================================================
local function FindOverlayFX(take)
  if not take then return nil end
  local fx_count = reaper.TakeFX_GetCount(take)
  for fx = 0, fx_count - 1 do
    local _, fx_name = reaper.TakeFX_GetFXName(take, fx, "")
    if fx_name:find("Video processor", 1, true) then
      local _, preset_name = reaper.TakeFX_GetPreset(take, fx, "")
      if preset_name == PRESET_NAME then
        return fx
      end
    end
  end
  return nil
end

-- Returns state_chunk, part-before-TAKEFX, the <TAKEFX...> block, part-after
-- -- assumes (like the precedent regions script) exactly one FX on the take.
--
-- RPP chunks nest arbitrarily deep (<TAKEFX> contains <VIDEO_EFFECT>
-- contains <CODE>, each closing on its own "  >" line before TAKEFX's own
-- close), so finding the block's end requires counting tag depth, not just
-- matching the first line that's only ">". Lines starting with "|" are raw
-- content (the JSFX source itself) and never affect depth, even if they
-- contain literal "<"/">" characters.
local function GetChunkAndTakeFX(item)
  local ok, state_chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok then return nil end

  local start_pos = state_chunk:find("<TAKEFX", 1, true)
  if not start_pos then return nil end

  local depth = 0
  local search_pos = start_pos
  local block_end_pos = nil
  while true do
    local line_end = state_chunk:find("\n", search_pos, true)
    local line = line_end and state_chunk:sub(search_pos, line_end - 1) or state_chunk:sub(search_pos)
    if not line:match("^%s*|") then
      if line:match("^%s*<%S") then
        depth = depth + 1
      elseif line:match("^%s*>%s*$") then
        depth = depth - 1
        if depth == 0 then
          block_end_pos = line_end or (#state_chunk + 1)
          break
        end
      end
    end
    if not line_end then break end
    search_pos = line_end + 1
  end
  if not block_end_pos then return nil end

  local part1 = state_chunk:sub(1, start_pos - 1)
  local code  = state_chunk:sub(start_pos, block_end_pos - 1)
  local part2 = state_chunk:sub(block_end_pos)
  return state_chunk, part1, code, part2
end

local function GetOverlayText(item)
  local _, _, code = GetChunkAndTakeFX(item)
  if not code then return "" end
  local _, text = code:match("(.-#text=\")(.-)(\".*)")
  if not text then return "" end
  return (text:gsub("\\n", "\n"))
end

local function SetOverlayText(item, text)
  local _, part1, code, part2 = GetChunkAndTakeFX(item)
  if not code then return false end
  local c1, _, c3 = code:match("(.-#text=\")(.-)(\".*)")
  if not c1 then return false end
  local escaped = text:gsub("\n", "\\n")
  return reaper.SetItemStateChunk(item, part1 .. c1 .. escaped .. c3 .. part2, false)
end

local function GetOverlayFont(item)
  local _, _, code = GetChunkAndTakeFX(item)
  if not code then return "Arial" end
  local _, font = code:match("(.-font=\")(.-)(\".*)")
  return font or "Arial"
end

local function SetOverlayFont(item, font)
  local _, part1, code, part2 = GetChunkAndTakeFX(item)
  if not code then return false end
  local c1, _, c3 = code:match("(.-font=\")(.-)(\".*)")
  if not c1 then return false end
  return reaper.SetItemStateChunk(item, part1 .. c1 .. font .. c3 .. part2, false)
end

-- Replaces one "field=value" (a quoted string field like #text="..." or
-- font="...") inside a block of code text, by plain substring search
-- (never Lua pattern matching) so arbitrary user text/font values can't be
-- misread as -- or need escaping against -- pattern/replacement specials.
local function set_quoted_field(block, field_prefix, new_value)
  local s, e = block:find(field_prefix, 1, true)
  if not s then return block end
  local value_end = block:find('"', e + 1, true)
  if not value_end then return block end
  return block:sub(1, e) .. new_value .. block:sub(value_end)
end

-- Real-slot-ordered CODEPARM values for `style`, padded out to the same
-- length as the template's own CODEPARM line.
local function format_codeparm(style)
  local vals = {
    style.size, style.ypos, style.xpos, style.border,
    style.text_r, style.text_g, style.text_b, style.text_alpha,
    style.bg_r, style.bg_g, style.bg_b, style.bg_alpha,
    style.bg_fit and 1 or 0,
    style.shadow and 1 or 0, style.shadow_x, style.shadow_y, style.shadow_alpha,
    style.ignore_input and 1 or 0, style.show_tc and 1 or 0, style.dropframe_tc and 1 or 0,
  }
  local parts = {}
  for _, v in ipairs(vals) do parts[#parts + 1] = tostring(v) end
  for _ = 1, 20 do parts[#parts + 1] = "0" end
  return table.concat(parts, " ")
end

-- Builds the full <TAKEFX> block for `style`, with text/font/every param's
-- initial value baked directly into the source (#text=, font=, CODEPARM)
-- rather than left as the template's placeholder defaults.
--
-- This matters because a brand new JSFX (never compiled by REAPER before,
-- unlike a familiar factory preset) doesn't finish compiling synchronously
-- within the same script call that injects it via SetItemStateChunk --
-- TakeFX_SetParam calls issued right after injection can get silently
-- discarded once compilation completes and the FX (re)initializes its
-- params from CODEPARM. Baking the real values into CODEPARM itself
-- sidesteps that race entirely for newly created items. #text/font are
-- immune to this either way since they're literal source text, not
-- runtime parameter memory, but are baked in here too for one clean
-- single-chunk-write creation path (see AddOverlayFX below). Once an item
-- is alive on the timeline, later live edits go through TakeFX_SetParam
-- as normal (see apply_param_to_targets/apply_style_params) -- there's no
-- race for an FX that's already compiled and stable.
local function build_preset_block(style)
  local block = PRESET_CODE_BLOCK
  block = set_quoted_field(block, '#text="', (style.text or ""):gsub("\n", "\\n"))
  block = set_quoted_field(block, 'font="', style.font or "Arial")

  local codeparm_start = block:find("CODEPARM ", 1, true)
  local line_end = block:find("\n", codeparm_start, true)
  block = block:sub(1, codeparm_start - 1) .. "CODEPARM " .. format_codeparm(style) .. block:sub(line_end)

  return block
end

-- Replaces an item's existing (empty/no-op) Video processor TAKEFX block
-- with the full text/timecode overlay preset, initialized with `style`'s
-- values. Requires the item to already have a Video processor FX on its
-- take (e.g. from action 41932, "Insert dedicated video processor item").
local function AddOverlayFX(item, style)
  local state_chunk, part1, _, part2 = GetChunkAndTakeFX(item)
  if not state_chunk then return false, "No Video Processor found on this item" end
  return reaper.SetItemStateChunk(item, part1 .. build_preset_block(style) .. part2, false)
end

local function apply_style_params(take, fx, style)
  reaper.TakeFX_SetParam(take, fx, PARAM.SIZE, style.size)
  reaper.TakeFX_SetParam(take, fx, PARAM.XPOS, style.xpos)
  reaper.TakeFX_SetParam(take, fx, PARAM.YPOS, style.ypos)
  reaper.TakeFX_SetParam(take, fx, PARAM.BORDER, style.border)
  reaper.TakeFX_SetParam(take, fx, PARAM.TEXT_R, style.text_r)
  reaper.TakeFX_SetParam(take, fx, PARAM.TEXT_G, style.text_g)
  reaper.TakeFX_SetParam(take, fx, PARAM.TEXT_B, style.text_b)
  reaper.TakeFX_SetParam(take, fx, PARAM.TEXT_ALPHA, style.text_alpha)
  reaper.TakeFX_SetParam(take, fx, PARAM.BG_R, style.bg_r)
  reaper.TakeFX_SetParam(take, fx, PARAM.BG_G, style.bg_g)
  reaper.TakeFX_SetParam(take, fx, PARAM.BG_B, style.bg_b)
  reaper.TakeFX_SetParam(take, fx, PARAM.BG_ALPHA, style.bg_alpha)
  reaper.TakeFX_SetParam(take, fx, PARAM.BG_FIT, style.bg_fit and 1 or 0)
  reaper.TakeFX_SetParam(take, fx, PARAM.SHADOW, style.shadow and 1 or 0)
  reaper.TakeFX_SetParam(take, fx, PARAM.SHADOW_X, style.shadow_x)
  reaper.TakeFX_SetParam(take, fx, PARAM.SHADOW_Y, style.shadow_y)
  reaper.TakeFX_SetParam(take, fx, PARAM.SHADOW_ALPHA, style.shadow_alpha)
  reaper.TakeFX_SetParam(take, fx, PARAM.IGNORE_INPUT, style.ignore_input and 1 or 0)
  reaper.TakeFX_SetParam(take, fx, PARAM.SHOW_TC, style.show_tc and 1 or 0)
  reaper.TakeFX_SetParam(take, fx, PARAM.DROPFRAME_TC, style.dropframe_tc and 1 or 0)
end

-- Reads a style-shaped table back out of a live overlay item, so the
-- inspector can sync its buffer to whatever the item's actual current
-- state is (not just whatever this script last wrote).
local function read_style_from_item(item)
  local take = reaper.GetActiveTake(item)
  local fx = FindOverlayFX(take)
  if not fx then return nil end
  return {
    text         = GetOverlayText(item),
    font         = GetOverlayFont(item),
    duration     = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    size         = reaper.TakeFX_GetParam(take, fx, PARAM.SIZE),
    xpos         = reaper.TakeFX_GetParam(take, fx, PARAM.XPOS),
    ypos         = reaper.TakeFX_GetParam(take, fx, PARAM.YPOS),
    border       = reaper.TakeFX_GetParam(take, fx, PARAM.BORDER),
    text_r       = reaper.TakeFX_GetParam(take, fx, PARAM.TEXT_R),
    text_g       = reaper.TakeFX_GetParam(take, fx, PARAM.TEXT_G),
    text_b       = reaper.TakeFX_GetParam(take, fx, PARAM.TEXT_B),
    text_alpha   = reaper.TakeFX_GetParam(take, fx, PARAM.TEXT_ALPHA),
    bg_r         = reaper.TakeFX_GetParam(take, fx, PARAM.BG_R),
    bg_g         = reaper.TakeFX_GetParam(take, fx, PARAM.BG_G),
    bg_b         = reaper.TakeFX_GetParam(take, fx, PARAM.BG_B),
    bg_alpha     = reaper.TakeFX_GetParam(take, fx, PARAM.BG_ALPHA),
    bg_fit       = reaper.TakeFX_GetParam(take, fx, PARAM.BG_FIT) >= 0.5,
    shadow       = reaper.TakeFX_GetParam(take, fx, PARAM.SHADOW) >= 0.5,
    shadow_x     = reaper.TakeFX_GetParam(take, fx, PARAM.SHADOW_X),
    shadow_y     = reaper.TakeFX_GetParam(take, fx, PARAM.SHADOW_Y),
    shadow_alpha = reaper.TakeFX_GetParam(take, fx, PARAM.SHADOW_ALPHA),
    ignore_input = reaper.TakeFX_GetParam(take, fx, PARAM.IGNORE_INPUT) >= 0.5,
    show_tc      = reaper.TakeFX_GetParam(take, fx, PARAM.SHOW_TC) >= 0.5,
    dropframe_tc = reaper.TakeFX_GetParam(take, fx, PARAM.DROPFRAME_TC) >= 0.5,
  }
end

local function deep_copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- ============================================================
-- System font discovery -- there's no ReaScript/ReaImGui API to enumerate
-- installed fonts, so this scans the OS's standard font directories
-- directly with reaper.EnumerateFiles (no shelling out) and derives a
-- display name from each file's basename. Flat (non-recursive), so a font
-- installed into a subfolder of one of these directories won't show up --
-- the FONT field stays a free-text input too, so any font can still be
-- typed by hand regardless of whether this discovery finds it.
-- ============================================================
local FONT_FILE_EXTENSIONS = { ttf = true, otf = true, ttc = true, dfont = true }

local function add_fonts_from_dir(dir, seen, out)
  if not dir or dir == "" then return end
  local i = 0
  while true do
    local file = reaper.EnumerateFiles(dir, i)
    if not file then break end
    local ext = file:match("%.([%a]+)$")
    if ext and FONT_FILE_EXTENSIONS[ext:lower()] then
      local name = file:sub(1, #file - #ext - 1):gsub("_", " ")
      if name ~= "" and not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
    i = i + 1
  end
end

local function discover_system_fonts()
  local seen, out = {}, {}
  if reaper.GetOS():find("Win") then
    local windir = os.getenv("WINDIR") or os.getenv("SystemRoot") or "C:\\Windows"
    add_fonts_from_dir(windir .. "\\Fonts", seen, out)
  else
    local home = os.getenv("HOME") or ""
    add_fonts_from_dir("/System/Library/Fonts", seen, out)
    add_fonts_from_dir("/Library/Fonts", seen, out)
    if home ~= "" then
      add_fonts_from_dir(home .. "/Library/Fonts", seen, out)
    end
  end
  table.sort(out, function(a, b) return a:lower() < b:lower() end)
  return out
end

-- ============================================================
-- Dedicated "Text Overlay" track (found/created once per project, GUID
-- remembered via ProjExtState -- same convention as the precedent regions
-- script's "acendan_vid_rgns" namespace, but without an SWS dependency).
-- ============================================================
local EXT_NAMESPACE = "schapps_text_overlay"
local TRACK_NAME     = "Text Overlay"

local function FindTrackByGUID(guid)
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(track) == guid then return track end
  end
  return nil
end

local function FindOrCreateOverlayTrack()
  local ok, guid = reaper.GetProjExtState(0, EXT_NAMESPACE, "trk_guid")
  if ok and guid ~= "" then
    local track = FindTrackByGUID(guid)
    if track then return track end
  end
  reaper.InsertTrackAtIndex(0, false)
  local track = reaper.GetTrack(0, 0)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", TRACK_NAME, true)
  reaper.SetProjExtState(0, EXT_NAMESPACE, "trk_guid", reaper.GetTrackGUID(track))
  return track
end

-- Creates a new overlay item on the dedicated track, at the current time
-- selection (or a default-length item at the edit cursor if there isn't
-- one), and applies `style` to it.
local function CreateOverlayItem(style)
  local track = FindOrCreateOverlayTrack()

  local orig_ts_start, orig_ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local orig_cursor = reaper.GetCursorPosition()

  local sel_start, sel_end = orig_ts_start, orig_ts_end
  if sel_end <= sel_start then
    sel_start = orig_cursor
    sel_end = orig_cursor + (style.duration or DEFAULT_DURATION)
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  reaper.SetOnlyTrackSelected(track)
  reaper.GetSet_LoopTimeRange(true, false, sel_start, sel_end, false)

  local items_before = reaper.CountTrackMediaItems(track)
  reaper.Main_OnCommand(41932, 0) -- Insert dedicated video processor item
  local item = nil
  if reaper.CountTrackMediaItems(track) > items_before then
    item = reaper.GetTrackMediaItem(track, reaper.CountTrackMediaItems(track) - 1)
  end

  if item then
    -- Action 41932 only inserts the item shell -- it does not by itself
    -- attach a Video processor FX instance, so one has to be added before
    -- AddOverlayFX has a <TAKEFX> block to splice the preset into.
    local take = reaper.GetActiveTake(item)
    reaper.TakeFX_AddByName(take, "Video processor", 1)

    local ok, err = AddOverlayFX(item, style)
    if ok then
      local fx = FindOverlayFX(take)
      if fx then
        reaper.TakeFX_SetOpen(take, fx, false)
      end
    else
      reaper.ShowMessageBox("Could not set up the text overlay:\n" .. tostring(err), "Text Overlay", 0)
    end
    reaper.SetMediaItemSelected(item, true)
  end

  reaper.GetSet_LoopTimeRange(true, false, orig_ts_start, orig_ts_end, false)
  reaper.SetEditCurPos(orig_cursor, false, false)

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Add Text Overlay", -1)
  reaper.UpdateArrange()

  return item
end

-- ============================================================
-- Style file I/O -- named presets saved as plain Lua files, same shape as
-- Video/Export Time Selection as Video (GUI).lua's template storage.
-- ============================================================
local STYLE_FIELDS_ORDER = {
  "name", "text", "font", "duration",
  "size", "xpos", "ypos", "border",
  "text_r", "text_g", "text_b", "text_alpha",
  "bg_r", "bg_g", "bg_b", "bg_alpha", "bg_fit",
  "shadow", "shadow_x", "shadow_y", "shadow_alpha",
  "ignore_input", "show_tc", "dropframe_tc",
}

local function ensure_style_dir()
  reaper.RecursiveCreateDirectory(style_dir, 0)
end

local function save_style(t)
  ensure_style_dir()
  local path = style_dir .. t.name .. ".lua"
  local f = io.open(path, "w")
  if not f then
    reaper.ShowMessageBox("Could not write style:\n" .. path, "Text Overlay", 0)
    return
  end
  f:write("-- Text Overlay Style\n")
  for _, k in ipairs(STYLE_FIELDS_ORDER) do
    local v = t[k]
    if type(v) == "string" then
      f:write(k .. " = " .. string.format("%q", v) .. "\n")
    else
      f:write(k .. " = " .. tostring(v) .. "\n")
    end
  end
  f:close()
end

local function load_style_file(path)
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
    chunk = load(content, "style", "t", env)
  end
  if not chunk then return nil end
  pcall(chunk)
  for k, v in pairs(DEFAULT_STYLE) do
    if t[k] == nil then t[k] = v end
  end
  return t
end

local function list_styles()
  local list = {}
  local i = 0
  while true do
    local file = reaper.EnumerateFiles(style_dir, i)
    if not file then break end
    if file:match("%.lua$") and not file:match("^%.") then
      local name = file:gsub("%.lua$", "")
      local t = load_style_file(style_dir .. file)
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

local function delete_style(name)
  os.remove(style_dir .. name .. ".lua")
end

local function rename_style_file(old_name, new_name)
  local t = load_style_file(style_dir .. old_name .. ".lua")
  if not t then return false end
  t.name = new_name
  save_style(t)
  delete_style(old_name)
  return true
end

local function bootstrap_default_style()
  ensure_style_dir()
  local t = deep_copy(DEFAULT_STYLE)
  save_style(t)
  return t
end

local function name_in_use(styles, name, exclude_idx)
  for i, t in ipairs(styles) do
    if t.name == name and i ~= (exclude_idx or -1) then return true end
  end
  return false
end

-- ============================================================
-- Selected overlay items ("targets") -- every selected media item whose
-- active take is currently on the text/timecode overlay preset.
-- ============================================================
local function get_targets()
  local targets = {}
  local sig_parts = {}
  local n = reaper.CountSelectedMediaItems(0)
  for i = 0, n - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    local fx = FindOverlayFX(take)
    if fx then
      table.insert(targets, { item = item, take = take, fx = fx })
      table.insert(sig_parts, tostring(item))
    end
  end
  return targets, table.concat(sig_parts, ",")
end

local function apply_param_to_targets(targets, key, value)
  for _, t in ipairs(targets) do
    reaper.TakeFX_SetParam(t.take, t.fx, PARAM[key], value)
  end
end

local function apply_font_to_targets(targets, font)
  for _, t in ipairs(targets) do
    SetOverlayFont(t.item, font)
  end
end

local function apply_style_to_targets(targets, style)
  for _, t in ipairs(targets) do
    apply_style_params(t.take, t.fx, style)
    SetOverlayFont(t.item, style.font)
  end
end

local function commit_undo(label)
  reaper.Undo_BeginBlock()
  reaper.Undo_EndBlock(label, -1)
end

-- ============================================================
-- ImGui context
-- ============================================================
local script_title = "TEXT OVERLAY"
local ctx = ImGui.CreateContext(script_title)
local WIN_FLAGS = ImGui.WindowFlags_NoCollapse

-- Fonts for the live preview canvas, one per distinct family name (must be
-- created once and reused, not per frame) -- keyed by name since buf.font
-- can change at any time as the user types/switches styles. Falls back to
-- a generic sans-serif if the named family can't be resolved/created.
local preview_font_cache = {}
local function get_preview_font(name)
  name = (name and name ~= "") and name or "Arial"
  local font = preview_font_cache[name]
  if not font then
    local ok, created = pcall(ImGui.CreateFont, name)
    font = (ok and created) or ImGui.CreateFont("sans-serif")
    ImGui.Attach(ctx, font)
    preview_font_cache[name] = font
  end
  return font
end

-- ============================================================
-- State
-- ============================================================
local styles     = {}
local active_idx = 1
local buf        = deep_copy(DEFAULT_STYLE)
local last_sig   = nil

local rename_pending    = false
local rename_focus_next = false
local rename_idx        = 1
local rename_buf        = ""
local rename_dup_err    = false

local delete_pending = false
local delete_idx     = 1

local available_fonts = discover_system_fonts()
local font_filter     = ""

local function init_styles()
  ensure_style_dir()
  styles = list_styles()
  if #styles == 0 then
    table.insert(styles, bootstrap_default_style())
  end

  active_idx = 1
  local saved_name = reaper.GetExtState("TextOverlayGUI", "active_style")
  if saved_name ~= "" then
    for i, s in ipairs(styles) do
      if s.name == saved_name then active_idx = i break end
    end
  end

  buf = deep_copy(styles[active_idx])
end

init_styles()

local function style_dirty()
  local s = styles[active_idx]
  if not s then return false end
  for _, k in ipairs(STYLE_FIELDS_ORDER) do
    if k ~= "name" and s[k] ~= buf[k] then return true end
  end
  return false
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  local targets, sig = get_targets()
  if sig ~= last_sig then
    last_sig = sig
    if #targets >= 1 then
      local s = read_style_from_item(targets[1].item)
      if s then buf = s end
    else
      -- Nothing selected: fall back to the active style's own saved
      -- values rather than leaving stale values from a previously
      -- selected item in the buffer.
      buf = deep_copy(styles[active_idx])
    end
  end

  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSize(ctx, 680, 0, ImGui.Cond_FirstUseEver)
  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then

    -- ── Style tab bar ───────────────────────────────────────
    if ImGui.BeginTabBar(ctx, "##styles", ImGui.TabBarFlags_AutoSelectNewTabs) then
      for i, s in ipairs(styles) do
        local tab_visible, new_open = ImGui.BeginTabItem(ctx, s.name, true, 0)

        if ImGui.BeginPopupContextItem(ctx, "##ctx_" .. i) then
          if ImGui.MenuItem(ctx, "Rename\u{2026}") then
            rename_pending = true
            rename_idx     = i
            rename_buf     = s.name
            rename_dup_err = false
          end
          local can_delete = #styles > 1
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

        if not new_open and #styles > 1 then
          delete_pending = true
          delete_idx     = i
        end

        if tab_visible then
          if i ~= active_idx then
            active_idx = i
            buf = deep_copy(s)
            if #targets >= 1 then
              apply_style_to_targets(targets, s)
              commit_undo("Apply text overlay style")
            end
            reaper.SetExtState("TextOverlayGUI", "active_style", s.name, true)
          end
          ImGui.EndTabItem(ctx)
        end
      end

      if ImGui.TabItemButton(ctx, "+", ImGui.TabItemFlags_Trailing) then
        local base = "New Style"
        local new_name = base
        local suffix = 2
        while name_in_use(styles, new_name) do
          new_name = base .. " " .. suffix
          suffix = suffix + 1
        end

        local new_s = deep_copy(styles[active_idx])
        new_s.name = new_name
        save_style(new_s)
        table.insert(styles, new_s)

        active_idx = #styles
        buf = deep_copy(new_s)
        reaper.SetExtState("TextOverlayGUI", "active_style", new_name, true)

        rename_pending    = true
        rename_focus_next = true
        rename_idx        = active_idx
        rename_buf        = new_name
        rename_dup_err    = false
      end

      ImGui.EndTabBar(ctx)
    end

    ImGui.Spacing(ctx)

    local single_target = (#targets == 1) and targets[1] or nil

    -- Packs/unpacks this style's 0-1 float RGB triples to/from the 24-bit
    -- packed int ImGui.ColorEdit3 (and the preview canvas below) expect.
    local function rgb_to_packed(r, g, b)
      local ri = math.floor(math.max(0, math.min(1, r)) * 255 + 0.5)
      local gi = math.floor(math.max(0, math.min(1, g)) * 255 + 0.5)
      local bi = math.floor(math.max(0, math.min(1, b)) * 255 + 0.5)
      return (ri << 16) | (gi << 8) | bi
    end
    local function packed_to_rgb(packed)
      return ((packed >> 16) & 0xFF) / 255, ((packed >> 8) & 0xFF) / 255, (packed & 0xFF) / 255
    end

    -- ── Status line ─────────────────────────────────────────
    ImGui.PushStyleColor(ctx, ImGui.Col_TextDisabled, 0xA0A0A0FF)
    if #targets == 0 then
      ImGui.Text(ctx, "No overlay item selected -- editing style \"" .. styles[active_idx].name .. "\"")
    elseif #targets == 1 then
      ImGui.Text(ctx, "Editing 1 selected overlay item")
    else
      ImGui.Text(ctx, "Editing " .. #targets .. " selected overlay items (text left untouched)")
    end
    ImGui.PopStyleColor(ctx)
    ImGui.Spacing(ctx)

    -- ── Left column: fields ──────────────────────────────────
    local LEFT_W = 320
    ImGui.BeginGroup(ctx)

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, "TEXT")
    ImGui.PopStyleColor(ctx)

    -- Disabled only for multi-item batches (each item's own text stays
    -- untouched there) or while Show Timecode overrides it -- otherwise
    -- stays editable with zero targets too, since that's exactly the
    -- buffer "Add Text Overlay" will stamp onto a brand new item.
    local text_disabled = (#targets > 1) or buf.show_tc
    if text_disabled then ImGui.BeginDisabled(ctx, true) end
    ImGui.SetNextItemWidth(ctx, LEFT_W)
    local text_changed, new_text = ImGui.InputText(ctx, "##overlay_text", buf.text)
    if text_changed then
      buf.text = new_text
      if single_target then SetOverlayText(single_target.item, new_text) end
    end
    if text_disabled then ImGui.EndDisabled(ctx) end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) and single_target then
      commit_undo("Set text overlay text")
    end
    if buf.show_tc and ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Overridden by the live timecode while Show Timecode is on")
    end

    ImGui.Spacing(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, "PREVIEW")
    ImGui.PopStyleColor(ctx)

    -- Live preview: renders the text at its actual size/position/color/
    -- background/shadow against a neutral frame-shaped placeholder,
    -- following the same math as the JSFX itself (size/xpos/ypos/border
    -- are fractions of the frame; shadow_x/y are real output pixels, so
    -- scaled here assuming a ~1080p output -- there's no real video image
    -- to preview against via ReaScript, so this is an approximation of
    -- proportions/placement/color, not a pixel-exact render). Doubles as
    -- the XY position control: click/drag anywhere in the frame to set
    -- xpos/ypos directly, a real WYSIWYG placement control instead of two
    -- abstract sliders (the sliders below remain for precise entry).
    do
      local PAD_W = LEFT_W
      local PAD_H = math.floor(PAD_W * 9 / 16)
      local draw_list = ImGui.GetWindowDrawList(ctx)
      local x0, y0 = ImGui.GetCursorScreenPos(ctx)
      local x1, y1 = x0 + PAD_W, y0 + PAD_H

      ImGui.DrawList_AddRectFilled(draw_list, x0, y0, x1, y1, 0x141414FF, 3)
      ImGui.DrawList_AddRect(draw_list, x0, y0, x1, y1, 0x3F3F3FFF, 3)

      local display_text
      if buf.show_tc then
        display_text = reaper.format_timestr_pos(reaper.GetCursorPosition(), "", 5)
      elseif buf.text ~= "" then
        display_text = buf.text
      else
        display_text = "(no text)"
      end

      local font = get_preview_font(buf.font)
      local font_px = math.max(6, buf.size * PAD_H)
      ImGui.PushFont(ctx, font, font_px)
      local txtw, txth = ImGui.CalcTextSize(ctx, display_text)
      ImGui.PopFont(ctx)

      -- Mirrors the JSFX's own b/yt/xp math exactly, with PAD_W/PAD_H
      -- standing in for project_w/project_h (size/xpos/ypos/border are
      -- already 0-1 fractions of the frame, so no extra scaling needed).
      local b  = buf.border * txth
      local yt = (PAD_H - txth - b * 2) * buf.ypos
      local xp = buf.xpos * (PAD_W - txtw)

      if buf.bg_alpha > 0 then
        local bx0 = buf.bg_fit and (xp - b) or 0
        local bw  = buf.bg_fit and (txtw + b * 2) or PAD_W
        local bg_color = (rgb_to_packed(buf.bg_r, buf.bg_g, buf.bg_b) << 8)
          | math.floor(buf.bg_alpha * 255 + 0.5)
        ImGui.DrawList_AddRectFilled(draw_list, x0 + bx0, y0 + yt, x0 + bx0 + bw, y0 + yt + txth + b * 2, bg_color)
      end

      if buf.shadow then
        -- shadow_x/y are real output pixels (0-10px range), not a 0-1
        -- fraction -- scale to the preview assuming ~1080p output.
        local shadow_scale = PAD_H / 1080
        local sx = buf.shadow_x * shadow_scale
        local sy = buf.shadow_y * shadow_scale
        local shadow_color = math.floor(buf.text_alpha * buf.shadow_alpha * 255 + 0.5)
        ImGui.PushFont(ctx, font, font_px)
        ImGui.DrawList_AddText(draw_list, x0 + xp + sx, y0 + yt + b + sy, shadow_color, display_text)
        ImGui.PopFont(ctx)
      end

      local text_color = (rgb_to_packed(buf.text_r, buf.text_g, buf.text_b) << 8)
        | math.floor(buf.text_alpha * 255 + 0.5)
      ImGui.PushFont(ctx, font, font_px)
      ImGui.DrawList_AddText(draw_list, x0 + xp, y0 + yt + b, text_color, display_text)
      ImGui.PopFont(ctx)

      ImGui.SetCursorScreenPos(ctx, x0, y0)
      ImGui.InvisibleButton(ctx, "##xy_pad", PAD_W, PAD_H)
      if ImGui.IsItemActive(ctx) then
        local mx, my = ImGui.GetMousePos(ctx)
        local dot_x = math.max(0, math.min(1, (mx - x0) / PAD_W))
        local dot_y = math.max(0, math.min(1, (my - y0) / PAD_H))
        if dot_x ~= buf.xpos or dot_y ~= buf.ypos then
          buf.xpos, buf.ypos = dot_x, dot_y
          apply_param_to_targets(targets, "XPOS", dot_x)
          apply_param_to_targets(targets, "YPOS", dot_y)
        end
      end
      if ImGui.IsItemDeactivatedAfterEdit(ctx) and #targets > 0 then
        commit_undo("Set text overlay position")
      end
    end
    ImGui.Spacing(ctx)

    -- ── Slider rows ───────────────────────────────────────────
    local function slider_row(label, key, buf_key, min, max, fmt)
      ImGui.SetNextItemWidth(ctx, LEFT_W)
      local changed, val = ImGui.SliderDouble(ctx, "##" .. buf_key, buf[buf_key], min, max, label .. ": " .. fmt)
      if changed then
        buf[buf_key] = val
        apply_param_to_targets(targets, key, val)
      end
      if ImGui.IsItemDeactivatedAfterEdit(ctx) and #targets > 0 then
        commit_undo("Set text overlay " .. label:lower())
      end
    end

    slider_row("X Position", "XPOS", "xpos", 0, 1, "%.2f")
    slider_row("Y Position", "YPOS", "ypos", 0, 1, "%.2f")

    ImGui.Spacing(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, "SIZE")
    ImGui.PopStyleColor(ctx)
    slider_row("Text Size", "SIZE", "size", 0.01, 0.2, "%.3f")
    slider_row("Background Padding", "BORDER", "border", 0, 1, "%.2f")

    -- ── Checkboxes (declared before use by the color rows' "Fit
    -- Background to Text" placement below) ──────────────────────
    local function checkbox_row(label, key, buf_key, disabled)
      if disabled then ImGui.BeginDisabled(ctx, true) end
      local changed, val = ImGui.Checkbox(ctx, label, buf[buf_key])
      if changed then
        buf[buf_key] = val
        apply_param_to_targets(targets, key, val and 1 or 0)
        if #targets > 0 then commit_undo("Set text overlay " .. label:lower()) end
      end
      if disabled then ImGui.EndDisabled(ctx) end
    end

    local function color_row(label, key_r, key_g, key_b, buf_r, buf_g, buf_b)
      local packed = rgb_to_packed(buf[buf_r], buf[buf_g], buf[buf_b])
      ImGui.SetNextItemWidth(ctx, LEFT_W)
      local changed, new_packed = ImGui.ColorEdit3(ctx, label, packed)
      if changed then
        local r, g, b = packed_to_rgb(new_packed)
        buf[buf_r], buf[buf_g], buf[buf_b] = r, g, b
        apply_param_to_targets(targets, key_r, r)
        apply_param_to_targets(targets, key_g, g)
        apply_param_to_targets(targets, key_b, b)
      end
      if ImGui.IsItemDeactivatedAfterEdit(ctx) and #targets > 0 then
        commit_undo("Set text overlay " .. label:lower())
      end
    end

    ImGui.Spacing(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, "TEXT COLOR")
    ImGui.PopStyleColor(ctx)
    color_row("Color##text_color", "TEXT_R", "TEXT_G", "TEXT_B", "text_r", "text_g", "text_b")
    slider_row("Text Opacity", "TEXT_ALPHA", "text_alpha", 0, 1, "%.2f")

    ImGui.Spacing(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, "BACKGROUND COLOR")
    ImGui.PopStyleColor(ctx)
    color_row("Color##bg_color", "BG_R", "BG_G", "BG_B", "bg_r", "bg_g", "bg_b")
    slider_row("Background Opacity", "BG_ALPHA", "bg_alpha", 0, 1, "%.2f")
    checkbox_row("Fit Background to Text", "BG_FIT", "bg_fit")

    ImGui.Spacing(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, "SHADOW")
    ImGui.PopStyleColor(ctx)
    checkbox_row("Enable Shadow", "SHADOW", "shadow")
    slider_row("Shadow X Offset", "SHADOW_X", "shadow_x", 0, 10, "%.1f px")
    slider_row("Shadow Y Offset", "SHADOW_Y", "shadow_y", 0, 10, "%.1f px")
    slider_row("Shadow Opacity Scale", "SHADOW_ALPHA", "shadow_alpha", 0, 1, "%.2f")

    ImGui.Spacing(ctx)
    checkbox_row("Ignore Input Video", "IGNORE_INPUT", "ignore_input")
    checkbox_row("Show Timecode", "SHOW_TC", "show_tc")
    checkbox_row("Dropframe Timecode", "DROPFRAME_TC", "dropframe_tc", not buf.show_tc)

    ImGui.Spacing(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, "FONT")
    ImGui.PopStyleColor(ctx)

    local font_icon_size = ImGui.GetFontSize(ctx)
    local font_btn_w = theme.IconButtonSize(ctx, font_icon_size)

    ImGui.SetNextItemWidth(ctx, LEFT_W - font_btn_w - 6)
    local font_changed, new_font = ImGui.InputText(ctx, "##overlay_font", buf.font)
    if font_changed then
      buf.font = new_font
      apply_font_to_targets(targets, new_font)
    end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) and #targets > 0 then
      commit_undo("Set text overlay font")
    end

    ImGui.SameLine(ctx, 0, 6)
    if theme.IconButton(ctx, theme.Icons.LIST .. "##font_list_btn", nil, nil, font_icon_size) then
      ImGui.OpenPopup(ctx, "##font_list_popup")
      font_filter = ""
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, #available_fonts > 0
        and "Choose from installed fonts"
        or "No fonts found on this system -- type a name manually")
    end

    if ImGui.BeginPopup(ctx, "##font_list_popup") then
      ImGui.SetNextItemWidth(ctx, 240)
      if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
      local _, new_filter = ImGui.InputTextWithHint(ctx, "##font_filter", "Filter...", font_filter)
      font_filter = new_filter

      ImGui.Separator(ctx)
      if ImGui.BeginChild(ctx, "##font_list_scroll", 240, 220) then
        local filter_lower = font_filter:lower()
        local any_match = false
        for _, name in ipairs(available_fonts) do
          if filter_lower == "" or name:lower():find(filter_lower, 1, true) then
            any_match = true
            if ImGui.Selectable(ctx, name, name == buf.font) then
              buf.font = name
              apply_font_to_targets(targets, name)
              if #targets > 0 then commit_undo("Set text overlay font") end
              ImGui.CloseCurrentPopup(ctx)
            end
          end
        end
        if not any_match then
          ImGui.PushStyleColor(ctx, ImGui.Col_TextDisabled, 0xA0A0A0FF)
          ImGui.Text(ctx, #available_fonts == 0 and "No fonts found" or "No matches")
          ImGui.PopStyleColor(ctx)
        end
        ImGui.EndChild(ctx)
      end
      ImGui.EndPopup(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x7A7A7AFF)
    ImGui.Text(ctx, "NEW ITEM DURATION (used only when no time selection)")
    ImGui.PopStyleColor(ctx)
    ImGui.SetNextItemWidth(ctx, LEFT_W)
    local dur_changed, new_dur = ImGui.SliderDouble(ctx, "##duration", buf.duration, 0.5, 20, "%.1f sec")
    if dur_changed then buf.duration = new_dur end

    if single_target then
      ImGui.Spacing(ctx)
      if theme.IconButton(ctx, theme.Icons.SETTINGS, nil, nil, ImGui.GetFontSize(ctx)) then
        reaper.TakeFX_Show(single_target.take, single_target.fx, 3)
      end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, "Open native FX window (font/code editing, etc.)")
      end
    end

    ImGui.EndGroup(ctx)

    -- ── Bottom actions ────────────────────────────────────────
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    local dirty = style_dirty()
    if not dirty then ImGui.BeginDisabled(ctx, true) end
    if ImGui.Button(ctx, "Update Style \"" .. styles[active_idx].name .. "\"", 220, 0) then
      local s = styles[active_idx]
      for _, k in ipairs(STYLE_FIELDS_ORDER) do
        if k ~= "name" then s[k] = buf[k] end
      end
      save_style(s)
    end
    if not dirty then ImGui.EndDisabled(ctx) end

    ImGui.SameLine(ctx)
    if theme.PrimaryButton(ctx, "Add Text Overlay", -1, 0, nil, theme.Icons.VIDEO) then
      local new_item = CreateOverlayItem(buf)
      if new_item then
        last_sig = nil -- force a re-sync from the new selection next frame
      end
    end

    ImGui.End(ctx)
  end

  -- ── Rename modal ─────────────────────────────────────────
  if rename_pending then
    ImGui.OpenPopup(ctx, "Rename Style##modal")
    rename_pending    = false
    rename_focus_next = true
  end

  if ImGui.BeginPopupModal(ctx, "Rename Style##modal", nil, ImGui.WindowFlags_AlwaysAutoResize) then
    ImGui.Text(ctx, "Style name:")
    ImGui.SetNextItemWidth(ctx, 280)
    if rename_focus_next then
      ImGui.SetKeyboardFocusHere(ctx)
      rename_focus_next = false
    end
    local _, new_rb = ImGui.InputText(ctx, "##rename_val", rename_buf, ImGui.InputTextFlags_AutoSelectAll)
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
      if name_in_use(styles, rename_buf, rename_idx) then
        rename_dup_err = true
      else
        local old_name = styles[rename_idx].name
        if old_name ~= rename_buf then
          rename_style_file(old_name, rename_buf)
          if rename_idx == active_idx then
            reaper.SetExtState("TextOverlayGUI", "active_style", rename_buf, true)
          end
        end
        styles[rename_idx].name = rename_buf
        ImGui.CloseCurrentPopup(ctx)
        rename_dup_err = false
      end
    end

    ImGui.EndPopup(ctx)
  end

  -- ── Pending delete ────────────────────────────────────────
  if delete_pending then
    delete_pending = false
    local name = styles[delete_idx] and styles[delete_idx].name or "?"
    local answer = reaper.ShowMessageBox(
      ('Delete style "%s"? This cannot be undone.'):format(name),
      "Text Overlay", 4)
    if answer == 6 then
      delete_style(name)
      table.remove(styles, delete_idx)
      if active_idx > delete_idx then active_idx = active_idx - 1 end
      active_idx = math.max(1, math.min(active_idx, #styles))
      buf = deep_copy(styles[active_idx])
    end
  end

  theme.Pop(ctx, color_count, var_count)

  if still_open then
    reaper.defer(loop)
  end
end

-- ============================================================
-- Entry point
-- ============================================================
reaper.defer(loop)
