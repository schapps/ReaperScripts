-- @description Subproject Manager
-- @author Stephen Schappler
-- @version 1.6
-- @about
--   Unified subproject management window: preview selected subprojects, open them,
--   duplicate to new versioned takes, explode to child tracks, and color all subproject items — all in one ReaImGUI panel.
--   Requires: Schapps ReaImGUI Theme (install from this repository first).
-- @link https://www.stephenschappler.com
-- @changelog
--   05/06/26 - v1.6 Fixing Export Script Setting Persistence Bug
--   05/06/26 - v1.5 Adding shortcuts (play and select all)
--   05/06/26 - v1.4 Fixing Shift + Click selection bug
--   05/06/26 - v1.3 Fixing Open Subproject Logic
--   05/06/26 - v1.2 Sortable column headers
--   05/06/26 - v1.1 Settings popup with export script; Export button
--   05/06/26 - v1.0 Start column using project ruler format
--   05/06/26 - v0.9 Lasso drag selection in subproject list
--   05/06/26 - v0.8 Search bar filters list by take name
--   05/06/26 - v0.7 Single-click seeks to item; double-click opens inline take rename
--   05/02/26 - v0.6 Added Explode Subprojects button
--   05/01/26 - v0.5 Image-based play button (cross-platform)
--   05/01/26 - v0.4 Removed create subproject (moved to Subproject Hub)
--   04/29/26 - v0.3 Feature additions
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

local play_img
do
  local p = script_dir .. "Common/line-md--play-filled.png"
  if not reaper.file_exists(p) then p = script_dir .. "../Common/line-md--play-filled.png" end
  play_img = ImGui.CreateImage(p)
  if play_img then ImGui.Attach(ctx, play_img) end
end

local last_clicked_idx  = nil  -- anchor row for shift-click range selection
local preview_stop_pos  = nil  -- item end position for auto-stop after play button
local renaming_idx       = nil  -- row index currently being renamed (nil = not renaming)
local rename_buf         = ""
local rename_needs_focus = false
local search_buf         = ""
local lasso_active       = false
local lasso_pending      = false  -- click in empty area; waiting for drag threshold
local lasso_x1, lasso_y1 = 0, 0  -- drag start (screen coords)
local lasso_x2, lasso_y2 = 0, 0  -- current drag end
local sort_col           = -1     -- sorted column index (-1 = unsorted)
local sort_asc           = true   -- ascending direction
local export_path_buf    = reaper.GetExtState("SchappsSubprojects", "ExportScript")

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

local function runCommand(id)
  reaper.Main_OnCommand(id, 0)
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
            local ipos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            rows[#rows + 1] = { item = item, track = tname, file = basename, takes = tc, take_idx = cur_idx, take = takeName, start = ipos }
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
  for _, item in ipairs(items) do
    local take = reaper.GetActiveTake(item)
    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      if src then
        local existing = reaper.GetSubProjectFromSource(src)
        if existing then
          reaper.SelectProjectInstance(existing)
        else
          local fp = reaper.GetMediaSourceFileName(src, "")
          if fp ~= "" then
            reaper.Main_OnCommand(40859, 0)  -- new project tab (keep current)
            reaper.Main_openProject(fp)
          end
        end
      end
    end
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
          reaper.Main_OnCommand(40859, 0)  -- new project tab (keep current)
          reaper.Main_openProject(fp)
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
            reaper.Main_OnCommand(40859, 0)  -- new project tab (keep current)
            reaper.Main_openProject(fp)
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
-- Feature: explode selected subproject items to child tracks
-- ============================================================
local function CountChildTrack(track)
  local count = 0
  local depth = reaper.GetTrackDepth(track)
  local track_index = reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER')
  for i = track_index, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if reaper.GetTrackDepth(tr) > depth then count = count + 1 else break end
  end
  return count
end

local function getTrackTablePositions(project_table)
  local positions = {}
  local track_start, track_count, track_closers = 0, 0, 0
  for i = 1, #project_table do
    local s = project_table[i]
    if s:sub(3, 8) == "<TRACK" then track_count = track_count + 1; track_start = i end
    if s:sub(3, 3) == ">" and track_count > track_closers then
      track_closers = track_closers + 1
      positions[#positions + 1] = { track_start = track_start, track_end = i }
    end
  end
  return positions
end

local function rppToTable(filename)
  local t = {}
  local f = io.open(filename, "r")
  if not f then return t end
  for line in f:lines() do t[#t + 1] = line end
  t[#t + 1] = ""
  f:close()
  return t
end

local function SetTrackChunkSNM(track, chunk)
  if not (track and chunk) then return end
  local fs = reaper.SNM_CreateFastString("")
  if reaper.SNM_SetFastString(fs, chunk) then
    reaper.SNM_GetSetObjectState(track, fs, true, false)
  end
  reaper.SNM_DeleteFastString(fs)
end

local function explodeOneSubproject(filename, track, item)
  local t = rppToTable(filename)
  if #t == 0 then return end

  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  reaper.Main_OnCommand(40289, 0)
  reaper.SetMediaItemSelected(item, true)
  reaper.Main_OnCommand(42228, 0)
  reaper.BR_SetItemEdges(item, item_pos, item_pos + item_len)

  local track_number = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
  reaper.SetMediaTrackInfo_Value(track, 'I_FOLDERDEPTH', 1)
  local count_child = CountChildTrack(track)
  local positions   = getTrackTablePositions(t)
  local new_tracks  = {}
  local tmp_t       = {}

  for i = 1, #positions do
    reaper.InsertTrackAtIndex(track_number + i - 1, false)
    local tptr = reaper.GetTrack(0, track_number + i - 1)
    new_tracks[#new_tracks + 1] = tptr
    for ii = positions[i].track_start, positions[i].track_end do
      tmp_t[#tmp_t + 1] = t[ii]
    end
    SetTrackChunkSNM(tptr, table.concat(tmp_t, "\n"))
    tmp_t = {}
  end

  reaper.SetMediaTrackInfo_Value(
    reaper.GetTrack(0, count_child + #new_tracks - 1),
    'I_FOLDERDEPTH', -1
  )
end

local function explodeSubprojects(items)
  if not items or #items == 0 then return end

  local explode_list = {}
  local seen_files   = {}
  local all_items    = {}

  for _, item in ipairs(items) do
    local take = reaper.GetActiveTake(item)
    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      if src then
        local fn = reaper.GetMediaSourceFileName(src, "")
        if fn and fn:sub(-4):lower() == ".rpp" then
          local track = reaper.GetMediaItemTrack(item)
          all_items[#all_items + 1] = { item = item, track = track }
          if not seen_files[fn] then
            seen_files[fn] = true
            explode_list[#explode_list + 1] = { filename = fn, track = track, item = item }
          end
        end
      end
    end
  end

  if #explode_list == 0 then return end

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  for _, entry in ipairs(explode_list) do
    explodeOneSubproject(entry.filename, entry.track, entry.item)
  end
  for _, entry in ipairs(all_items) do
    reaper.SetMediaItemInfo_Value(entry.item, "B_MUTE", 1)
  end

  reaper.Undo_EndBlock("Explode selected subprojects to child tracks", -1)
  reaper.UpdateArrange()
  reaper.PreventUIRefresh(-1)
end

-- ============================================================
-- Feature: run configured export script on selected subproject items
-- ============================================================
local function exportSelectedSubprojects(items)
  if not items or #items == 0 then return end
  local export_path = reaper.GetExtState("SchappsSubprojects", "ExportScript")
  if not export_path or export_path == "" then return end
  if not reaper.file_exists(export_path) then
    reaper.MB("Export script not found:\n\n" .. export_path, "Export Error", 0)
    return
  end
  reaper.Main_OnCommand(40289, 0)
  for _, item in ipairs(items) do reaper.SetMediaItemSelected(item, true) end
  reaper.UpdateArrange()
  local cmd_id = reaper.AddRemoveReaScript(true, 0, export_path, false)
  reaper.Main_OnCommand(cmd_id, 0)
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

  ImGui.SetNextWindowSize(ctx, 800, 500, ImGui.Cond_FirstUseEver)
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

    -- ── Subproject items table ───────────────────────────────────
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, "SUBPROJECT ITEMS")
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    do
      local cur_x   = ImGui.GetCursorPosX(ctx)
      local avail_w = select(1, ImGui.GetContentRegionAvail(ctx))
      local tw      = select(1, ImGui.CalcTextSize(ctx, "⚙"))
      local fpx     = select(1, ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding))
      ImGui.SetCursorPosX(ctx, cur_x + avail_w - tw - fpx * 2)
    end
    if ImGui.SmallButton(ctx, "⚙##settings") then
      ImGui.OpenPopup(ctx, "##settings_popup")
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Settings") end

    if ImGui.BeginPopup(ctx, "##settings_popup") then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
      ImGui.Text(ctx, "SETTINGS")
      ImGui.PopStyleColor(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)
      ImGui.Text(ctx, "Export Script")
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 350)
      local ch, nv = ImGui.InputText(ctx, "##exportpath", export_path_buf, 0)
      if ch then
        export_path_buf = nv
        reaper.SetExtState("SchappsSubprojects", "ExportScript", export_path_buf, true)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Browse...") then
        if reaper.JS_Dialog_BrowseForOpenFiles then
          local retval, path = reaper.JS_Dialog_BrowseForOpenFiles(
            "Select export script", "", "", "Lua scripts (*.lua)\0*.lua\0All files\0*.*\0\0", false)
          if retval and path ~= "" then
            export_path_buf = path
            reaper.SetExtState("SchappsSubprojects", "ExportScript", export_path_buf, true)
            ImGui.CloseCurrentPopup(ctx)
          end
        else
          reaper.MB(
            "Install js_ReaScriptAPI to enable file browsing,\nor paste the script path directly into the field.",
            "Browse", 0)
        end
      end
      if export_path_buf ~= "" then
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Clear") then
          export_path_buf = ""
          reaper.SetExtState("SchappsSubprojects", "ExportScript", "", true)
        end
      end
      ImGui.Spacing(ctx)
      ImGui.EndPopup(ctx)
    end

    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    ImGui.SetNextItemWidth(ctx, -1)
    local sc, search_val = ImGui.InputTextWithHint(ctx, "##search", "Filter by take name...", search_buf, 0)
    if sc then
      search_buf = search_val
      last_clicked_idx = nil
      renaming_idx = nil
    end
    ImGui.Spacing(ctx)

    local lower_search = search_buf:lower()
    local display_rows = {}
    for _, r in ipairs(rows) do
      if lower_search == "" or r.take:lower():find(lower_search, 1, true) then
        display_rows[#display_rows + 1] = r
      end
    end
    if sort_col >= 0 then
      local asc, scol = sort_asc, sort_col
      table.sort(display_rows, function(a, b)
        local va, vb
        if     scol == 1 then va, vb = a.take:lower(),  b.take:lower()
        elseif scol == 2 then va, vb = a.take_idx,      b.take_idx
        elseif scol == 3 then va, vb = a.start,         b.start
        elseif scol == 4 then va, vb = a.track:lower(), b.track:lower()
        elseif scol == 5 then va, vb = a.file:lower(),  b.file:lower()
        else return false end
        if asc then return va < vb else return va > vb end
      end)
    end

    local _, avail_h = ImGui.GetContentRegionAvail(ctx)
    local _, sp_y    = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
    local child_h    = math.max(400, avail_h - ImGui.GetFrameHeight(ctx) - sp_y * 2)
    local child_visible = ImGui.BeginChild(ctx, "##preview", 0, child_h, rawget(ImGui, "ChildFlags_Border") or 1)
    if child_visible then
    if #rows == 0 then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x555555FF)
      ImGui.Text(ctx, "No subproject items in project")
      ImGui.PopStyleColor(ctx)
    elseif #display_rows == 0 then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x555555FF)
      ImGui.Text(ctx, "No items match filter")
      ImGui.PopStyleColor(ctx)
    else
      local SEL_SPAN   = (rawget(ImGui, "SelectableFlags_SpanAllColumns") or 0)
                       | (rawget(ImGui, "SelectableFlags_AllowOverlap")
                          or rawget(ImGui, "SelectableFlags_AllowItemOverlap") or 0)
      local KEY_LCTRL  = rawget(ImGui, "Key_LeftCtrl")
      local KEY_RCTRL  = rawget(ImGui, "Key_RightCtrl")
      local KEY_LSHIFT = rawget(ImGui, "Key_LeftShift")
      local KEY_RSHIFT = rawget(ImGui, "Key_RightShift")
      local row_rects = {}
      local row_h     = ImGui.GetFrameHeight(ctx)
      local hdr_c   = ImGui.GetStyleColor(ctx, ImGui.Col_Header)
      local hdr_dim = (hdr_c & 0xFFFFFF00) | math.floor((hdr_c & 0xFF) * 0.4)
      ImGui.PushStyleColor(ctx, ImGui.Col_Header, hdr_dim)
      ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderLight, 0x3A3F45FF)
      if ImGui.BeginTable(ctx, "##ptable", 6,
          ImGui.TableFlags_BordersInner) then
        ImGui.TableSetupColumn(ctx, "##playcol",    ImGui.TableColumnFlags_WidthFixed, 24)
        ImGui.TableSetupColumn(ctx, "Take Name",    ImGui.TableColumnFlags_WidthStretch)
        ImGui.TableSetupColumn(ctx, "Take Version", ImGui.TableColumnFlags_WidthFixed, 130)
        ImGui.TableSetupColumn(ctx, "Start",        ImGui.TableColumnFlags_WidthFixed, 110)
        ImGui.TableSetupColumn(ctx, "Track",        ImGui.TableColumnFlags_WidthStretch)
        ImGui.TableSetupColumn(ctx, "RPP File",     ImGui.TableColumnFlags_WidthStretch)

        -- Manual header row: click to sort asc, again for desc, third click clears sort
        local hdr_names = { nil, "Take Name", "Take Version", "Start", "Track", "RPP File" }
        ImGui.TableNextRow(ctx, rawget(ImGui, "TableRowFlags_Headers") or 0)
        for col = 0, 5 do
          ImGui.TableSetColumnIndex(ctx, col)
          local name = hdr_names[col + 1]
          if name then
            local arrow = sort_col == col and (sort_asc and " ▲" or " ▼") or ""
            ImGui.TableHeader(ctx, name .. arrow)
            if ImGui.IsItemClicked(ctx, 0) then
              if sort_col == col then
                if sort_asc then sort_asc = false
                else sort_col = -1 end
              else
                sort_col = col
                sort_asc = true
              end
              last_clicked_idx = nil
              renaming_idx     = nil
            end
          else
            ImGui.TableHeader(ctx, "")
          end
        end

        local last_rpp_file = nil
        local rpp_alt       = false
        local row_bg0       = ImGui.GetStyleColor(ctx, ImGui.Col_TableRowBg)
        local row_bg1       = ImGui.GetStyleColor(ctx, ImGui.Col_TableRowBgAlt)
        local tgt_row_bg    = rawget(ImGui, "TableBgTarget_RowBg0") or 1
        for i, r in ipairs(display_rows) do
          ImGui.TableNextRow(ctx)
          local _, row_screen_y = ImGui.GetCursorScreenPos(ctx)
          row_rects[i] = row_screen_y
          if r.file ~= last_rpp_file then
            rpp_alt = not rpp_alt
            last_rpp_file = r.file
          end
          ImGui.TableSetBgColor(ctx, tgt_row_bg, rpp_alt and row_bg1 or row_bg0)
          ImGui.TableSetColumnIndex(ctx, 1)
          if renaming_idx == i then
            if rename_needs_focus then
              ImGui.SetKeyboardFocusHere(ctx)
              rename_needs_focus = false
            end
            ImGui.SetNextItemWidth(ctx, -1)
            local enter_pressed, current_val = ImGui.InputText(ctx, "##rename"..i, rename_buf,
              ImGui.InputTextFlags_EnterReturnsTrue | ImGui.InputTextFlags_AutoSelectAll)
            rename_buf = current_val
            local deactivated = ImGui.IsItemDeactivated(ctx)
            local function commitRename()
              local take = reaper.GetTake(r.item, r.take_idx)
              reaper.Undo_BeginBlock()
              reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", rename_buf, true)
              reaper.UpdateArrange()
              reaper.Undo_EndBlock("Rename take", -1)
              renaming_idx = nil
            end
            if enter_pressed then
              commitRename()
            elseif deactivated then
              local KEY_ESCAPE = rawget(ImGui, "Key_Escape")
              if not (KEY_ESCAPE and ImGui.IsKeyPressed(ctx, KEY_ESCAPE)) then
                commitRename()
              else
                renaming_idx = nil
              end
            end
          else
            local is_sel = reaper_sel[r.item] == true
            if ImGui.Selectable(ctx, "##sel"..i, is_sel, SEL_SPAN) and not lasso_active then
              local ctrl  = (KEY_LCTRL  and ImGui.IsKeyDown(ctx, KEY_LCTRL))
                         or (KEY_RCTRL  and ImGui.IsKeyDown(ctx, KEY_RCTRL))
              local shift = (KEY_LSHIFT and ImGui.IsKeyDown(ctx, KEY_LSHIFT))
                         or (KEY_RSHIFT and ImGui.IsKeyDown(ctx, KEY_RSHIFT))
              if shift and last_clicked_idx then
                local lo = math.min(last_clicked_idx, i)
                local hi = math.max(last_clicked_idx, i)
                for ri = lo, hi do
                  if display_rows[ri] then reaper.SetMediaItemSelected(display_rows[ri].item, true) end
                end
              elseif ctrl then
                reaper.SetMediaItemSelected(r.item, not reaper_sel[r.item])
                last_clicked_idx = i
              else
                reaper.Main_OnCommand(40289, 0)
                reaper.SetMediaItemSelected(r.item, true)
                last_clicked_idx = i
              end
              local pos = reaper.GetMediaItemInfo_Value(r.item, "D_POSITION")
              reaper.SetEditCurPos(pos, true, false)
              reaper.UpdateArrange()
            end
            if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, 0) and not lasso_active then
              renaming_idx = i
              rename_buf = r.take
              rename_needs_focus = true
            end
            ImGui.SameLine(ctx)
            ImGui.Text(ctx, r.take)
          end
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
          ImGui.TableSetColumnIndex(ctx, 3) ImGui.Text(ctx, reaper.format_timestr_pos(r.start, "", -1))
          ImGui.TableSetColumnIndex(ctx, 4) ImGui.Text(ctx, r.track)
          ImGui.TableSetColumnIndex(ctx, 5) ImGui.Text(ctx, r.file)
          -- Play button drawn last so it renders on top of the SpanAllColumns selectable
          ImGui.TableSetColumnIndex(ctx, 0)
          local play_clicked
          if play_img then
            ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 2, 2)
            play_clicked = ImGui.ImageButton(ctx, "##play"..i, play_img, 14, 14)
            ImGui.PopStyleVar(ctx)
          else
            play_clicked = ImGui.SmallButton(ctx, "▶##play"..i)
          end
          if play_clicked then
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
      ImGui.PopStyleColor(ctx, 2)

      -- ── Lasso selection ─────────────────────────────────────────
      -- InvisibleButton fills empty space below the table rows. Pressing it
      -- makes it the active ImGui item, which prevents the parent window from
      -- moving on drag (the fix for window-moves-while-lassoeing). It also
      -- gives a clean hook to detect the drag start without IsAnyItemHovered.
      do
        local ew, eh = ImGui.GetContentRegionAvail(ctx)
        if eh > 0 then
          ImGui.InvisibleButton(ctx, "##lasso_area", ew, eh)
          if not lasso_active and not lasso_pending and ImGui.IsItemClicked(ctx, 0) then
            lasso_pending = true
            lasso_x1, lasso_y1 = ImGui.GetMousePos(ctx)
            lasso_x2, lasso_y2 = lasso_x1, lasso_y1
          end
        end
      end
      local mouse_x, mouse_y = ImGui.GetMousePos(ctx)
      if lasso_pending then
        if ImGui.IsMouseDragging(ctx, 0, 4) then
          lasso_active  = true
          lasso_pending = false
        elseif not ImGui.IsMouseDown(ctx, 0) then
          lasso_pending = false
        end
      end
      if lasso_active then
        if ImGui.IsMouseDown(ctx, 0) then
          lasso_x2, lasso_y2 = mouse_x, mouse_y
          local win_x, win_y = ImGui.GetWindowPos(ctx)
          local win_w, win_h = ImGui.GetWindowSize(ctx)
          local sel_x1 = math.max(math.min(lasso_x1, lasso_x2), win_x)
          local sel_y1 = math.max(math.min(lasso_y1, lasso_y2), win_y)
          local sel_x2 = math.min(math.max(lasso_x1, lasso_x2), win_x + win_w)
          local sel_y2 = math.min(math.max(lasso_y1, lasso_y2), win_y + win_h)
          local dl = ImGui.GetWindowDrawList(ctx)
          ImGui.DrawList_AddRectFilled(dl, sel_x1, sel_y1, sel_x2, sel_y2, 0x3377AA33)
          ImGui.DrawList_AddRect(dl, sel_x1, sel_y1, sel_x2, sel_y2, 0x66BBFFAA, 0, 0, 1)
          local lasso_ctrl = (KEY_LCTRL and ImGui.IsKeyDown(ctx, KEY_LCTRL))
                          or (KEY_RCTRL and ImGui.IsKeyDown(ctx, KEY_RCTRL))
          if not lasso_ctrl then
            for _, r in ipairs(rows) do reaper.SetMediaItemSelected(r.item, false) end
          end
          local y_lo = math.min(lasso_y1, lasso_y2)
          local y_hi = math.max(lasso_y1, lasso_y2)
          for j, ry in pairs(row_rects) do
            if y_hi >= ry and y_lo <= ry + row_h then
              reaper.SetMediaItemSelected(display_rows[j].item, true)
            end
          end
          reaper.UpdateArrange()
        else
          lasso_active = false
        end
      end
    end
    ImGui.EndChild(ctx)
    end -- child_visible

    ImGui.Spacing(ctx)

    -- ── Quick action buttons ─────────────────────────────────────
    local avail_w, _ = ImGui.GetContentRegionAvail(ctx)
    local sp_x, _    = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
    local btn_w      = (avail_w - sp_x * 5) / 6
    local swatch_w   = 18
    local row_sx, row_sy = ImGui.GetCursorScreenPos(ctx)

    local has_export = export_path_buf ~= ""
    if not (has_selection and has_export) then ImGui.BeginDisabled(ctx, true) end
    if ImGui.Button(ctx, "Export", btn_w, 0) then
      exportSelectedSubprojects(valid_selected)
    end
    if not (has_selection and has_export) then ImGui.EndDisabled(ctx) end
    local hov_dis = rawget(ImGui, "HoveredFlags_AllowWhenDisabled") or 0
    if ImGui.IsItemHovered(ctx, hov_dis) and not has_export then
      ImGui.SetTooltip(ctx, "Configure an export script in Settings (⚙)")
    end
    ImGui.SameLine(ctx)
    if not has_selection then ImGui.BeginDisabled(ctx, true) end
    if ImGui.Button(ctx, "Open Selected", btn_w, 0) then
      openSelectedSubprojects(valid_selected)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Update Subprojects", btn_w, 0) then
      updateSubproject(valid_selected)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Duplicate New Version", btn_w, 0) then
      duplicateToNewVersion(valid_selected)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Explode Subprojects", btn_w, 0) then
      explodeSubprojects(valid_selected)
    end
    if not has_selection then ImGui.EndDisabled(ctx) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Color Subprojects", btn_w - swatch_w, 0) then
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

    -- Keyboard shortcuts (suppressed when a text field has keyboard focus)
    if not ImGui.IsAnyItemActive(ctx) then
      local KEY_SPACE = rawget(ImGui, "Key_Space")
      if KEY_SPACE and ImGui.IsKeyPressed(ctx, KEY_SPACE) then
        reaper.Main_OnCommand(40044, 0)
      end
      local KEY_A    = rawget(ImGui, "Key_A")
      local lctrl    = rawget(ImGui, "Key_LeftCtrl")  and ImGui.IsKeyDown(ctx, rawget(ImGui, "Key_LeftCtrl"))
      local rctrl    = rawget(ImGui, "Key_RightCtrl") and ImGui.IsKeyDown(ctx, rawget(ImGui, "Key_RightCtrl"))
      if KEY_A and (lctrl or rctrl) and ImGui.IsKeyPressed(ctx, KEY_A) then
        for _, r in ipairs(display_rows) do
          reaper.SetMediaItemSelected(r.item, true)
        end
        reaper.UpdateArrange()
      end
    end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, cc, vc)

  if still_open then reaper.defer(loop) end
end

reaper.defer(loop)
