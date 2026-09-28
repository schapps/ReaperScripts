-- @description Selected Items Counter
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   ReaImGUI status window that shows how many items are selected, updating
--   live as the selection changes. Keep it open (or docked) while working.
--   Set an optional Target to track progress toward a minimum count, e.g.
--   20 variations per action; the count turns green once the target is met.
--   Requires: Schapps Script Resources (install from this repository first).
-- @link https://www.stephenschappler.com
-- @changelog
--   09/28/26 - v1.0 Initial release



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
local _, script_path, section_id, cmd_id = reaper.get_action_context()
local script_dir  = script_path:match("^(.*[/\\])")
local theme_path  = script_dir .. "Common/ReaImGuiTheme.lua"
if not reaper.file_exists(theme_path) then
  theme_path = script_dir .. "../Common/ReaImGuiTheme.lua"
end
local theme = dofile(theme_path)

-- ============================================================
-- Context + state variables
-- ============================================================
local script_title  = "SELECTED ITEMS"
local ctx           = ImGui.CreateContext(script_title)
local EXT_SECTION   = "SelectedItemsCounter"

local WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
               | ImGui.WindowFlags_NoCollapse
               | ImGui.WindowFlags_NoScrollWithMouse

local COLOR_DIM     = 0xA0A0A0FF
local COLOR_PENDING = 0xE0B050FF -- below target
local COLOR_MET     = 0x7BC47FFF -- target reached
local COUNT_SIZE    = 56

local target = math.max(0, math.floor(tonumber(reaper.GetExtState(EXT_SECTION, "Target")) or 0))

-- ============================================================
-- Helpers
-- ============================================================

-- Draws `text` horizontally centered in the remaining content width.
local function centeredText(text, color)
  local text_w = ImGui.CalcTextSize(ctx, text)
  local avail_w = ImGui.GetContentRegionAvail(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + math.max(0, (avail_w - text_w) / 2))
  if color then
    ImGui.TextColored(ctx, color, text)
  else
    ImGui.Text(ctx, text)
  end
end

-- Light up the toolbar button while the window is open.
local function setToggleState(state)
  reaper.SetToggleCommandState(section_id, cmd_id, state)
  reaper.RefreshToolbar2(section_id, cmd_id)
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  local count = reaper.CountSelectedMediaItems(0)
  local has_target = target > 0
  local met = has_target and count >= target

  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSize(ctx, 240, 200, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then
    -- ---- Big count ----
    theme.PushBoldFont(ctx, COUNT_SIZE)
    local count_color = nil
    if has_target then count_color = met and COLOR_MET or COLOR_PENDING end
    centeredText(tostring(count), count_color)
    theme.PopBoldFont(ctx)

    centeredText(count == 1 and "item selected" or "items selected", COLOR_DIM)

    -- ---- Target progress ----
    if has_target then
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_PlotHistogram, met and COLOR_MET or COLOR_PENDING)
      ImGui.ProgressBar(ctx, math.min(count / target, 1), -1, 0, ("%d / %d"):format(count, target))
      ImGui.PopStyleColor(ctx)
      if met then
        centeredText("Target met", COLOR_MET)
      else
        local needed = target - count
        centeredText(("%d more needed"):format(needed), COLOR_DIM)
      end
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- ---- Target input ----
    ImGui.SetNextItemWidth(ctx, 110)
    local changed, new_target = ImGui.InputInt(ctx, "Target##target", target)
    if changed then
      target = math.max(0, new_target)
      reaper.SetExtState(EXT_SECTION, "Target", tostring(target), true)
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Minimum number of items you need selected.\nSet to 0 to turn the target off.")
    end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)

  if open then
    reaper.defer(loop)
  end
end

-- ============================================================
-- Entry point
-- ============================================================
setToggleState(1)
reaper.atexit(function() setToggleState(0) end)
reaper.defer(loop)
