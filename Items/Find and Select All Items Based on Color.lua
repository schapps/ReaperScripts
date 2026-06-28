-- @description Find and Select All Items Based on Color
-- @author Stephen Schappler
-- @version 2.2
-- @about
--   ReaImGUI interface for finding and selecting all items in the project
--   that match a chosen color. Use the color picker to set a target color,
--   or capture it directly from a selected item.
--   Requires: Schapps Script Resources (install from this repository first).
-- @link https://www.stephenschappler.com
-- @changelog
--   6/28/26 - v2.2 Add Scope dropdown (Entire Project / Selected Track(s))
--   6/28/26 - v2.1 Fix window resize animation and color matching
--   6/28/26 - v2.0 ReaImGUI interface with color picker and capture button
--   7/29/24 - v1.0 Initial release (headless, hardcoded color)

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
-- Context + state
-- ============================================================
local script_title = "FIND ITEMS BY COLOR"
local ctx = ImGui.CreateContext(script_title)

local WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
               | ImGui.WindowFlags_NoCollapse
               | ImGui.WindowFlags_AlwaysAutoResize
               | ImGui.WindowFlags_NoScrollWithMouse

-- Color stored as packed 0xRRGGBB for ImGui.ColorEdit3
local saved_color = reaper.GetExtState("FindItemsByColor", "TargetColor")
local target_color = (saved_color ~= "" and tonumber(saved_color)) or 0x00AA00

local SCOPE_PROJECT  = 0
local SCOPE_TRACKS   = 1
local SCOPE_ITEMS    = {"Entire Project", "Selected Track(s)"}

local saved_scope = reaper.GetExtState("FindItemsByColor", "Scope")
local scope = (saved_scope ~= "" and tonumber(saved_scope)) or SCOPE_PROJECT

local status_msg = ""

-- ============================================================
-- Color conversion helpers
-- ============================================================
local function imgui_to_reaper_native(packed)
  local r = (packed >> 16) & 0xFF
  local g = (packed >> 8)  & 0xFF
  local b =  packed        & 0xFF
  return reaper.ColorToNative(r, g, b)
end

local function reaper_native_to_imgui(native)
  local r, g, b = reaper.ColorFromNative(native)
  return (r << 16) | (g << 8) | b
end

-- ============================================================
-- Core logic
-- ============================================================
local function findAndSelect()
  -- GetDisplayedMediaItemColor returns the native color with the 0x01000000
  -- custom-color flag bit set; ColorToNative does not include it.
  -- Mask both sides to the lower 24 bits so they compare equal.
  local native_target = imgui_to_reaper_native(target_color) & 0xFFFFFF

  -- Build a set of selected tracks when scope is limited to tracks
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
    if selected_tracks == nil or selected_tracks[reaper.GetMediaItem_Track(item)] then
      if (reaper.GetDisplayedMediaItemColor(item) & 0xFFFFFF) == native_target then
        reaper.SetMediaItemSelected(item, true)
        count = count + 1
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Find and select items by color", -1)

  local word = count == 1 and "item" or "items"
  status_msg = count > 0
    and (count .. " " .. word .. " selected")
    or "No matching items found"
end

local function captureFromSelectedItem()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    status_msg = "No item selected"
    return
  end
  local native = reaper.GetDisplayedMediaItemColor(item)
  target_color = reaper_native_to_imgui(native)
  reaper.SetExtState("FindItemsByColor", "TargetColor", tostring(target_color), true)
  status_msg = "Color captured from selected item"
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSizeConstraints(ctx, 280, 0, 9999, 9999)
  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then
    -- Color picker
    ImGui.SetNextItemWidth(ctx, -1)
    local changed, new_color = ImGui.ColorEdit3(ctx, "##color", target_color,
      ImGui.ColorEditFlags_DisplayHex | ImGui.ColorEditFlags_PickerHueWheel)
    if changed then
      target_color = new_color
      reaper.SetExtState("FindItemsByColor", "TargetColor", tostring(target_color), true)
    end

    ImGui.Spacing(ctx)

    -- Capture button
    if ImGui.Button(ctx, "Capture Selected Item's Color", -1, 0) then
      captureFromSelectedItem()
    end

    ImGui.Spacing(ctx)

    -- Scope dropdown
    ImGui.SetNextItemWidth(ctx, -1)
    local scope_changed, new_scope = ImGui.Combo(ctx, "##scope", scope,
      table.concat(SCOPE_ITEMS, "\0") .. "\0")
    if scope_changed then
      scope = new_scope
      reaper.SetExtState("FindItemsByColor", "Scope", tostring(scope), true)
      status_msg = ""
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Status line
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    local total = reaper.CountMediaItems(0)
    ImGui.Text(ctx, status_msg ~= "" and status_msg or (total .. " total items in project"))
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)

    -- Find and Select button
    if ImGui.Button(ctx, "Find and Select", -1, 0) then
      findAndSelect()
    end

    ImGui.End(ctx)
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
