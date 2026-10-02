-- @description Selected Items Counter (compact)
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   One-row version of Selected Items Counter, sized to fit beside a REAPER
--   toolbar: the whole window is 30pt tall, which ReaImGui scales with the
--   UI the same way toolbar buttons scale (30/45/60px at 100/150/200%).
--   Shows the live selected item count, and with a Target set, the count
--   out of the target plus a small progress bar; the count turns green once
--   the target is met. The Target is shared with Selected Items Counter.
--   Right-click the counter to set the Target, dock/undock it, or close it.
--   Requires: Schapps Script Resources (install from this repository first).
-- @link https://www.stephenschappler.com
-- @changelog
--   10/02/26 - v1.0 Initial release

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
local script_title  = "SELECTED ITEMS (COMPACT)"
local ctx           = ImGui.CreateContext(script_title)
local EXT_SECTION   = "SelectedItemsCounter"          -- shared with the full counter
local EXT_COMPACT   = "SelectedItemsCounterCompact"

local WIN_FLAGS = ImGui.WindowFlags_NoTitleBar
               | ImGui.WindowFlags_NoScrollbar
               | ImGui.WindowFlags_NoCollapse
               | ImGui.WindowFlags_NoScrollWithMouse

local COLOR_DIM     = 0xA0A0A0FF
local COLOR_PENDING = 0xE0B050FF -- below target
local COLOR_MET     = 0x7BC47FFF -- target reached
local COLOR_BAR_BG  = 0x3A3A3AFF

-- Every size here is in ReaImGui points, which scale with REAPER's UI
-- scale exactly like toolbar buttons do, so 30 matches a toolbar row at
-- every DPI.
local HEIGHT     = 30
local PAD_X      = 8
local GAP        = 6
local COUNT_SIZE = 18
local BAR_W      = 56
local BAR_H      = 6

local target    = math.max(0, math.floor(tonumber(reaper.GetExtState(EXT_SECTION, "Target")) or 0))
local last_dock = tonumber(reaper.GetExtState(EXT_COMPACT, "LastDock")) or -1

-- Row width measured at the end of each frame; the floating window is
-- sized to it on the next one. Seeded with a guess for the first frame.
local row_w       = 120
local is_docked   = false
local set_dock_id = nil
local close_req   = false

-- ============================================================
-- Helpers
-- ============================================================

-- Centers the next item of height `h` vertically in the window. Called
-- after SameLine too, which would otherwise snap it to the line's top.
local function centerY(h)
  ImGui.SetCursorPosY(ctx, math.floor((ImGui.GetWindowHeight(ctx) - h) / 2))
end

local function textCentered(text, color)
  local _, h = ImGui.CalcTextSize(ctx, text)
  centerY(h)
  if color then
    ImGui.TextColored(ctx, color, text)
  else
    ImGui.Text(ctx, text)
  end
end

-- Thin rounded progress bar on the draw list; ImGui.ProgressBar's frame
-- padding can't be squeezed this small.
local function miniBar(fraction, color)
  centerY(BAR_H)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + BAR_W, y + BAR_H, COLOR_BAR_BG, BAR_H / 2)
  if fraction > 0 then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + BAR_W * fraction, y + BAR_H, color, BAR_H / 2)
  end
  ImGui.Dummy(ctx, BAR_W, BAR_H)
end

-- Light up the toolbar button while the window is open.
local function setToggleState(state)
  reaper.SetToggleCommandState(section_id, cmd_id, state)
  reaper.RefreshToolbar2(section_id, cmd_id)
end

local function drawContextMenu()
  if not ImGui.BeginPopupContextWindow(ctx, "##ctx") then return end

  ImGui.SetNextItemWidth(ctx, 110)
  local changed, new_target = ImGui.InputInt(ctx, "Target##target", target)
  if changed then
    target = math.max(0, new_target)
    reaper.SetExtState(EXT_SECTION, "Target", tostring(target), true)
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "Minimum number of items you need selected.\nSet to 0 to turn the target off.")
  end

  ImGui.Separator(ctx)

  -- Docking goes through the menu since there's no title bar to drag.
  -- Undocking remembers which docker it was in, so Dock puts it back there.
  if is_docked then
    if ImGui.MenuItem(ctx, "Undock") then
      last_dock = ImGui.GetWindowDockID(ctx)
      reaper.SetExtState(EXT_COMPACT, "LastDock", tostring(last_dock), true)
      set_dock_id = 0
    end
  else
    if ImGui.MenuItem(ctx, "Dock") then set_dock_id = last_dock end
  end
  if ImGui.MenuItem(ctx, "Close") then close_req = true end

  ImGui.EndPopup(ctx)
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  local count = reaper.CountSelectedMediaItems(0)
  local has_target = target > 0
  local met = has_target and count >= target
  local status_color = has_target and (met and COLOR_MET or COLOR_PENDING) or nil

  local color_count, var_count = theme.Push(ctx)
  -- ImGui's default 32pt minimum window size would hold the window above
  -- HEIGHT, and the theme's vertical window padding would eat into it.
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowMinSize, 1, 1)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, PAD_X, 0)

  -- A docked window takes its size from REAPER's docker; only the floating
  -- one is pinned to the row.
  if not is_docked then
    ImGui.SetNextWindowSize(ctx, row_w + PAD_X * 2, HEIGHT, ImGui.Cond_Always)
  end
  if set_dock_id then
    ImGui.SetNextWindowDockID(ctx, set_dock_id)
    set_dock_id = nil
  end

  local flags = WIN_FLAGS | (is_docked and 0 or ImGui.WindowFlags_NoResize)
  local visible, open = ImGui.Begin(ctx, script_title, true, flags)
  -- Popped right away: Begin has already applied them to this window, and
  -- leaving them pushed would squash the right-click menu's padding too.
  ImGui.PopStyleVar(ctx, 2)

  if visible then
    is_docked = ImGui.IsWindowDocked(ctx)

    ImGui.BeginGroup(ctx)

    theme.PushBoldFont(ctx, COUNT_SIZE)
    textCentered(tostring(count), status_color)
    theme.PopBoldFont(ctx)

    ImGui.SameLine(ctx, 0, GAP)
    if has_target then
      textCentered(("/ %d items"):format(target), COLOR_DIM)
      ImGui.SameLine(ctx, 0, GAP + 2)
      miniBar(math.min(count / target, 1), status_color)
    else
      textCentered(count == 1 and "item" or "items", COLOR_DIM)
    end

    ImGui.EndGroup(ctx)
    row_w = ImGui.GetItemRectSize(ctx)

    if ImGui.IsWindowHovered(ctx) and not ImGui.IsPopupOpen(ctx, "##ctx") then
      local tip = count .. (count == 1 and " item selected" or " items selected")
      if has_target then
        tip = tip .. (met and "\nTarget met" or ("\n%d more needed"):format(target - count))
      end
      ImGui.SetTooltip(ctx, tip .. "\n\nRight-click for options")
    end

    drawContextMenu()

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)

  if open and not close_req then
    reaper.defer(loop)
  end
end

-- ============================================================
-- Entry point
-- ============================================================
setToggleState(1)
reaper.atexit(function() setToggleState(0) end)
reaper.defer(loop)
