-- @description Find and Select Items by Name on Selected Tracks
-- @author Stephen Schappler
-- @version 1.1
-- @about
--   Find and Select Items by Name on Selected Tracks
-- @link https://www.stephenschappler.com
-- @changelog 
--   10/31/24 - v1.0 - Updatng the script to use ReaImGUI

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("ReaImGui is required for this script.", "Missing Dependency", 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require "imgui" "0.10"

local script_title = "Find and Select Items by Name"
local ctx = ImGui.CreateContext(script_title)
local search_string = ""
local status_msg = ""

local function run_search()
  if search_string == "" then
    status_msg = "Enter a search string."
    return
  end

  reaper.Undo_BeginBlock()
  reaper.Main_OnCommand(40289, 0) -- Unselect all items

  local selected_items = 0
  local track_count = reaper.CountSelectedTracks(0)
  for t = 0, track_count - 1 do
    local track = reaper.GetSelectedTrack(0, t)
    local item_count = reaper.CountTrackMediaItems(track)
    for i = 0, item_count - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      local take = reaper.GetMediaItemTake(item, 0)
      if take then
        local item_name = reaper.GetTakeName(take)
        if item_name:find(search_string) then
          reaper.SetMediaItemSelected(item, true)
          selected_items = selected_items + 1
        end
      end
    end
  end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Select Items by Name on Selected Tracks", -1)

  status_msg = ("Selected %d item%s."):format(selected_items, selected_items == 1 and "" or "s")
end

local function loop()
  local visible, open = ImGui.Begin(ctx, script_title, true)
  if visible then
    ImGui.Text(ctx, "Find items on selected tracks by take name.")
    ImGui.Spacing(ctx)
    ImGui.SetNextItemWidth(ctx, -1)
    local input_flags = ImGui.InputTextFlags_EnterReturnsTrue
    local enter_pressed, new_value = ImGui.InputText(ctx, "##search", search_string, input_flags)
    search_string = new_value
    if enter_pressed then
      run_search()
    end

    if ImGui.Button(ctx, "Find and Select") then
      run_search()
    end

    local window_focused = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)
    if window_focused and (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)) then
      run_search()
    end
    if status_msg ~= "" then
      ImGui.Spacing(ctx)
      ImGui.Text(ctx, status_msg)
    end
    ImGui.End(ctx)
  end

  if open then
    reaper.defer(loop)
  end
end

reaper.defer(loop)
