-- @description Find And Select Items
-- @author Stephen Schappler
-- @version 1.1
-- @about
--   ReaImGUI interface for finding and selecting items by any combination of:
--   name, color, channel count, subproject status, and edit cursor position.
--   Enabled filters are combined with AND logic. Scope can be limited to
--   selected tracks.
--   Requires: Schapps Script Resources (install from this repository first).
-- @link https://www.stephenschappler.com
-- @changelog
--   6/29/26 - v1.1 Added Edit Cursor position, pitch, and rate filters.
--   6/29/26 - v1.0 Initial release

-- ============================================================
-- ReaImGUI dependency check + bootstrap
-- ============================================================
if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("ReaImGui is required for this script.", "Missing Dependency", 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

-- ============================================================
-- Theme module
-- ============================================================
local script_path = ({reaper.get_action_context()})[2]
local script_dir  = script_path:match("^(.*[/\\])")
local theme_path  = script_dir .. "Common/ReaImGuiTheme.lua"
if not reaper.file_exists(theme_path) then
  theme_path = script_dir .. "../Common/ReaImGuiTheme.lua"
end
local theme = dofile(theme_path)

-- ============================================================
-- Context + constants
-- ============================================================
local script_title = "FIND AND SELECT ITEMS"
local ctx = ImGui.CreateContext(script_title)

local WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
               | ImGui.WindowFlags_NoCollapse
               | ImGui.WindowFlags_AlwaysAutoResize
               | ImGui.WindowFlags_NoScrollWithMouse

local EXT = "FindItems"

local SCOPE_PROJECT = 0
local SCOPE_TRACKS  = 1
local SCOPE_LABELS  = {"Entire Project", "Selected Track(s)"}

-- ============================================================
-- Persistent state helpers
-- ============================================================
local function getBool(key, default)
  local v = reaper.GetExtState(EXT, key)
  if v == "" then return default end
  return v == "true"
end

local function getNum(key, default)
  local v = reaper.GetExtState(EXT, key)
  return v ~= "" and tonumber(v) or default
end

-- ============================================================
-- State
-- ============================================================
local scope         = getNum("Scope",   SCOPE_PROJECT)

-- Filter: Name
local name_enabled  = getBool("NameEnabled", false)
local search_buf    = reaper.GetExtState(EXT, "NameSearch")  -- "" if never set
local case_sens     = getBool("NameCase",    false)

-- Filter: Color
local color_enabled = getBool("ColorEnabled", false)
local target_color  = getNum("Color", 0x00AA00)

-- Filter: Channel Count
local ch_enabled    = getBool("ChEnabled", false)
local ch_value      = getNum("ChValue",    2)

-- Filter: Subproject  (combo: 0=Subproject, 1=Not Subproject)
local subproj_enabled = getBool("SubprojEnabled", false)
local subproj_combo   = getNum("SubprojCombo",    0)

-- Filter: Playback Rate changed from default (1.0)
local rate_enabled    = getBool("RateEnabled",  false)

-- Filter: Playback Pitch changed from default (0.0)
local pitch_enabled   = getBool("PitchEnabled", false)

-- Filter: Edit Cursor position  (combo: 0=Before, 1=After)
local cursor_enabled  = getBool("CursorEnabled", false)
local cursor_combo    = getNum("CursorCombo",    0)

local status_msg = ""

-- ============================================================
-- Color conversion helpers
-- ============================================================
local function imgui_to_native(packed)
  return reaper.ColorToNative((packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF)
end

local function native_to_imgui(native)
  local r, g, b = reaper.ColorFromNative(native)
  return (r << 16) | (g << 8) | b
end

-- ============================================================
-- Capture helpers
-- ============================================================
local function captureItemName()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    status_msg = "No item selected"
    return
  end
  local take = reaper.GetActiveTake(item)
  if not take then
    status_msg = "No active take on selected item"
    return
  end
  search_buf = reaper.GetTakeName(take)
  reaper.SetExtState(EXT, "NameSearch", search_buf, true)
  status_msg = "Name captured from selected item"
end

local function captureColor()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    status_msg = "No item selected"
    return
  end
  target_color = native_to_imgui(reaper.GetDisplayedMediaItemColor(item))
  reaper.SetExtState(EXT, "Color", tostring(target_color), true)
  status_msg = "Color captured from selected item"
end

-- ============================================================
-- Core find-and-select logic
-- ============================================================
local function findAndSelect()
  local any = name_enabled or color_enabled or ch_enabled or subproj_enabled
           or rate_enabled or pitch_enabled or cursor_enabled
  if not any then
    status_msg = "Enable at least one filter"
    return
  end
  if name_enabled and search_buf == "" then
    status_msg = "Name filter: enter a search string"
    return
  end

  local needle     = name_enabled  and (case_sens and search_buf or search_buf:lower()) or nil
  local native_tgt = color_enabled and (imgui_to_native(target_color) & 0xFFFFFF)       or nil
  local cursor_pos = cursor_enabled and reaper.GetCursorPosition()                       or nil

  local selected_tracks
  if scope == SCOPE_TRACKS then
    selected_tracks = {}
    for i = 0, reaper.CountSelectedTracks(0) - 1 do
      selected_tracks[reaper.GetSelectedTrack(0, i)] = true
    end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  reaper.Main_OnCommand(40289, 0)  -- Item: Unselect all items

  local count = 0
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    if not selected_tracks or selected_tracks[reaper.GetMediaItem_Track(item)] then
      local ok = true

      -- Edit cursor position filter
      if ok and cursor_enabled then
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        ok = cursor_combo == 0 and item_pos < cursor_pos
          or cursor_combo == 1 and item_pos >= cursor_pos
      end

      -- Color filter
      if ok and color_enabled then
        ok = (reaper.GetDisplayedMediaItemColor(item) & 0xFFFFFF) == native_tgt
      end

      -- Subproject filter (checks all takes for a .rpp source)
      if ok and subproj_enabled then
        local is_sub = false
        for j = 0, reaper.CountTakes(item) - 1 do
          local t = reaper.GetTake(item, j)
          if t then
            local src = reaper.GetMediaItemTake_Source(t)
            if src then
              local fn = reaper.GetMediaSourceFileName(src, "")
              if fn:lower():find("%.rpp", 1, false) then
                is_sub = true
                break
              end
            end
          end
        end
        ok = is_sub == (subproj_combo == 0)
      end

      -- Take-based filters
      if ok and (name_enabled or ch_enabled or rate_enabled or pitch_enabled) then
        local take = reaper.GetActiveTake(item)
        if not take then
          ok = false
        else
          -- Name
          if ok and name_enabled then
            local n = reaper.GetTakeName(take)
            if not case_sens then n = n:lower() end
            ok = n:find(needle, 1, true) ~= nil
          end
          -- Channel count
          if ok and ch_enabled then
            local src = reaper.GetMediaItemTake_Source(take)
            ok = src and reaper.GetMediaSourceNumChannels(src) == ch_value
          end
          -- Playback rate
          if ok and rate_enabled then
            ok = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") ~= 1.0
          end
          -- Playback pitch
          if ok and pitch_enabled then
            ok = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH") ~= 0.0
          end
        end
      end

      if ok then
        reaper.SetMediaItemSelected(item, true)
        count = count + 1
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Find and select items", -1)

  status_msg = count > 0
    and (count .. (count == 1 and " item" or " items") .. " selected")
    or "No matching items found"
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  local cc, vc = theme.Push(ctx)
  ImGui.SetNextWindowSizeConstraints(ctx, 320, 0, 9999, 9999)
  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then

    -- ── Name ─────────────────────────────────────────────────
    do
      local ch, v = ImGui.Checkbox(ctx, "##name_en", name_enabled)
      if ch then
        name_enabled = v
        reaper.SetExtState(EXT, "NameEnabled", tostring(v), true)
        status_msg = ""
      end
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, "Name")
      ImGui.SameLine(ctx)
      if not name_enabled then ImGui.BeginDisabled(ctx, true) end
      local cs_ch, cs_v = ImGui.Checkbox(ctx, "Case Sensitive", case_sens)
      if cs_ch then
        case_sens = cs_v
        reaper.SetExtState(EXT, "NameCase", tostring(cs_v), true)
        status_msg = ""
      end
      if not name_enabled then ImGui.EndDisabled(ctx) end

      if not name_enabled then ImGui.BeginDisabled(ctx, true) end
      ImGui.SetNextItemWidth(ctx, -1)
      local _, nb = ImGui.InputTextWithHint(ctx, "##search", "search by take name", search_buf)
      if nb ~= search_buf then
        search_buf = nb
        reaper.SetExtState(EXT, "NameSearch", nb, true)
        status_msg = ""
      end
      if ImGui.Button(ctx, "Capture Selected Item's Name", -1, 0) then
        captureItemName()
      end
      if not name_enabled then ImGui.EndDisabled(ctx) end
    end

    ImGui.Spacing(ctx)

    -- ── Color ─────────────────────────────────────────────────
    do
      local ch, v = ImGui.Checkbox(ctx, "##color_en", color_enabled)
      if ch then
        color_enabled = v
        reaper.SetExtState(EXT, "ColorEnabled", tostring(v), true)
        status_msg = ""
      end
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, "Color")

      if not color_enabled then ImGui.BeginDisabled(ctx, true) end
      ImGui.SetNextItemWidth(ctx, -1)
      local col_ch, nc = ImGui.ColorEdit3(ctx, "##color", target_color,
        ImGui.ColorEditFlags_DisplayHex | ImGui.ColorEditFlags_PickerHueWheel)
      if col_ch then
        target_color = nc
        reaper.SetExtState(EXT, "Color", tostring(nc), true)
      end
      if ImGui.Button(ctx, "Capture Selected Item's Color", -1, 0) then
        captureColor()
      end
      if not color_enabled then ImGui.EndDisabled(ctx) end
    end

    ImGui.Spacing(ctx)

    -- ── Channel Count ─────────────────────────────────────────
    do
      local ch, v = ImGui.Checkbox(ctx, "##ch_en", ch_enabled)
      if ch then
        ch_enabled = v
        reaper.SetExtState(EXT, "ChEnabled", tostring(v), true)
        status_msg = ""
      end
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, "Channels:")
      ImGui.SameLine(ctx)
      if not ch_enabled then ImGui.BeginDisabled(ctx, true) end
      ImGui.SetNextItemWidth(ctx, -1)
      local iv_ch, nv = ImGui.InputInt(ctx, "##ch_val", ch_value, 1, 2)
      if iv_ch then
        ch_value = math.max(1, nv)
        reaper.SetExtState(EXT, "ChValue", tostring(ch_value), true)
        status_msg = ""
      end
      if not ch_enabled then ImGui.EndDisabled(ctx) end
    end

    ImGui.Spacing(ctx)

    -- ── Subproject ────────────────────────────────────────────
    do
      local ch, v = ImGui.Checkbox(ctx, "##subproj_en", subproj_enabled)
      if ch then
        subproj_enabled = v
        reaper.SetExtState(EXT, "SubprojEnabled", tostring(v), true)
        status_msg = ""
      end
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, "Subproject:")
      ImGui.SameLine(ctx)
      if not subproj_enabled then ImGui.BeginDisabled(ctx, true) end
      ImGui.SetNextItemWidth(ctx, -1)
      local sp_ch, sv = ImGui.Combo(ctx, "##subproj_val", subproj_combo,
        "Subproject\0Not Subproject\0")
      if sp_ch then
        subproj_combo = sv
        reaper.SetExtState(EXT, "SubprojCombo", tostring(sv), true)
        status_msg = ""
      end
      if not subproj_enabled then ImGui.EndDisabled(ctx) end
    end

    ImGui.Spacing(ctx)

    -- ── Playback Rate ─────────────────────────────────────────
    do
      local ch, v = ImGui.Checkbox(ctx, "Playback Rate Changed", rate_enabled)
      if ch then
        rate_enabled = v
        reaper.SetExtState(EXT, "RateEnabled", tostring(v), true)
        status_msg = ""
      end
    end

    ImGui.Spacing(ctx)

    -- ── Playback Pitch ────────────────────────────────────────
    do
      local ch, v = ImGui.Checkbox(ctx, "Playback Pitch Changed", pitch_enabled)
      if ch then
        pitch_enabled = v
        reaper.SetExtState(EXT, "PitchEnabled", tostring(v), true)
        status_msg = ""
      end
    end

    ImGui.Spacing(ctx)

    -- ── Edit Cursor ───────────────────────────────────────────
    do
      local ch, v = ImGui.Checkbox(ctx, "##cursor_en", cursor_enabled)
      if ch then
        cursor_enabled = v
        reaper.SetExtState(EXT, "CursorEnabled", tostring(v), true)
        status_msg = ""
      end
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, "Edit Cursor:")
      ImGui.SameLine(ctx)
      if not cursor_enabled then ImGui.BeginDisabled(ctx, true) end
      ImGui.SetNextItemWidth(ctx, -1)
      local cu_ch, cv = ImGui.Combo(ctx, "##cursor_val", cursor_combo,
        "Before Edit Cursor\0After Edit Cursor\0")
      if cu_ch then
        cursor_combo = cv
        reaper.SetExtState(EXT, "CursorCombo", tostring(cv), true)
        status_msg = ""
      end
      if not cursor_enabled then ImGui.EndDisabled(ctx) end
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- ── Scope ─────────────────────────────────────────────────
    ImGui.Text(ctx, "Scope")
    ImGui.SetNextItemWidth(ctx, -1)
    local sc_ch, sv = ImGui.Combo(ctx, "##scope", scope,
      table.concat(SCOPE_LABELS, "\0") .. "\0")
    if sc_ch then
      scope = sv
      reaper.SetExtState(EXT, "Scope", tostring(sv), true)
      status_msg = ""
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- ── Status ────────────────────────────────────────────────
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    local total = reaper.CountMediaItems(0)
    ImGui.Text(ctx, status_msg ~= "" and status_msg or (total .. " total items in project"))
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)

    -- ── Find and Select ───────────────────────────────────────
    local any_active = name_enabled or color_enabled or ch_enabled or subproj_enabled
                    or rate_enabled or pitch_enabled or cursor_enabled
    local name_empty = name_enabled and search_buf == ""
    local btn_disabled = not any_active or name_empty

    if btn_disabled then ImGui.BeginDisabled(ctx, true) end
    local clicked = ImGui.Button(ctx, "Find and Select", -1, 0)
    if btn_disabled then ImGui.EndDisabled(ctx) end

    local focused = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)
    local enter = focused and
      (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter))

    if (clicked or enter) and not btn_disabled then
      findAndSelect()
    end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, cc, vc)
  if still_open then reaper.defer(loop) end
end

-- ============================================================
-- Entry point
-- ============================================================
reaper.defer(loop)
