-- @description Subproject Manager
-- @author Stephen Schappler
-- @version 0.3
-- @about
--   Unified subproject management window: preview selected subprojects, open them,
--   duplicate to new versioned takes, color all subproject items, and create new
--   subprojects from selected tracks — all in one ReaImGUI panel.
-- @link https://www.stephenschappler.com
-- @provides
--   [nomain] ../Common/ReaImGuiTheme.lua > Common/ReaImGuiTheme.lua
-- @changelog
--   04/29/26 - v0.3 feature additions
--   04/28/26 - v0.2 Adding color picker, bug fixes
--   04/27/26 - v0.1 Initial alpha release

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("ReaImGui is required for this script.", "Missing Dependency", 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

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
local TITLE     = "SUBPROJECT MANAGER"
local ctx       = ImGui.CreateContext(TITLE)
local WIN_FLAGS = ImGui.WindowFlags_NoCollapse
                | (rawget(ImGui, "WindowFlags_NoDocking") or 0)

local name_buf      = ""
local _ca           = reaper.GetExtState("CreateSubproject", "ChannelsAuto")
local channels_auto = (_ca == "") and true or (_ca == "true")
local channels_buf  = reaper.GetExtState("CreateSubproject", "ChannelCount")
if channels_buf == "" then channels_buf = "2" end
local tail_buf      = reaper.GetExtState("CreateSubproject", "TailSeconds")
if tail_buf == "" then tail_buf = "0.000" end
local copy_video        = reaper.GetExtState("CreateSubproject", "CopyVideoTracks")    == "true"
local close_after       = reaper.GetExtState("CreateSubproject", "CloseAfterCreation") == "true"
local run_dynamic_split = reaper.GetExtState("CreateSubproject", "RunDynamicSplit")    == "true"
local last_clicked_idx  = nil  -- anchor row for shift-click range selection
local preview_stop_pos  = nil  -- item end position for auto-stop after play button

-- Color picker state
local _cs = reaper.GetExtState("SubprojectManager", "SubprojectColor")
local color_r, color_g, color_b = _cs:match("(%d+),(%d+),(%d+)")
if color_r then
  color_r, color_g, color_b = tonumber(color_r), tonumber(color_g), tonumber(color_b)
else
  color_r, color_g, color_b = 161, 145, 227
end
local color_orig_r, color_orig_g, color_orig_b = color_r, color_g, color_b
local r_buf = tostring(color_r)
local g_buf = tostring(color_g)
local b_buf = tostring(color_b)
local h_buf, s_buf, v_buf = "0", "0", "0"
local hex_buf = string.format("%02X%02X%02X", color_r, color_g, color_b)

local function rgbToImGui(r, g, b)
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

local function imGuiToRgb(col)
  return (col >> 24) & 0xFF, (col >> 16) & 0xFF, (col >> 8) & 0xFF
end

local function rgbToHsv(r, g, b)
  r, g, b = r / 255.0, g / 255.0, b / 255.0
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local d = max - min
  local h, s, v = 0, 0, max
  if max > 0 then s = d / max end
  if d > 0 then
    if max == r then
      h = (g - b) / d
      if h < 0 then h = h + 6 end
    elseif max == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h * 60
  end
  return h, s * 100, v * 100
end

local function hsvToRgb(h, s, v)
  s, v = s / 100.0, v / 100.0
  if s == 0 then
    local c = math.floor(v * 255 + 0.5)
    return c, c, c
  end
  h = h / 60
  local i = math.floor(h) % 6
  local f = h - math.floor(h)
  local p = v * (1 - s)
  local q = v * (1 - s * f)
  local t = v * (1 - s * (1 - f))
  local r, g, b
  if     i == 0 then r, g, b = v, t, p
  elseif i == 1 then r, g, b = q, v, p
  elseif i == 2 then r, g, b = p, v, t
  elseif i == 3 then r, g, b = p, q, v
  elseif i == 4 then r, g, b = t, p, v
  else               r, g, b = v, p, q end
  return math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)
end

-- ============================================================
-- Utilities
-- ============================================================
local function containsString(str, substr)
  return string.find(str, substr, 1, true) ~= nil
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

local function getItemChannelCount(item)
  local take = reaper.GetActiveTake(item)
  if not take then return 0 end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return 0 end
  return reaper.GetMediaSourceNumChannels(src)
end

local function setTrackChannelCount(track, n)
  reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", n)
end

local function adjustTrackChannelCountToMatchItem(item)
  local track = reaper.GetMediaItem_Track(item)
  if not track then return end
  local n = getItemChannelCount(item)
  if n > 0 then setTrackChannelCount(track, n) end
end

local function getLastRenderedItem()
  local n = reaper.CountMediaItems(0)
  if n == 0 then return nil end
  return reaper.GetMediaItem(0, n - 1)
end

local function runCommand(id)
  reaper.Main_OnCommand(id, 0)
end

local function clearAllMarkers()
  local i = reaper.CountProjectMarkers(0) - 1
  while i >= 0 do
    local _, isrgn, _, _, _, idx = reaper.EnumProjectMarkers(i)
    reaper.DeleteProjectMarker(0, idx, isrgn)
    i = i - 1
  end
end

local function addMarkersToTimeSelection(tail)
  tail = tail or 0.0
  local s, e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if s ~= e then
    clearAllMarkers()
    reaper.AddProjectMarker(0, false, s,       0, "=START", -1)
    reaper.AddProjectMarker(0, false, e + tail, 0, "=END",   -1)
  else
    reaper.ShowMessageBox("No time selection set.", "Error", 0)
  end
end

local function getCurrentProjectName()
  return reaper.GetProjectName(0, "")
end

local function activateProjectByName(targetName)
  local i = 0
  while true do
    local proj = reaper.EnumProjects(i, "")
    if not proj then break end
    if reaper.GetProjectName(proj, "") == targetName then
      reaper.SelectProjectInstance(proj)
      break
    end
    i = i + 1
  end
end

local function isTimeSelectionPresent()
  local s, e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  return s ~= e
end

local function areItemsSelected()
  return reaper.CountSelectedMediaItems(0) > 0
end

local function isSubprojectItem(item)
  local take = reaper.GetActiveTake(item)
  if not take then return false end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return false end
  return reaper.GetMediaSourceFileName(src, ""):sub(-4):lower() == ".rpp"
end

-- ============================================================
-- Feature: all subproject items in the active project
-- ============================================================
local function getAllSubprojectItems()
  local rows = {}
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    if item then
      local take = reaper.GetActiveTake(item)
      if take then
        local src = reaper.GetMediaItemTake_Source(take)
        if src then
          local fn = reaper.GetMediaSourceFileName(src, "")
          if fn:sub(-4):lower() == ".rpp" then
            local track       = reaper.GetMediaItem_Track(item)
            local _, tname    = reaper.GetTrackName(track, "")
            local basename    = fn:match("([^\\/]+)%.rpp$") or fn
            local tc          = reaper.CountTakes(item)
            local cur_idx     = math.floor(reaper.GetMediaItemInfo_Value(item, "I_CURTAKE") + 0.5)
            local _, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
            if not takeName or takeName == "" then takeName = basename end
            rows[#rows + 1] = { item = item, track = tname, file = basename, takes = tc, take_idx = cur_idx, take = takeName }
          end
        end
      end
    end
  end
  return rows
end

-- ============================================================
-- Feature: open subproject items in new tabs
-- ============================================================
local function openSelectedSubprojects(items)
  if not items or #items == 0 then return end
  -- Deselect all, then open each subproject in turn (focus stays on the last one opened)
  reaper.Main_OnCommand(40289, 0)
  for _, item in ipairs(items) do
    reaper.SetMediaItemSelected(item, true)
    runCommand(40109)
    reaper.SetMediaItemSelected(item, false)
  end
end

-- ============================================================
-- Feature: update (open, render RPP-PROX, close) selected subprojects
-- ============================================================
local function updateSubproject(items)
  if not items or #items == 0 then return end
  local parentName = getCurrentProjectName()
  local rendered = {}
  for _, item in ipairs(items) do
    local take = reaper.GetActiveTake(item)
    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      if src then
        local fp = reaper.GetMediaSourceFileName(src, "")
        if fp and fp:sub(-4):lower() == ".rpp" and not rendered[fp] then
          rendered[fp] = true
          reaper.Main_OnCommand(40289, 0)
          reaper.SetMediaItemSelected(item, true)
          reaper.Main_OnCommand(40109, 0)  -- open subproject in tab
          reaper.Main_OnCommand(42332, 0)  -- save + render RPP-PROX
          reaper.Main_OnCommand(40860, 0)  -- close tab
        end
      end
    end
  end
  activateProjectByName(parentName)
  reaper.Main_OnCommand(40289, 0)
  for _, item in ipairs(items) do reaper.SetMediaItemSelected(item, true) end
  reaper.UpdateArrange()
end

-- ============================================================
-- Feature: color all subproject items in the project
-- ============================================================
local function colorAllSubprojectItems()
  reaper.Undo_BeginBlock()
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    for j = 0, reaper.CountTakes(item) - 1 do
      local take = reaper.GetTake(item, j)
      local src  = reaper.GetMediaItemTake_Source(take)
      local fn   = reaper.GetMediaSourceFileName(src, "")
      if containsString(fn, ".rpp") then
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR",
          reaper.ColorToNative(color_r, color_g, color_b) | 0x01000000)
        break
      end
    end
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Color all subproject items", -1)
end

-- ============================================================
-- Feature: duplicate selected subproject items to new versioned takes
-- ============================================================
local function duplicateToNewVersion(items)
  if not items or #items == 0 then
    reaper.ShowMessageBox("No subproject items selected.", "Error", 0)
    return
  end

  reaper.Undo_BeginBlock()
  local parentName = getCurrentProjectName()
  local savedItems = items

  local versionMap = {}

  -- First pass: copy RPP to new version, add new take
  for _, item in ipairs(savedItems) do
    local take = reaper.GetActiveTake(item)
    if not take then
      reaper.ShowMessageBox("One of the items has no active take.", "Error", 0)
      reaper.Undo_EndBlock("Duplicate subproject to new version", -1); return
    end
    local src = reaper.GetMediaItemTake_Source(take)
    if not src then
      reaper.ShowMessageBox("Unable to retrieve source.", "Error", 0)
      reaper.Undo_EndBlock("Duplicate subproject to new version", -1); return
    end
    local origFile = reaper.GetMediaSourceFileName(src, "")
    if not origFile or origFile == "" then
      reaper.ShowMessageBox("Could not determine subproject file path.", "Error", 0)
      reaper.Undo_EndBlock("Duplicate subproject to new version", -1); return
    end
    local folder, filename = origFile:match("^(.-)[\\/]([^\\/]-)$")
    if not folder then
      reaper.ShowMessageBox("Failed to parse file path.", "Error", 0)
      reaper.Undo_EndBlock("Duplicate subproject to new version", -1); return
    end
    local base, ext = filename:match("^(.*)%.([^.]+)$")
    if not base or ext:lower() ~= "rpp" then
      reaper.ShowMessageBox("Invalid subproject file.", "Error", 0)
      reaper.Undo_EndBlock("Duplicate subproject to new version", -1); return
    end

    local newFilePath = versionMap[origFile]
    if not newFilePath then
      local origBase, curVer = base:match("^(.*)_v(%d%d)$")
      local newVer = curVer and tonumber(curVer) + 1 or 2
      repeat
        newFilePath = string.format("%s/%s_v%02d.%s", folder, origBase or base, newVer, ext)
        newVer = newVer + 1
      until not file_exists(newFilePath)

      local infile = io.open(origFile, "rb")
      if not infile then
        reaper.ShowMessageBox("Could not open:\n" .. origFile, "Error", 0)
        reaper.Undo_EndBlock("Duplicate subproject to new version", -1); return
      end
      local content = infile:read("*all"); infile:close()
      local outfile = io.open(newFilePath, "wb")
      if not outfile then
        reaper.ShowMessageBox("Could not create:\n" .. newFilePath, "Error", 0)
        reaper.Undo_EndBlock("Duplicate subproject to new version", -1); return
      end
      outfile:write(content); outfile:close()
      versionMap[origFile] = newFilePath
    end

    local newTake = reaper.AddTakeToMediaItem(item)
    if not newTake then
      reaper.ShowMessageBox("Failed to add take.", "Error", 0)
      reaper.Undo_EndBlock("Duplicate subproject to new version", -1); return
    end
    local newSrc = reaper.PCM_Source_CreateFromFile(newFilePath)
    if not newSrc then
      reaper.ShowMessageBox("Failed to create PCM source.", "Error", 0)
      reaper.Undo_EndBlock("Duplicate subproject to new version", -1); return
    end
    reaper.SetMediaItemTake_Source(newTake, newSrc)
    reaper.SetMediaItemTakeInfo_Value(newTake, "D_STARTOFFS",
      reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"))
    local ok, tname = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    if ok then reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", tname, true) end
    reaper.SetMediaItemInfo_Value(item, "I_CURTAKE", reaper.CountTakes(item) - 1)
  end

  -- Second pass: open and render each unique new RPP once, skipping duplicates
  local rendered = {}
  for _, item in ipairs(savedItems) do
    if item then
      local take = reaper.GetActiveTake(item)
      if take then
        local src = reaper.GetMediaItemTake_Source(take)
        if src then
          local fp = reaper.GetMediaSourceFileName(src, "")
          if fp and fp:sub(-4):lower() == ".rpp" and not rendered[fp] then
            rendered[fp] = true
            for _, other in ipairs(savedItems) do
              reaper.SetMediaItemSelected(other, other == item)
            end
            reaper.Main_OnCommand(40109, 0)
            reaper.Main_OnCommand(42332, 0)
            activateProjectByName(parentName)
          end
        end
      end
    end
  end

  -- Restore original selection
  reaper.Main_OnCommand(40289, 0)
  for _, item in ipairs(savedItems) do reaper.SetMediaItemSelected(item, true) end

  -- Add take markers showing the new versioned filename
  for _, item in ipairs(savedItems) do
    if item then
      local tc = reaper.CountTakes(item)
      if tc > 1 then
        local newTake = reaper.GetTake(item, tc - 1)
        if newTake then
          local src = reaper.GetMediaItemTake_Source(newTake)
          if src then
            local fp    = reaper.GetMediaSourceFileName(src, "")
            local fname = fp:match("([^\\/]+)%.rpp$")
            if fname then
              local offs = reaper.GetMediaItemTakeInfo_Value(newTake, "D_STARTOFFS")
              reaper.SetTakeMarker(newTake, -1, fname, offs)
            end
          end
        end
      end
    end
  end

  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock("Duplicate subprojects (versioned, new takes, markers)", -1)
end

-- ============================================================
-- Feature: create subproject from selected tracks
-- ============================================================
local function collectVideoTrackChunks()
  local chunks = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(track, "")
    if name:lower():find("video", 1, true) then
      local ok, chunk = reaper.GetTrackStateChunk(track, "", false)
      if ok then chunks[#chunks + 1] = chunk end
    end
  end
  return chunks
end

local function pasteVideoTracksAtTop(chunks, subproj)
  for i = #chunks, 1, -1 do
    reaper.InsertTrackAtIndex(0, false)
    local t = reaper.GetTrack(subproj, 0)
    reaper.SetTrackStateChunk(t, chunks[i], false)
  end
  reaper.TrackList_AdjustWindows(false)
end

local function createSubproject()
  local tail_secs    = tonumber(tail_buf) or 0.0
  local manual_chans = not channels_auto
                       and math.max(2, math.floor(tonumber(channels_buf) or 2))
                       or nil
  local video_chunks = copy_video and collectVideoTrackChunks() or {}
  local first_track  = reaper.GetSelectedTrack(0, 0)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  if name_buf ~= "" and first_track then
    reaper.GetSetMediaTrackInfo_String(first_track, "P_NAME", name_buf, true)
  end

  if isTimeSelectionPresent() or areItemsSelected() then
    local parentName = getCurrentProjectName()
    runCommand(40290)
    runCommand(41997)
    runCommand(41205)
    runCommand(41816)

    local subproj = reaper.EnumProjects(-1, "")
    if manual_chans then
      local master = reaper.GetMasterTrack(subproj)
      if master then setTrackChannelCount(master, manual_chans) end
    end
    if #video_chunks > 0 then pasteVideoTracksAtTop(video_chunks, subproj) end

    addMarkersToTimeSelection(tail_secs)
    runCommand(40031)
    runCommand(42332)
    if close_after then runCommand(40860) end

    activateProjectByName(parentName)

    local lastItem = getLastRenderedItem()
    if lastItem then
      if channels_auto then
        adjustTrackChannelCountToMatchItem(lastItem)
      else
        local track = reaper.GetMediaItem_Track(lastItem)
        if track then setTrackChannelCount(track, manual_chans) end
      end
    end

    local cmd_id = reaper.NamedCommandLookup("_XENAKIOS_RESETITEMLENMEDOFFS")
    reaper.Main_OnCommand(cmd_id, 0)
    if run_dynamic_split then runCommand(42951) end
    runCommand(40635)
    reaper.Undo_EndBlock("Create subproject from selected track(s)", -1)
  else
    local parentName = getCurrentProjectName()
    runCommand(41997)
    runCommand(41816)
    if #video_chunks > 0 then
      local subproj = reaper.EnumProjects(-1, "")
      pasteVideoTracksAtTop(video_chunks, subproj)
    end
    if close_after then runCommand(40026); runCommand(40860) end
    reaper.Undo_EndBlock("Create subproject (basic path)", -1)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
end

-- ============================================================
-- Render loop
-- ============================================================
local function loop()
  if preview_stop_pos then
    if reaper.GetPlayState() & 1 == 0 then
      preview_stop_pos = nil
    elseif reaper.GetPlayPosition() >= preview_stop_pos then
      reaper.Main_OnCommand(1016, 0)  -- Transport: Stop
      preview_stop_pos = nil
    end
  end

  local cc, vc = theme.Push(ctx)

  ImGui.SetNextWindowSize(ctx, 800, 700, ImGui.Cond_FirstUseEver)
  local visible, still_open = ImGui.Begin(ctx, TITLE, true, WIN_FLAGS)

  if visible then
    local rows = getAllSubprojectItems()

    -- Mirror REAPER's current item selection each frame
    local reaper_sel = {}
    for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
      reaper_sel[reaper.GetSelectedMediaItem(0, i)] = true
    end

    -- valid_selected: selected items that are also in the subproject table
    local valid_selected = {}
    for _, r in ipairs(rows) do
      if reaper_sel[r.item] then
        valid_selected[#valid_selected + 1] = r.item
      end
    end
    local has_selection = #valid_selected > 0

    -- ── Create Subproject form ───────────────────────────────────
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, "CREATE SUBPROJECT")
    ImGui.PopStyleColor(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    if ImGui.BeginTable(ctx, "##create_cols", 2, ImGui.TableFlags_SizingStretchSame) then
      ImGui.TableSetupColumn(ctx, "##col_fields",  ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableSetupColumn(ctx, "##col_options", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableNextRow(ctx)

      -- Left column: Name / Channels / Tail
      ImGui.TableSetColumnIndex(ctx, 0)
      if ImGui.BeginTable(ctx, "##fields", 2) then
        ImGui.TableSetupColumn(ctx, "##input", ImGui.TableColumnFlags_WidthStretch)
        ImGui.TableSetupColumn(ctx, "##label", ImGui.TableColumnFlags_WidthFixed, 80)

        -- Name
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.SetNextItemWidth(ctx, -1)
        local _, nn = ImGui.InputTextWithHint(ctx, "##name", "optional", name_buf)
        name_buf = nn
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, "Name")

        -- Channels
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        if channels_auto then
          ImGui.BeginDisabled(ctx, true)
          ImGui.SetNextItemWidth(ctx, 110)
          ImGui.InputText(ctx, "##ch_display", "Auto", ImGui.InputTextFlags_ReadOnly)
          ImGui.EndDisabled(ctx)
        else
          ImGui.SetNextItemWidth(ctx, 110)
          local ch_c, nc = ImGui.InputText(ctx, "##ch_val", channels_buf,
            ImGui.InputTextFlags_CharsDecimal)
          if ch_c then
            channels_buf = nc
            reaper.SetExtState("CreateSubproject", "ChannelCount", channels_buf, true)
          end
        end
        ImGui.SameLine(ctx)
        local ch_a, na = ImGui.Checkbox(ctx, "Auto##ch_auto", channels_auto)
        if ch_a then
          channels_auto = na
          reaper.SetExtState("CreateSubproject", "ChannelsAuto", channels_auto and "true" or "false", true)
        end
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, "Channels")

        -- Tail
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.SetNextItemWidth(ctx, -1)
        local ch_t, nt = ImGui.InputText(ctx, "##tail", tail_buf,
          ImGui.InputTextFlags_CharsDecimal)
        if ch_t then
          tail_buf = nt
          reaper.SetExtState("CreateSubproject", "TailSeconds", tail_buf, true)
        end
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, "Tail  (sec)")

        ImGui.EndTable(ctx)
      end

      -- Right column: Options checkboxes
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
      ImGui.PopStyleColor(ctx)

      local ch_v, ncv = ImGui.Checkbox(ctx, "Copy Video Track(s)", copy_video)
      if ch_v then
        copy_video = ncv
        reaper.SetExtState("CreateSubproject", "CopyVideoTracks", ncv and "true" or "false", true)
      end
      local ch_d, nds = ImGui.Checkbox(ctx, "Run Dynamic Split", run_dynamic_split)
      if ch_d then
        run_dynamic_split = nds
        reaper.SetExtState("CreateSubproject", "RunDynamicSplit", nds and "true" or "false", true)
      end
      local ch_ca, nca = ImGui.Checkbox(ctx, "Close Subproject After Creation", close_after)
      if ch_ca then
        close_after = nca
        reaper.SetExtState("CreateSubproject", "CloseAfterCreation", nca and "true" or "false", true)
      end

      ImGui.EndTable(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    local sel_t     = reaper.CountSelectedTracks(0)
    local track_str = sel_t == 1 and "track" or "tracks"
    local no_tracks = sel_t == 0

    if no_tracks then ImGui.BeginDisabled(ctx, true) end
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x2C6B64FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x338077FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x2A5C56FF)
    if ImGui.Button(ctx, "Create", 80, 0) then
      reaper.SetExtState("CreateSubproject", "CopyVideoTracks",    copy_video        and "true" or "false", true)
      reaper.SetExtState("CreateSubproject", "CloseAfterCreation", close_after       and "true" or "false", true)
      reaper.SetExtState("CreateSubproject", "RunDynamicSplit",    run_dynamic_split and "true" or "false", true)
      createSubproject()
    end
    ImGui.PopStyleColor(ctx, 3)
    if no_tracks then ImGui.EndDisabled(ctx) end
    ImGui.SameLine(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, ("Create subproject from %d selected %s"):format(sel_t, track_str))
    ImGui.PopStyleColor(ctx)

    if not no_tracks and (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or
                          ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)) then
      reaper.SetExtState("CreateSubproject", "CopyVideoTracks",    copy_video        and "true" or "false", true)
      reaper.SetExtState("CreateSubproject", "CloseAfterCreation", close_after       and "true" or "false", true)
      reaper.SetExtState("CreateSubproject", "RunDynamicSplit",    run_dynamic_split and "true" or "false", true)
      createSubproject()
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- ── Subproject items table ───────────────────────────────────
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, "SUBPROJECT ITEMS")
    ImGui.PopStyleColor(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    local row_h   = ImGui.GetTextLineHeightWithSpacing(ctx)
    local child_h = math.min(600, math.max(row_h * 3, row_h * (#rows + 1) + 4))
    local child_visible = ImGui.BeginChild(ctx, "##preview", 0, child_h, rawget(ImGui, "ChildFlags_Border") or 1)
    if child_visible then
    if #rows == 0 then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x555555FF)
      ImGui.Text(ctx, "No subproject items in project")
      ImGui.PopStyleColor(ctx)
    else
      local SEL_SPAN   = (rawget(ImGui, "SelectableFlags_SpanAllColumns") or 0)
                       | (rawget(ImGui, "SelectableFlags_AllowOverlap")
                          or rawget(ImGui, "SelectableFlags_AllowItemOverlap") or 0)
      local KEY_LCTRL  = rawget(ImGui, "Key_LeftCtrl")
      local KEY_RCTRL  = rawget(ImGui, "Key_RightCtrl")
      local KEY_LSHIFT = rawget(ImGui, "Key_LeftShift")
      local KEY_RSHIFT = rawget(ImGui, "Key_RightShift")
      local hdr_c   = ImGui.GetStyleColor(ctx, ImGui.Col_Header)
      local hdr_dim = (hdr_c & 0xFFFFFF00) | math.floor((hdr_c & 0xFF) * 0.4)
      ImGui.PushStyleColor(ctx, ImGui.Col_Header, hdr_dim)
      if ImGui.BeginTable(ctx, "##ptable", 5,
          ImGui.TableFlags_BordersInnerV) then
        ImGui.TableSetupColumn(ctx, "##playcol",    ImGui.TableColumnFlags_WidthFixed, 24)
        ImGui.TableSetupColumn(ctx, "Take Name",    ImGui.TableColumnFlags_WidthStretch)
        ImGui.TableSetupColumn(ctx, "Take Version", ImGui.TableColumnFlags_WidthFixed, 130)
        ImGui.TableSetupColumn(ctx, "Track",        ImGui.TableColumnFlags_WidthStretch)
        ImGui.TableSetupColumn(ctx, "RPP File",     ImGui.TableColumnFlags_WidthStretch)
        ImGui.TableHeadersRow(ctx)
        local last_rpp_file = nil
        local rpp_alt       = false
        local row_bg0       = ImGui.GetStyleColor(ctx, ImGui.Col_TableRowBg)
        local row_bg1       = ImGui.GetStyleColor(ctx, ImGui.Col_TableRowBgAlt)
        local tgt_row_bg    = rawget(ImGui, "TableBgTarget_RowBg0") or 1
        for i, r in ipairs(rows) do
          ImGui.TableNextRow(ctx)
          if r.file ~= last_rpp_file then
            rpp_alt = not rpp_alt
            last_rpp_file = r.file
          end
          ImGui.TableSetBgColor(ctx, tgt_row_bg, rpp_alt and row_bg1 or row_bg0)
          ImGui.TableSetColumnIndex(ctx, 1)
          local is_sel = reaper_sel[r.item] == true
          if ImGui.Selectable(ctx, "##sel"..i, is_sel, SEL_SPAN) then
            local ctrl  = (KEY_LCTRL  and ImGui.IsKeyDown(ctx, KEY_LCTRL))
                       or (KEY_RCTRL  and ImGui.IsKeyDown(ctx, KEY_RCTRL))
            local shift = (KEY_LSHIFT and ImGui.IsKeyDown(ctx, KEY_LSHIFT))
                       or (KEY_RSHIFT and ImGui.IsKeyDown(ctx, KEY_RSHIFT))
            if shift and last_clicked_idx then
              -- Range select: additively select all rows between anchor and here
              local lo = math.min(last_clicked_idx, i)
              local hi = math.max(last_clicked_idx, i)
              for ri = lo, hi do
                if rows[ri] then reaper.SetMediaItemSelected(rows[ri].item, true) end
              end
            elseif ctrl then
              reaper.SetMediaItemSelected(r.item, not reaper_sel[r.item])
              last_clicked_idx = i
            else
              reaper.Main_OnCommand(40289, 0)
              reaper.SetMediaItemSelected(r.item, true)
              last_clicked_idx = i
            end
            reaper.UpdateArrange()
          end
          if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, 0) then
            local pos = reaper.GetMediaItemInfo_Value(r.item, "D_POSITION")
            reaper.SetEditCurPos(pos, true, false)
            reaper.UpdateArrange()
          end
          ImGui.SameLine(ctx)
          ImGui.Text(ctx, r.take)
          ImGui.TableSetColumnIndex(ctx, 2)
          local ci, tot = r.take_idx, r.takes
          if ci <= 0 then ImGui.BeginDisabled(ctx, true) end
          if ImGui.SmallButton(ctx, "<##p"..i) then
            reaper.SetMediaItemInfo_Value(r.item, "I_CURTAKE", ci - 1)
            reaper.UpdateArrange()
          end
          if ci <= 0 then ImGui.EndDisabled(ctx) end
          ImGui.SameLine(ctx)
          ImGui.Text(ctx, string.format("%d of %d", ci + 1, tot))
          ImGui.SameLine(ctx)
          if ci >= tot - 1 then ImGui.BeginDisabled(ctx, true) end
          if ImGui.SmallButton(ctx, ">##n"..i) then
            reaper.SetMediaItemInfo_Value(r.item, "I_CURTAKE", ci + 1)
            reaper.UpdateArrange()
          end
          if ci >= tot - 1 then ImGui.EndDisabled(ctx) end
          ImGui.TableSetColumnIndex(ctx, 3) ImGui.Text(ctx, r.track)
          ImGui.TableSetColumnIndex(ctx, 4) ImGui.Text(ctx, r.file)
          -- Play button drawn last so it renders on top of the SpanAllColumns selectable
          ImGui.TableSetColumnIndex(ctx, 0)
          if ImGui.SmallButton(ctx, "▶##play"..i) then
            reaper.Main_OnCommand(40289, 0)
            reaper.SetMediaItemSelected(r.item, true)
            last_clicked_idx = i
            local pos = reaper.GetMediaItemInfo_Value(r.item, "D_POSITION")
            local len = reaper.GetMediaItemInfo_Value(r.item, "D_LENGTH")
            reaper.SetEditCurPos(pos, true, false)
            reaper.Main_OnCommand(43354, 0)
            preview_stop_pos = pos + len
            reaper.UpdateArrange()
          end
          if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Preview track") end
        end
        ImGui.EndTable(ctx)
      end
      ImGui.PopStyleColor(ctx)
    end
    ImGui.EndChild(ctx)
    end -- child_visible

    ImGui.Spacing(ctx)

    -- ── Quick action buttons ─────────────────────────────────────
    local avail_w, _ = ImGui.GetContentRegionAvail(ctx)
    local sp_x, _    = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
    local btn_w      = (avail_w - sp_x * 3) / 4
    local swatch_w   = 18
    local row_sx, row_sy = ImGui.GetCursorScreenPos(ctx)

    if not has_selection then ImGui.BeginDisabled(ctx, true) end
    if ImGui.Button(ctx, "Open Selected", btn_w, 0) then
      openSelectedSubprojects(valid_selected)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Update Subproject", btn_w, 0) then
      updateSubproject(valid_selected)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Duplicate to New Version", btn_w, 0) then
      duplicateToNewVersion(valid_selected)
    end
    if not has_selection then ImGui.EndDisabled(ctx) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Color All Subproject Items", btn_w - swatch_w, 0) then
      colorAllSubprojectItems()
    end

    -- Place swatch at exact screen-space right edge of the content region
    ImGui.SetCursorScreenPos(ctx, row_sx + avail_w - swatch_w, row_sy)
    local cur_col = rgbToImGui(color_r, color_g, color_b)
    if ImGui.ColorButton(ctx, "##color_swatch", cur_col, ImGui.ColorEditFlags_NoTooltip, swatch_w, 0) then
      ImGui.OpenPopup(ctx, "##color_picker_popup")
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Click to change color") end

    if ImGui.BeginPopup(ctx, "##color_picker_popup") then
      if ImGui.IsWindowAppearing(ctx) then
        color_orig_r, color_orig_g, color_orig_b = color_r, color_g, color_b
        r_buf = tostring(color_r)
        g_buf = tostring(color_g)
        b_buf = tostring(color_b)
        local h0, s0, v0 = rgbToHsv(color_r, color_g, color_b)
        h_buf = string.format("%.0f", h0)
        s_buf = string.format("%.0f", s0)
        v_buf = string.format("%.0f", v0)
        hex_buf = string.format("%02X%02X%02X", color_r, color_g, color_b)
      end

      local color_changed = false
      local edited_buf, edited_val

      local sw_flags = ImGui.ColorEditFlags_NoTooltip | ImGui.ColorEditFlags_NoBorder
      ImGui.ColorButton(ctx, "##orig_p", rgbToImGui(color_orig_r, color_orig_g, color_orig_b), sw_flags, 50, 24)
      ImGui.SameLine(ctx)
      ImGui.ColorButton(ctx, "##cur_p", rgbToImGui(color_r, color_g, color_b), sw_flags, 50, 24)
      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)

      local fw  = 52
      local dec = ImGui.InputTextFlags_CharsDecimal
      local function lbl(t)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
        ImGui.Text(ctx, t) ImGui.PopStyleColor(ctx) ImGui.SameLine(ctx)
      end

      -- RGB
      lbl("R") ImGui.SetNextItemWidth(ctx, fw)
      local cr, nr = ImGui.InputText(ctx, "##r", r_buf, dec)
      if cr and tonumber(nr) then
        color_r = math.max(0, math.min(255, math.floor(tonumber(nr) + 0.5)))
        color_changed = true; edited_buf = "r"; edited_val = nr
      end
      ImGui.SameLine(ctx)
      lbl("G") ImGui.SetNextItemWidth(ctx, fw)
      local cg, ng = ImGui.InputText(ctx, "##g", g_buf, dec)
      if cg and tonumber(ng) then
        color_g = math.max(0, math.min(255, math.floor(tonumber(ng) + 0.5)))
        color_changed = true; edited_buf = "g"; edited_val = ng
      end
      ImGui.SameLine(ctx)
      lbl("B") ImGui.SetNextItemWidth(ctx, fw)
      local cb, nb = ImGui.InputText(ctx, "##b", b_buf, dec)
      if cb and tonumber(nb) then
        color_b = math.max(0, math.min(255, math.floor(tonumber(nb) + 0.5)))
        color_changed = true; edited_buf = "b"; edited_val = nb
      end

      -- HSV
      lbl("H") ImGui.SetNextItemWidth(ctx, fw)
      local ch, nh = ImGui.InputText(ctx, "##h", h_buf, dec)
      if ch and tonumber(nh) then
        color_r, color_g, color_b = hsvToRgb(
          math.max(0, math.min(360, tonumber(nh))),
          math.max(0, math.min(100, tonumber(s_buf) or 0)),
          math.max(0, math.min(100, tonumber(v_buf) or 0)))
        color_changed = true; edited_buf = "h"; edited_val = nh
      end
      ImGui.SameLine(ctx)
      lbl("S") ImGui.SetNextItemWidth(ctx, fw)
      local cs, ns = ImGui.InputText(ctx, "##s", s_buf, dec)
      if cs and tonumber(ns) then
        color_r, color_g, color_b = hsvToRgb(
          math.max(0, math.min(360, tonumber(h_buf) or 0)),
          math.max(0, math.min(100, tonumber(ns))),
          math.max(0, math.min(100, tonumber(v_buf) or 0)))
        color_changed = true; edited_buf = "s"; edited_val = ns
      end
      ImGui.SameLine(ctx)
      lbl("V") ImGui.SetNextItemWidth(ctx, fw)
      local cv, nv = ImGui.InputText(ctx, "##v", v_buf, dec)
      if cv and tonumber(nv) then
        color_r, color_g, color_b = hsvToRgb(
          math.max(0, math.min(360, tonumber(h_buf) or 0)),
          math.max(0, math.min(100, tonumber(s_buf) or 0)),
          math.max(0, math.min(100, tonumber(nv))))
        color_changed = true; edited_buf = "v"; edited_val = nv
      end

      -- Hex
      lbl("#") ImGui.SetNextItemWidth(ctx, -1)
      local hxc, new_hex = ImGui.InputText(ctx, "##hex", hex_buf)
      if hxc then
        hex_buf = new_hex
        local clean = new_hex:gsub("[^%x]", "")
        if #clean == 6 then
          local r = tonumber(clean:sub(1,2), 16)
          local g = tonumber(clean:sub(3,4), 16)
          local b = tonumber(clean:sub(5,6), 16)
          if r and g and b then
            color_r, color_g, color_b = r, g, b
            color_changed = true; edited_buf = "hex"; edited_val = new_hex
          end
        end
      end

      if color_changed then
        -- sync all buffers from canonical color, then restore the active field
        r_buf = tostring(color_r); g_buf = tostring(color_g); b_buf = tostring(color_b)
        local h2, s2, v2 = rgbToHsv(color_r, color_g, color_b)
        h_buf = string.format("%.0f", h2)
        s_buf = string.format("%.0f", s2)
        v_buf = string.format("%.0f", v2)
        hex_buf = string.format("%02X%02X%02X", color_r, color_g, color_b)
        -- keep the field the user is typing in as-is
        if     edited_buf == "r"   then r_buf   = edited_val
        elseif edited_buf == "g"   then g_buf   = edited_val
        elseif edited_buf == "b"   then b_buf   = edited_val
        elseif edited_buf == "h"   then h_buf   = edited_val
        elseif edited_buf == "s"   then s_buf   = edited_val
        elseif edited_buf == "v"   then v_buf   = edited_val
        elseif edited_buf == "hex" then hex_buf = edited_val
        end
        reaper.SetExtState("SubprojectManager", "SubprojectColor",
          color_r .. "," .. color_g .. "," .. color_b, true)
      end

      ImGui.EndPopup(ctx)
    end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, cc, vc)

  if still_open then reaper.defer(loop) end
end

reaper.defer(loop)
