-- @description Reposition Items
-- @author Stephen Schappler
-- @version 1.1
-- @about
--   Spaces selected items relative to each other. The first item stays in place.
--   "End" mode: gap between each item's end and the next item's start.
--   "Start" mode: gap between each item's start and the next item's start.
--   Supports seconds, frames, and beats as the gap unit.
-- @link https://www.stephenschappler.com
-- @provides
--   [nomain] ../Common/ReaImGuiTheme.lua > Common/ReaImGuiTheme.lua
-- @changelog
--   4/21/26 - v1.1 adding option to shift automation with items 
--   4/21/26 - v1.0 Initial release

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("ReaImGui is required for this script.", "Missing Dependency", 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require "imgui" "0.10"

local script_path = ({reaper.get_action_context()})[2]
local script_dir  = script_path:match("^(.*[/\\])")
local theme_path  = script_dir .. "Common/ReaImGuiTheme.lua"
if not reaper.file_exists(theme_path) then
  theme_path = script_dir .. "../Common/ReaImGuiTheme.lua"
end
local theme = dofile(theme_path)

local ctx        = ImGui.CreateContext("Reposition Items")
local WIN_FLAGS  = ImGui.WindowFlags_NoScrollbar
                 | ImGui.WindowFlags_NoCollapse
                 | ImGui.WindowFlags_AlwaysAutoResize
                 | ImGui.WindowFlags_NoScrollWithMouse

local amount_buf  = "1.0"
local gap_focused  = false
local auto_close   = reaper.GetExtState("RepositionItems", "AutoClose") == "true"
local close_window = false
local unit_idx   = tonumber(reaper.GetExtState("RepositionItems", "UnitIdx"))  or 1
local ref_idx    = tonumber(reaper.GetExtState("RepositionItems", "RefIdx"))   or 2
local unit_items      = {"Seconds", "Frames", "Beats"}
local ref_items       = {"Start", "End"}
local status_msg      = ""
local move_automation = reaper.GetExtState("RepositionItems", "MoveAutomation") == "true"

local function shift_envelopes(track, range_start, range_end, delta)
  for e = 0, reaper.CountTrackEnvelopes(track) - 1 do
    local env = reaper.GetTrackEnvelope(track, e)
    for p = 0, reaper.CountEnvelopePoints(env) - 1 do
      local ok, t, val, shape, tension, sel = reaper.GetEnvelopePoint(env, p)
      if ok and t >= range_start and t <= range_end then
        reaper.SetEnvelopePoint(env, p, t + delta, val, shape, tension, sel, true)
      end
    end
    reaper.Envelope_SortPoints(env)
  end
end

local function gap_to_seconds(amount, unit, anchor_pos)
  if unit == 1 then
    return amount
  elseif unit == 2 then
    local fps = reaper.TimeMap_curFrameRate(0)
    return amount / fps
  else
    local qn = reaper.TimeMap_timeToQN(anchor_pos)
    return reaper.TimeMap_QNToTime(qn + amount) - anchor_pos
  end
end

local function reposition_items()
  local amount = tonumber(amount_buf)
  if not amount then
    status_msg = "Invalid amount."
    return
  end

  local item_count = reaper.CountSelectedMediaItems(0)
  if item_count < 2 then
    status_msg = "Select at least 2 items."
    return
  end

  -- Collect and sort selected items by position
  local items = {}
  for i = 0, item_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    items[#items + 1] = {
      item = item,
      pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
      len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    }
  end
  table.sort(items, function(a, b) return a.pos < b.pos end)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- First item is the anchor; reposition each subsequent item relative to the previous
  for i = 2, #items do
    local prev     = items[i - 1]
    local anchor   = (ref_idx == 1) and prev.pos or (prev.pos + prev.len)
    local gap      = gap_to_seconds(amount, unit_idx, anchor)
    local new_pos  = anchor + gap
    local old_pos  = items[i].pos
    if move_automation then
      local track = reaper.GetMediaItem_Track(items[i].item)
      shift_envelopes(track, old_pos, old_pos + items[i].len, new_pos - old_pos)
    end
    reaper.SetMediaItemPosition(items[i].item, new_pos, false)
    items[i].pos = new_pos  -- update so next item uses the moved position
  end

  reaper.UpdateArrange()
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Reposition Items", -1)

  local moved = item_count - 1
  status_msg = ("Repositioned %d item%s."):format(moved, moved == 1 and "" or "s")
  if auto_close then close_window = true end
end

local function loop()
  local color_count, var_count = theme.Push(ctx)
  local visible, open = ImGui.Begin(ctx, "Reposition Items", true, WIN_FLAGS)

  if visible then
    ImGui.Text(ctx, "Reference")
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 80)
    if ImGui.BeginCombo(ctx, "##ref", ref_items[ref_idx]) then
      for i, v in ipairs(ref_items) do
        if ImGui.Selectable(ctx, v, ref_idx == i) then
          ref_idx = i
          reaper.SetExtState("RepositionItems", "RefIdx", tostring(ref_idx), true)
        end
        if ref_idx == i then ImGui.SetItemDefaultFocus(ctx) end
      end
      ImGui.EndCombo(ctx)
    end

    ImGui.Spacing(ctx)

    ImGui.Text(ctx, "Gap")
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 80)
    if not gap_focused then ImGui.SetKeyboardFocusHere(ctx) end
    local enter_pressed, new_amt = ImGui.InputText(ctx, "##amount", amount_buf,
      ImGui.InputTextFlags_CharsDecimal | ImGui.InputTextFlags_EnterReturnsTrue)
    amount_buf = new_amt
    if not gap_focused then gap_focused = ImGui.IsItemActive(ctx) end
    if enter_pressed then reposition_items() end
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 90)
    if ImGui.BeginCombo(ctx, "##unit", unit_items[unit_idx]) then
      for i, v in ipairs(unit_items) do
        if ImGui.Selectable(ctx, v, unit_idx == i) then
          unit_idx = i
          reaper.SetExtState("RepositionItems", "UnitIdx", tostring(unit_idx), true)
        end
        if unit_idx == i then ImGui.SetItemDefaultFocus(ctx) end
      end
      ImGui.EndCombo(ctx)
    end

    ImGui.Spacing(ctx)

    local _, new_move_auto = ImGui.Checkbox(ctx, "Move automation with item", move_automation)
    if new_move_auto ~= move_automation then
      move_automation = new_move_auto
      reaper.SetExtState("RepositionItems", "MoveAutomation", tostring(move_automation), true)
    end

    local _, new_auto_close = ImGui.Checkbox(ctx, "Auto close after reposition", auto_close)
    if new_auto_close ~= auto_close then
      auto_close = new_auto_close
      reaper.SetExtState("RepositionItems", "AutoClose", tostring(auto_close), true)
    end

    ImGui.Spacing(ctx)

    local too_few = reaper.CountSelectedMediaItems(0) < 2
    if too_few then ImGui.BeginDisabled(ctx, true) end
    if ImGui.Button(ctx, "Reposition", -1, 0) then reposition_items() end
    if too_few then ImGui.EndDisabled(ctx) end

    if status_msg ~= "" then
      ImGui.Spacing(ctx)
      ImGui.Text(ctx, status_msg)
    end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)
  if open and not close_window then reaper.defer(loop) end
end

reaper.defer(loop)
