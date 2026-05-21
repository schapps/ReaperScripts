-- @description Send Source Track to Selected Tracks
-- @version 1.2
-- @about
--   Opens a window to capture one or more source tracks and create sends from
--   them to any selected tracks. Options: Post-Fader or Pre-Fader send mode,
--   and optional sidechain routing to channels 3/4 on the destination.
--   Options are remembered between sessions.
--   Requires: ReaImGUI, Schapps Script Resources (Common/ReaImGuiTheme.lua).
-- @author Stephen Schappler
-- @link https://www.stephenschappler.com
-- @changelog
--   05/21/25 v1.2 - Get Source now captures all selected tracks
--   05/21/25 v1.1 - Set destination track to 4 channels when sidechain is enabled
--   05/21/25 v1.0 - Initial release

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

-- ============================================================
-- Constants
-- ============================================================
local EXT_KEY          = "TrackSendTool"
local SEND_MODE_LABELS = { "Post-Fader", "Pre-Fader" }
local SEND_MODE_VALUES = { 0, 3 }  -- REAPER I_SENDMODE: 0=post-fader, 3=pre-fader (post-fx)

-- ============================================================
-- Context + persisted state
-- ============================================================
local ctx       = ImGui.CreateContext("TRACK SEND TOOL")
local WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
                | ImGui.WindowFlags_NoCollapse
                | ImGui.WindowFlags_NoScrollWithMouse

local send_mode_idx = math.max(1, math.min(2,
  tonumber(reaper.GetExtState(EXT_KEY, "SendModeIdx")) or 1))
local sidechain     = reaper.GetExtState(EXT_KEY, "Sidechain") == "true"

-- Session-only: the captured source tracks
local source_tracks = {}
local source_name   = "Not set"

-- ============================================================
-- Helpers
-- ============================================================
local function isValidTrack(t)
  return t ~= nil and reaper.ValidatePtr(t, "MediaTrack*")
end

local function trackDisplayName(t)
  if not isValidTrack(t) then return "Not set" end
  local _, name = reaper.GetTrackName(t)
  if not name or name == "" then
    local num = math.floor(reaper.GetMediaTrackInfo_Value(t, "IP_TRACKNUMBER"))
    return "Track " .. num
  end
  return name
end

local function hasSendToTrack(src, dst)
  local n = reaper.GetTrackNumSends(src, 0)
  for i = 0, n - 1 do
    if reaper.GetTrackSendInfo_Value(src, 0, i, "P_DESTTRACK") == dst then
      return true
    end
  end
  return false
end

local function saveOptions()
  reaper.SetExtState(EXT_KEY, "SendModeIdx", tostring(send_mode_idx), true)
  reaper.SetExtState(EXT_KEY, "Sidechain",   sidechain and "true" or "false", true)
end

-- ============================================================
-- Actions
-- ============================================================
local function doGetSource()
  local n = reaper.CountSelectedTracks(0)
  if n == 0 then return end
  source_tracks = {}
  for i = 0, n - 1 do
    local t = reaper.GetSelectedTrack(0, i)
    if isValidTrack(t) then source_tracks[#source_tracks + 1] = t end
  end
  if #source_tracks == 1 then
    source_name = trackDisplayName(source_tracks[1])
  elseif #source_tracks > 1 then
    source_name = #source_tracks .. " tracks"
  else
    source_name = "Not set"
  end
end

local function doSendToTracks()
  if #source_tracks == 0 then return end

  local mode    = SEND_MODE_VALUES[send_mode_idx]
  local dst_chan = sidechain and 2 or 0  -- 0 = ch1/2, 2 = ch3/4
  local n_sel   = reaper.CountSelectedTracks(0)
  local created = 0

  -- Build set for quick source-track lookup to skip source→source sends
  local src_set = {}
  for _, t in ipairs(source_tracks) do src_set[t] = true end

  reaper.Undo_BeginBlock()
  for _, src in ipairs(source_tracks) do
    for i = 0, n_sel - 1 do
      local dst = reaper.GetSelectedTrack(0, i)
      if src_set[dst] then
        -- skip: destination is one of the sources
      elseif hasSendToTrack(src, dst) then
        -- skip: send already exists
      else
        local idx = reaper.CreateTrackSend(src, dst)
        reaper.SetTrackSendInfo_Value(src, 0, idx, "I_SENDMODE", mode)
        reaper.SetTrackSendInfo_Value(src, 0, idx, "I_SRCCHAN",  0)
        reaper.SetTrackSendInfo_Value(src, 0, idx, "I_DSTCHAN",  dst_chan)
        if sidechain then
          local cur_chan = reaper.GetMediaTrackInfo_Value(dst, "I_NCHAN")
          if cur_chan < 4 then
            reaper.SetMediaTrackInfo_Value(dst, "I_NCHAN", 4)
          end
        end
        created = created + 1
      end
    end
  end

  local label = "Create " .. created .. " track send(s) from " .. #source_tracks .. " source(s)"
  reaper.Undo_EndBlock(label, -1)
  reaper.UpdateArrange()
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSize(ctx, 310, 0, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "TRACK SEND TOOL", true, WIN_FLAGS)

  if visible then

    -- Validate source tracks on every frame (handle track deletion)
    local valid = {}
    for _, t in ipairs(source_tracks) do
      if isValidTrack(t) then valid[#valid + 1] = t end
    end
    source_tracks = valid
    if #source_tracks == 0 then
      source_name = "Not set"
    elseif #source_tracks == 1 then
      source_name = trackDisplayName(source_tracks[1])
    else
      source_name = #source_tracks .. " tracks"
    end

    -- ---- Source display ----
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, "Source")
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, source_name)

    ImGui.Spacing(ctx)

    -- ---- Buttons ----
    local no_sel    = reaper.CountSelectedTracks(0) == 0
    local no_source = #source_tracks == 0

    if ImGui.BeginTable(ctx, "##btns", 2) then
      ImGui.TableSetupColumn(ctx, "##b0", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableSetupColumn(ctx, "##b1", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableNextRow(ctx)

      -- Get Source
      ImGui.TableSetColumnIndex(ctx, 0)
      if no_sel then ImGui.BeginDisabled(ctx, true) end
      if ImGui.Button(ctx, "Get Source", -1, 0) then
        doGetSource()
      end
      if no_sel then ImGui.EndDisabled(ctx) end

      -- Send to Track(s)
      ImGui.TableSetColumnIndex(ctx, 1)
      local cant_send = no_source or no_sel
      if cant_send then ImGui.BeginDisabled(ctx, true) end
      if ImGui.Button(ctx, "Send to Track(s)", -1, 0) then
        doSendToTracks()
      end
      if cant_send then ImGui.EndDisabled(ctx) end

      ImGui.EndTable(ctx)
    end

    ImGui.Spacing(ctx)

    -- ---- Options ----
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, "Options")
    ImGui.PopStyleColor(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Send mode dropdown
    if ImGui.BeginTable(ctx, "##opts", 2) then
      ImGui.TableSetupColumn(ctx, "##ov", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableSetupColumn(ctx, "##ol", ImGui.TableColumnFlags_WidthFixed, 80)

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      if ImGui.BeginCombo(ctx, "##sendmode", SEND_MODE_LABELS[send_mode_idx]) then
        for i, label in ipairs(SEND_MODE_LABELS) do
          if ImGui.Selectable(ctx, label, send_mode_idx == i) then
            send_mode_idx = i
            saveOptions()
          end
          if send_mode_idx == i then ImGui.SetItemDefaultFocus(ctx) end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Send Mode")

      ImGui.EndTable(ctx)
    end

    ImGui.Spacing(ctx)

    local _, new_sc = ImGui.Checkbox(ctx, "Send as Sidechain (3/4)", sidechain)
    if new_sc ~= sidechain then
      sidechain = new_sc
      saveOptions()
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- ---- Status ----
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    local n_sel = reaper.CountSelectedTracks(0)
    ImGui.Text(ctx, n_sel .. (n_sel == 1 and " track selected" or " tracks selected"))
    ImGui.PopStyleColor(ctx)

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)

  if open then reaper.defer(loop) end
end

-- ============================================================
-- Entry point
-- ============================================================
reaper.defer(loop)
