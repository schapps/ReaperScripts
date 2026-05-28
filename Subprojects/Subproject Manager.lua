-- @description Subproject Manager
-- @author Stephen Schappler
-- @version 1.11
-- @about
--   Unified subproject management window: preview selected subprojects, open them,
--   duplicate to new versioned takes, explode to child tracks, and color all subproject items — all in one ReaImGUI panel.
--   Requires: Schapps ReaImGUI Theme (install from this repository first).
-- @link https://www.stephenschappler.com
-- @changelog
--   05/28/26 - v1.11 Fixing column width display
--   05/26/26 - v1.10 - Making overlapping subproject items (loops), only show up once in table entry
--   05/08/26 - v1.9 Bug fixes and code cleanup (version regex fix, helper extraction, constant hoisting)
--   05/06/26 - v1.8 adding color support
--   05/06/26 - v1.7 adding more columns and allowing for toggling of column visibility
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
local lasso_x2, lasso_y2  = 0, 0  -- current drag end
local sort_col            = -1    -- sorted column index (-1 = unsorted)
local color_pick_items      = nil   -- items to apply color to when picker is open
local color_pick_was_open   = false -- for detecting popup close → end undo block
local color_pick_requested  = false -- deferred OpenPopup flag (child→parent scope)
local sort_asc           = true   -- ascending direction
local export_path_buf    = reaper.GetExtState("SchappsSubprojects", "ExportScript")

-- Column visibility state (cols 3-8 are user-toggleable; 0-2 are always shown)
-- _cv1=col3, _cv2=col4, _cv3=col5, _cv4=col6, _cv5=col7, _cv6=col8
local _cv_raw = reaper.GetExtState("SubprojectManager", "ColumnVisibility")
local _cv1, _cv2, _cv3, _cv4, _cv5, _cv6 = _cv_raw:match("(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)")
local col_visible = {
  [3] = (_cv1 == nil or _cv1 == "1"),
  [4] = (_cv2 == nil or _cv2 == "1"),
  [5] = (_cv3 == nil or _cv3 == "1"),
  [6] = (_cv4 == nil or _cv4 == "1"),
  [7] = (_cv5 == nil or _cv5 == "1"),
  [8] = (_cv6 == nil or _cv6 == "1"),
}
local function saveColVisibility()
  reaper.SetExtState("SubprojectManager", "ColumnVisibility",
    string.format("%d,%d,%d,%d,%d,%d",
      col_visible[3] and 1 or 0, col_visible[4] and 1 or 0,
      col_visible[5] and 1 or 0, col_visible[6] and 1 or 0,
      col_visible[7] and 1 or 0, col_visible[8] and 1 or 0), true)
end
local TableSetColumnEnabled = rawget(ImGui, "TableSetColumnEnabled")

-- ImGui flag constants (resolved once at load time; used inside the render loop)
local SEL_SPAN   = (rawget(ImGui, "SelectableFlags_SpanAllColumns") or 0)
                 | (rawget(ImGui, "SelectableFlags_AllowOverlap")
                    or rawget(ImGui, "SelectableFlags_AllowItemOverlap") or 0)
local KEY_LCTRL  = rawget(ImGui, "Key_LeftCtrl")
local KEY_RCTRL  = rawget(ImGui, "Key_RightCtrl")
local KEY_LSHIFT = rawget(ImGui, "Key_LeftShift")
local KEY_RSHIFT = rawget(ImGui, "Key_RightShift")
local KEY_ESCAPE = rawget(ImGui, "Key_Escape")

-- Constant tables for column header and context-menu labels
local HDR_NAMES  = { nil, nil, "Take Name", "Take Version", "Start", "End", "Length", "Track", "RPP File" }
local COL_LABELS = { [3]="Take Version", [4]="Start", [5]="End", [6]="Length", [7]="Track", [8]="RPP File" }

-- Color picker state
local _cs = reaper.GetExtState("SubprojectManager", "SubprojectColor")
local color_r, color_g, color_b = _cs:match("(%d+),(%d+),(%d+)")
if color_r then
  color_r, color_g, color_b = tonumber(color_r), tonumber(color_g), tonumber(color_b)
else
  color_r, color_g, color_b = 161, 145, 227
end
local color_orig_r, color_orig_g, color_orig_b = color_r, color_g, color_b

local function rgbToImGui(r, g, b)
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

-- ============================================================
-- Utilities
-- ============================================================

local function runCommand(id)
  reaper.Main_OnCommand(id, 0)
end

local function getCurrentProjectName()
  return reaper.GetProjectName(0, "")
end

-- Returns the active take's PCM source for an item, or nil if unavailable.
local function getActiveSrc(item)
  local take = reaper.GetActiveTake(item)
  return take and reaper.GetMediaItemTake_Source(take)
end

-- Opens a project file in a new tab and renders its RPP-PROX proxy.
-- Pass closeAfter=true to close the tab once rendering is done.
local function openAndRenderRPPPROX(filepath, closeAfter)
  reaper.Main_OnCommand(40859, 0)  -- new project tab (keep current)
  reaper.Main_openProject(filepath)
  reaper.Main_OnCommand(42332, 0)  -- save + render RPP-PROX
  if closeAfter then reaper.Main_OnCommand(40860, 0) end  -- close tab
end

-- Clears REAPER's selection and re-selects the given item list.
local function restoreSelection(items)
  reaper.Main_OnCommand(40289, 0)
  for _, item in ipairs(items) do reaper.SetMediaItemSelected(item, true) end
  reaper.UpdateArrange()
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
            local ipos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local ilen  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local icol  = math.floor(reaper.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR"))
            rows[#rows + 1] = { item = item, track = tname, file = basename, takes = tc, take_idx = cur_idx, take = takeName, start = ipos, len = ilen, color = icol }
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
    local src = getActiveSrc(item)
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

-- ============================================================
-- Feature: update (open, render RPP-PROX, close) selected subprojects
-- ============================================================
local function updateSubproject(items)
  if not items or #items == 0 then return end
  local parentName = getCurrentProjectName()
  local rendered = {}
  for _, item in ipairs(items) do
    local src = getActiveSrc(item)
    if src then
      local fp = reaper.GetMediaSourceFileName(src, "")
      if fp and fp:sub(-4):lower() == ".rpp" and not rendered[fp] then
        rendered[fp] = true
        openAndRenderRPPPROX(fp, true)
      end
    end
  end
  activateProjectByName(parentName)
  restoreSelection(items)
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
  local versionMap = {}

  -- First pass: copy RPP to new version, add new take
  for _, item in ipairs(items) do
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
      local origBase, curVer = base:match("^(.*)_v(%d+)$")
      local newVer = curVer and tonumber(curVer) + 1 or 2
      repeat
        newFilePath = string.format("%s/%s_v%02d.%s", folder, origBase or base, newVer, ext)
        newVer = newVer + 1
      until not reaper.file_exists(newFilePath)

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
  for _, item in ipairs(items) do
    if item then
      local src = getActiveSrc(item)
      if src then
        local fp = reaper.GetMediaSourceFileName(src, "")
        if fp and fp:sub(-4):lower() == ".rpp" and not rendered[fp] then
          rendered[fp] = true
          openAndRenderRPPPROX(fp, false)
          activateProjectByName(parentName)
        end
      end
    end
  end

  -- Restore original selection
  restoreSelection(items)

  -- Add take markers showing the new versioned filename
  for _, item in ipairs(items) do
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
    local src = getActiveSrc(item)
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

-- Removes rows where another row shares the same take name and overlaps in time,
-- keeping only the earliest-starting representative for each such group.
local function deduplicateOverlappingRows(rows)
  local result = {}
  for _, r in ipairs(rows) do
    local duplicate = false
    for _, existing in ipairs(result) do
      if r.take == existing.take then
        local r_end = r.start + r.len
        local e_end = existing.start + existing.len
        if r.start < e_end and existing.start < r_end then
          duplicate = true
          break
        end
      end
    end
    if not duplicate then result[#result + 1] = r end
  end
  return result
end

-- Commits an in-progress take rename for row r and closes the rename widget.
local function commitRename(r)
  local take = reaper.GetTake(r.item, r.take_idx)
  reaper.Undo_BeginBlock()
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", rename_buf, true)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Rename take", -1)
  renaming_idx = nil
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
    display_rows = deduplicateOverlappingRows(display_rows)
    if sort_col >= 0 then
      local asc, scol = sort_asc, sort_col
      table.sort(display_rows, function(a, b)
        local va, vb
        if     scol == 2 then va, vb = a.take:lower(),          b.take:lower()
        elseif scol == 3 then va, vb = a.take_idx,              b.take_idx
        elseif scol == 4 then va, vb = a.start,                 b.start
        elseif scol == 5 then va, vb = a.start + a.len,         b.start + b.len
        elseif scol == 6 then va, vb = a.len,                   b.len
        elseif scol == 7 then va, vb = a.track:lower(),         b.track:lower()
        elseif scol == 8 then va, vb = a.file:lower(),          b.file:lower()
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
      local row_rects = {}
      local row_h     = ImGui.GetFrameHeight(ctx)
      local take_name_col_w, track_col_w, rpp_col_w
      do
        local tn_max = select(1, ImGui.CalcTextSize(ctx, "Take Name"))
        local tr_max = select(1, ImGui.CalcTextSize(ctx, "Track"))
        local rp_max = select(1, ImGui.CalcTextSize(ctx, "RPP File"))
        for _, r in ipairs(display_rows) do
          local tn = select(1, ImGui.CalcTextSize(ctx, r.take))
          local tr = select(1, ImGui.CalcTextSize(ctx, r.track))
          local rp = select(1, ImGui.CalcTextSize(ctx, r.file))
          if tn > tn_max then tn_max = tn end
          if tr > tr_max then tr_max = tr end
          if rp > rp_max then rp_max = rp end
        end
        take_name_col_w = tn_max + 16
        track_col_w     = tr_max + 16
        rpp_col_w       = rp_max + 16
      end
      local hdr_c   = ImGui.GetStyleColor(ctx, ImGui.Col_Header)
      local hdr_dim = (hdr_c & 0xFFFFFF00) | math.floor((hdr_c & 0xFF) * 0.4)
      ImGui.PushStyleColor(ctx, ImGui.Col_Header, hdr_dim)
      ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderLight, 0x3A3F45FF)
      if ImGui.BeginTable(ctx, "##ptable", 9,
          ImGui.TableFlags_BordersInner | (rawget(ImGui, "TableFlags_Hideable") or 0)
          | (rawget(ImGui, "TableFlags_ScrollX") or 0)) then
        ImGui.TableSetupColumn(ctx, "##colswatch", ImGui.TableColumnFlags_WidthFixed, 18)
        ImGui.TableSetupColumn(ctx, "##playcol",   ImGui.TableColumnFlags_WidthFixed, 24)
        ImGui.TableSetupColumn(ctx, "Take Name",    ImGui.TableColumnFlags_WidthFixed, take_name_col_w)
        ImGui.TableSetupColumn(ctx, "Take Version", ImGui.TableColumnFlags_WidthFixed, 100)
        ImGui.TableSetupColumn(ctx, "Start",        ImGui.TableColumnFlags_WidthFixed, 85)
        ImGui.TableSetupColumn(ctx, "End",          ImGui.TableColumnFlags_WidthFixed, 85)
        ImGui.TableSetupColumn(ctx, "Length",       ImGui.TableColumnFlags_WidthFixed, 80)
        ImGui.TableSetupColumn(ctx, "Track",        ImGui.TableColumnFlags_WidthFixed, track_col_w)
        ImGui.TableSetupColumn(ctx, "RPP File",     ImGui.TableColumnFlags_WidthFixed, rpp_col_w)
        if TableSetColumnEnabled then
          TableSetColumnEnabled(ctx, 3, col_visible[3])
          TableSetColumnEnabled(ctx, 4, col_visible[4])
          TableSetColumnEnabled(ctx, 5, col_visible[5])
          TableSetColumnEnabled(ctx, 6, col_visible[6])
          TableSetColumnEnabled(ctx, 7, col_visible[7])
          TableSetColumnEnabled(ctx, 8, col_visible[8])
        end

        -- Manual header row: click to sort asc, again for desc, third click clears sort
        ImGui.TableNextRow(ctx, rawget(ImGui, "TableRowFlags_Headers") or 0)
        for col = 0, 8 do
          ImGui.TableSetColumnIndex(ctx, col)
          local name = HDR_NAMES[col + 1]
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
            if ImGui.IsItemClicked(ctx, 1) then
              ImGui.OpenPopup(ctx, "##col_ctx_menu")
            end
          else
            ImGui.TableHeader(ctx, "##h"..col)
          end
        end

        if ImGui.BeginPopup(ctx, "##col_ctx_menu") then
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
          ImGui.Text(ctx, "COLUMNS")
          ImGui.PopStyleColor(ctx)
          ImGui.Separator(ctx)
          ImGui.Spacing(ctx)
          for _, col in ipairs({3, 4, 5, 6, 7, 8}) do
            local changed, new_val = ImGui.Checkbox(ctx, COL_LABELS[col], col_visible[col])
            if changed then
              col_visible[col] = new_val
              saveColVisibility()
            end
          end
          ImGui.Spacing(ctx)
          ImGui.EndPopup(ctx)
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
          ImGui.TableSetColumnIndex(ctx, 2)
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
            if enter_pressed then
              commitRename(r)
            elseif deactivated then
              if not (KEY_ESCAPE and ImGui.IsKeyPressed(ctx, KEY_ESCAPE)) then
                commitRename(r)
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
          if col_visible[3] then
            ImGui.TableSetColumnIndex(ctx, 3)
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
          end
          if col_visible[4] then
            ImGui.TableSetColumnIndex(ctx, 4)
            ImGui.Text(ctx, reaper.format_timestr_pos(r.start, "", -1))
          end
          if col_visible[5] then
            ImGui.TableSetColumnIndex(ctx, 5)
            ImGui.Text(ctx, reaper.format_timestr_pos(r.start + r.len, "", -1))
          end
          if col_visible[6] then
            ImGui.TableSetColumnIndex(ctx, 6)
            ImGui.Text(ctx, reaper.format_timestr_len(r.len, r.start, 64, -1))
          end
          if col_visible[7] then
            ImGui.TableSetColumnIndex(ctx, 7)
            ImGui.Text(ctx, r.track)
          end
          if col_visible[8] then
            ImGui.TableSetColumnIndex(ctx, 8)
            ImGui.Text(ctx, r.file)
          end
          -- Play button and color swatch drawn last, on top of the SpanAllColumns selectable
          ImGui.TableSetColumnIndex(ctx, 1)
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
          -- Color swatch (col 0) — click to open color picker for this item (or all selected)
          ImGui.TableSetColumnIndex(ctx, 0)
          do
            local raw     = r.color
            local has_col = (raw & 0x1000000) ~= 0
            local sw_r, sw_g, sw_b
            if has_col then
              sw_r, sw_g, sw_b = reaper.ColorFromNative(raw)
            else
              sw_r, sw_g, sw_b = 80, 80, 80
            end
            local sw_flags = ImGui.ColorEditFlags_NoTooltip | ImGui.ColorEditFlags_NoBorder
            if ImGui.ColorButton(ctx, "##csw"..i, rgbToImGui(sw_r, sw_g, sw_b), sw_flags, 14, 14) then
              color_pick_items = reaper_sel[r.item] and #valid_selected > 0 and valid_selected or { r.item }
              if has_col then color_r, color_g, color_b = sw_r, sw_g, sw_b end
              reaper.Undo_BeginBlock()
              color_pick_requested = true
            end
            if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Click to set item color") end
          end
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
    -- Fire deferred OpenPopup now that we're back in the parent window scope
    if color_pick_requested then
      ImGui.OpenPopup(ctx, "##color_picker_popup")
      color_pick_requested = false
    end
    end -- child_visible

    ImGui.Spacing(ctx)

    -- ── Quick action buttons ─────────────────────────────────────
    local avail_w, _ = ImGui.GetContentRegionAvail(ctx)
    local sp_x, _    = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
    local btn_w      = (avail_w - sp_x * 4) / 5

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

    -- Detect color picker popup close → end undo block
    do
      local picker_now_open = ImGui.IsPopupOpen(ctx, "##color_picker_popup")
      if color_pick_was_open and not picker_now_open and color_pick_items then
        reaper.Undo_EndBlock("Color subproject items", -1)
        color_pick_items = nil
      end
      color_pick_was_open = picker_now_open
    end

    if ImGui.BeginPopup(ctx, "##color_picker_popup") then
      if ImGui.IsWindowAppearing(ctx) then
        color_orig_r, color_orig_g, color_orig_b = color_r, color_g, color_b
      end
      local picker_flags = rawget(ImGui, "ColorEditFlags_PickerHueBar") or 0
      local cur_col = rgbToImGui(color_r, color_g, color_b)
      local ref_col = rgbToImGui(color_orig_r, color_orig_g, color_orig_b)
      local changed, new_col = ImGui.ColorPicker4(ctx, "##item_color", cur_col, picker_flags, ref_col)
      if changed then
        color_r = (new_col >> 24) & 0xFF
        color_g = (new_col >> 16) & 0xFF
        color_b = (new_col >>  8) & 0xFF
        if color_pick_items then
          for _, item in ipairs(color_pick_items) do
            reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR",
              reaper.ColorToNative(color_r, color_g, color_b) | 0x01000000)
          end
          reaper.UpdateArrange()
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
