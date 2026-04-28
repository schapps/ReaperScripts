-- @description Set Selected Tracks Channel Count
-- @author Stephen Schappler
-- @version 1.1
-- @about
--   Sets all selected tracks' channel count to a chosen value.
--   Channel count is selected from a dropdown (even values 2–128).
-- @link https://www.stephenschappler.com
-- @provides
--   [nomain] ../Common/ReaImGuiTheme.lua > Common/ReaImGuiTheme.lua
-- @changelog
--   4/27/26 - v1.1 Adding provides for ReaImGui Theme
--   4/24/26 - v1.0 Initial release

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

-- Even channel values 2–128
local channel_values = {}
for v = 2, 128, 2 do
  channel_values[#channel_values + 1] = v
end

local ctx       = ImGui.CreateContext("SET TRACK CHANNELS")
local WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
                | ImGui.WindowFlags_NoCollapse
                | ImGui.WindowFlags_AlwaysAutoResize
                | ImGui.WindowFlags_NoScrollWithMouse

local chan_idx = tonumber(reaper.GetExtState("SetTracksChannelCount", "ChannelIdx")) or 1

local function applyChannelCount()
  local count = channel_values[chan_idx]
  reaper.Undo_BeginBlock()
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", count)
  end
  reaper.Undo_EndBlock("Set selected tracks channel count to " .. count, -1)
end

local function loop()
  local color_count, var_count = theme.Push(ctx)
  local visible, open = ImGui.Begin(ctx, "SET TRACK CHANNELS", true, WIN_FLAGS)

  if visible then
    -- Status line
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    local cur_sel   = reaper.CountSelectedTracks(0)
    local track_word = cur_sel == 1 and "track" or "tracks"
    ImGui.Text(ctx, ("%d %s selected"):format(cur_sel, track_word))
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Channels label + dropdown
    ImGui.Text(ctx, "Channels")
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 100)
    if ImGui.BeginCombo(ctx, "##channels", tostring(channel_values[chan_idx])) then
      for i, v in ipairs(channel_values) do
        if ImGui.Selectable(ctx, tostring(v), chan_idx == i) then
          chan_idx = i
          reaper.SetExtState("SetTracksChannelCount", "ChannelIdx", tostring(chan_idx), true)
        end
        if chan_idx == i then ImGui.SetItemDefaultFocus(ctx) end
      end
      ImGui.EndCombo(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Apply button (disabled when no tracks selected)
    local no_tracks = cur_sel == 0
    if no_tracks then ImGui.BeginDisabled(ctx, true) end
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x2C6B64FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x338077FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x2A5C56FF)
    if ImGui.Button(ctx, "Apply", -1, 0) then
      applyChannelCount()
    end
    ImGui.PopStyleColor(ctx, 3)
    if no_tracks then ImGui.EndDisabled(ctx) end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
