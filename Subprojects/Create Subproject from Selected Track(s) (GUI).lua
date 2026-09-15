-- @description Create Subproject from Selected Track(s) (GUI)
-- @author Stephen Schappler
-- @version 1.10
-- @about
--   ReaImGUI version of the subproject creation script.
--   Presents a dialog to optionally set a Name, Channels, Tail, and Copy Video Tracks
--   before running the Subproject Workflow.
--   Requires: Schapps Script Resources (install from this repository first).
-- @link https://www.stephenschappler.com
-- @changelog
--   09/13/26 - v1.10 Added a "Subprojects Folder" option that saves each subproject's .RPP/render into its own "Subprojects/<name>" folder inside the project directory instead of the project's normal media/recording path, and copies all referenced (non-video) media into a "Media" subfolder there so the subproject is self-contained.
--   09/06/26 - v1.9 Added a "Version Track" option that appends _v01 to the subproject name, so Duplicate Subproject Version can find it and continue the sequence.
--   08/23/26 - v1.8 Create button now uses the shared theme's
--                   PrimaryButton style, with a square-plus icon.
--   5/18/26 - v1.7 Remove Cancel button, rename Ok to Create
--   5/07/26 - v1.6 Color Changes
--   5/06/26 - v1.5 Removing Provides
--   4/27/26 - v1.4 Fixing window title
--   4/27/26 - v1.3 Adding provides for ReaImGui Theme
--   3/31/26 - v1.2 Added option to run Dynamic Split on rendered item after creation
--   3/31/26 - v1.1 Added in option to auto close subproject after creation
--   3/28/26 - v1.0 Initial release with ReaImGUI dialog



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
-- Context + state variables
-- ============================================================
local script_title  = "CREATE SUBPROJECT"
local ctx           = ImGui.CreateContext(script_title)

local WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
               | ImGui.WindowFlags_NoCollapse
               | ImGui.WindowFlags_AlwaysAutoResize
               | ImGui.WindowFlags_NoScrollWithMouse

local name_buf       = ""      -- empty = REAPER default naming
local channels_auto  = true    -- true = Auto; false = manual
local channels_buf   = "2"     -- used when channels_auto is false
local tail_buf       = "0.000" -- seconds
local copy_video          = reaper.GetExtState("CreateSubproject", "CopyVideoTracks") == "true"
local close_after         = reaper.GetExtState("CreateSubproject", "CloseAfterCreation") == "true"
local run_dynamic_split   = reaper.GetExtState("CreateSubproject", "RunDynamicSplit") == "true"
local version_track       = reaper.GetExtState("CreateSubproject", "VersionTrack") == "true"
local subproject_folder   = reaper.GetExtState("CreateSubproject", "SubprojectFolder") == "true"
local open           = true    -- window open/close flag

-- ============================================================
-- Helper functions (ported as locals from original script)
-- ============================================================

local function containsString(str, substr)
  return string.find(str, substr, 1, true) ~= nil
end

local function toAbsolutePath(path)
  local res_path = reaper.GetResourcePath()
  return reaper.file_exists(path) and path or (res_path .. "\\" .. path)
end

local function getItemChannelCount(item)
  local take = reaper.GetActiveTake(item)
  if not take then return 0 end
  local source = reaper.GetMediaItemTake_Source(take)
  if not source then return 0 end
  return reaper.GetMediaSourceNumChannels(source)
end

local function setTrackChannelCount(track, channelCount)
  reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", channelCount)
end

local function adjustTrackChannelCountToMatchItem(item)
  local track = reaper.GetMediaItem_Track(item)
  if not track then return end
  local channelCount = getItemChannelCount(item)
  if channelCount > 0 then
    setTrackChannelCount(track, channelCount)
  end
end

local function getLastRenderedItem()
  local numItems = reaper.CountMediaItems(0)
  if numItems == 0 then return nil end
  return reaper.GetMediaItem(0, numItems - 1)
end

local function runCommand(commandID)
  reaper.Main_OnCommand(commandID, 0)
end

local function clearAllMarkers()
  local i = reaper.CountProjectMarkers(0) - 1
  while i >= 0 do
    local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(i)
    reaper.DeleteProjectMarker(0, markrgnindexnumber, isrgn)
    i = i - 1
  end
end

local function addMarkersToTimeSelection(tail)
  tail = tail or 0.0
  local startTime, endTime = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if startTime ~= endTime then
    clearAllMarkers()
    reaper.AddProjectMarker(0, false, startTime, 0, "=START", -1)
    reaper.AddProjectMarker(0, false, endTime + tail, 0, "=END", -1)
  else
    reaper.ShowMessageBox(
      "No time selection set. Please set a time selection and run the script again.",
      "Error", 0)
  end
end

local function getCurrentProjectName()
  return reaper.GetProjectName(0, "")
end

local function activateProjectByName(targetName)
  local projIndex = 0
  while true do
    local proj = reaper.EnumProjects(projIndex, "")
    if not proj then break end
    local projectName = reaper.GetProjectName(proj, "")
    if projectName == nil then projectName = "Unnamed Project" end
    if projectName == targetName then
      reaper.SelectProjectInstance(proj)
      break
    end
    projIndex = projIndex + 1
  end
end

-- Appends "_v01" to `base` for Version Track mode, unless it already ends
-- in a "_vNN" suffix (so re-running this on an already-versioned name
-- doesn't stack a second one). Duplicate Subproject Version reads this
-- same "_vNN" pattern to know the next version to suggest.
local function apply_version_suffix(base)
  if base:match("_v%d%d$") then
    return base
  end
  return base ~= "" and (base .. "_v01") or "v01"
end

local function isTimeSelectionPresent()
  local startTime, endTime = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  return startTime ~= endTime
end

local function areItemsSelected()
  return reaper.CountSelectedMediaItems(0) > 0
end

-- ============================================================
-- Main action: create the subproject using dialog values
-- ============================================================
local function collectVideoTrackChunks()
  local chunks = {}
  local num_tracks = reaper.CountTracks(0)
  for i = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(track, "")
    if name:lower():find("video", 1, true) then
      local ok, chunk = reaper.GetTrackStateChunk(track, "", false)
      if ok then table.insert(chunks, chunk) end
    end
  end
  return chunks
end

-- subproj: explicit ReaProject* handle for the subproject, to avoid using the
-- Lua execution context's project `0` which still refers to the parent project
-- after the tab switch performed by runCommand(41816).
local function pasteVideoTracksAtTop(chunks, subproj)
  for i = #chunks, 1, -1 do
    reaper.InsertTrackAtIndex(0, false)
    local new_track = reaper.GetTrack(subproj, 0)
    reaper.SetTrackStateChunk(new_track, chunks[i], false)
  end
  reaper.TrackList_AdjustWindows(false)
end

-- Strips characters that are invalid in file/folder names on Windows or macOS
-- so the subproject name can double as a folder name.
local function sanitizeFolderName(name)
  name = (name or ""):gsub('[\\/:%*%?"<>|]', "_")
  return name:match("^%s*(.-)%s*$")
end

-- Subproject creation (41997) writes the new .RPP/render to the project's
-- current recording path (RECORD_PATH), which is what REAPER's docs call the
-- project's "media" path. Temporarily pointing RECORD_PATH at a relative
-- "Subprojects/<name>" folder redirects just this operation into its own
-- subfolder of the project directory, without touching the user's normal
-- recording path setting.
local function beginSubprojectFolderOverride(name)
  if not subproject_folder then return nil end
  local _, original = reaper.GetSetProjectInfo_String(0, "RECORD_PATH", "", false)
  local sanitized = sanitizeFolderName(name)
  local target = sanitized ~= "" and ("Subprojects/" .. sanitized) or "Subprojects"
  reaper.GetSetProjectInfo_String(0, "RECORD_PATH", target, true)
  return original
end

local function endSubprojectFolderOverride(original)
  if not subproject_folder then return end
  reaper.GetSetProjectInfo_String(0, "RECORD_PATH", original or "", true)
end

local VIDEO_EXTENSIONS = {
  mp4 = true, mov = true, avi = true, wmv = true, mkv = true, mpg = true,
  mpeg = true, m4v = true, webm = true, mxf = true, vob = true, flv = true,
  ogv = true, asf = true, ["3gp"] = true,
}

local function isVideoFile(path)
  local ext = path:match("%.([^.\\/]+)$")
  return ext ~= nil and VIDEO_EXTENSIONS[ext:lower()] == true
end

-- Appends " (1)", " (2)", ... before the extension until the name is free,
-- so consolidating media never silently clobbers an unrelated file that
-- already has the same name in the destination folder.
local function uniqueMediaDestPath(dir, filename)
  local base, ext = filename:match("^(.*)%.([^.]+)$")
  base = base or filename
  local candidate = dir .. "/" .. filename
  local n = 1
  while reaper.file_exists(candidate) do
    candidate = ext and (dir .. "/" .. base .. " (" .. n .. ")." .. ext)
                     or (dir .. "/" .. base .. " (" .. n .. ")")
    n = n + 1
  end
  return candidate
end

local function copyFileBytes(src_path, dst_path)
  local src_f = io.open(src_path, "rb")
  if not src_f then return false end
  local data = src_f:read("a")
  src_f:close()
  local dst_f = io.open(dst_path, "wb")
  if not dst_f then return false end
  dst_f:write(data)
  dst_f:close()
  return true
end

-- Copies every non-video media file referenced by the subproject's items
-- into a "Media" folder alongside its .RPP, and repoints those takes at the
-- copies, so the subproject folder is self-contained. Video files are left
-- referencing their original location (they're typically large, shared with
-- other projects, and already handled separately via pasteVideoTracksAtTop).
local function consolidateSubprojectMedia(subproj, media_dir)
  local copied_path = {} -- origFile -> new path (or false on failure), copy once per source
  local num_tracks = reaper.CountTracks(subproj)
  for ti = 0, num_tracks - 1 do
    local track = reaper.GetTrack(subproj, ti)
    local num_items = reaper.CountTrackMediaItems(track)
    for ii = 0, num_items - 1 do
      local item = reaper.GetTrackMediaItem(track, ii)
      local num_takes = reaper.CountTakes(item)
      for tk = 0, num_takes - 1 do
        local take = reaper.GetTake(item, tk)
        if take and not reaper.TakeIsMIDI(take) then
          local src = reaper.GetMediaItemTake_Source(take)
          local origFile = src and reaper.GetMediaSourceFileName(src, "") or ""
          if origFile ~= "" and not isVideoFile(origFile) then
            local newFilePath = copied_path[origFile]
            if newFilePath == nil then
              reaper.RecursiveCreateDirectory(media_dir, 0)
              local filename = origFile:match("([^\\/]+)$") or origFile
              local dest = uniqueMediaDestPath(media_dir, filename)
              newFilePath = copyFileBytes(origFile, dest) and dest or false
              copied_path[origFile] = newFilePath
            end
            if newFilePath then
              local new_source = reaper.PCM_Source_CreateFromFile(newFilePath)
              if new_source then
                reaper.SetMediaItemTake_Source(take, new_source)
                reaper.PCM_Source_Destroy(src)
              end
            end
          end
        end
      end
    end
  end
end

local function createSubproject()
  local tail_seconds = tonumber(tail_buf) or 0.0
  local manual_chans = nil
  if not channels_auto then
    manual_chans = math.max(2, math.floor(tonumber(channels_buf) or 2))
  end

  -- Collect video track chunks from parent BEFORE any tracks are moved
  local video_chunks = copy_video and collectVideoTrackChunks() or {}

  local first_track = reaper.GetSelectedTrack(0, 0)
  local final_name = ""

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Set custom name on track BEFORE command 41997.
  -- The track moves into the subproject, so the name sticks there
  -- and also appears on the parent timeline item. Do NOT touch the
  -- track handle after 41997 — it is stale.
  if first_track then
    final_name = name_buf
    if final_name == "" then
      local _, existing = reaper.GetSetMediaTrackInfo_String(first_track, "P_NAME", "", false)
      final_name = existing or ""
    end
    if version_track then
      final_name = apply_version_suffix(final_name)
    end
    if final_name ~= "" then
      reaper.GetSetMediaTrackInfo_String(first_track, "P_NAME", final_name, true)
    end
  end

  if isTimeSelectionPresent() or areItemsSelected() then
    local parentName = getCurrentProjectName()

    local original_record_path = beginSubprojectFolderOverride(final_name)
    runCommand(40290)  -- Time selection: Set time selection to items
    runCommand(41997)  -- Move tracks to subproject
    runCommand(41205)  -- Move position of item to edit cursor
    runCommand(41816)  -- Open associated project in new tab
    endSubprojectFolderOverride(original_record_path)

    -- Grab an explicit handle to the subproject. reaper.EnumProjects(-1) returns
    -- the currently focused project (the subproject tab just opened), which is
    -- needed because GetTrack/GetMasterTrack with project arg `0` still refers
    -- to the parent project within this Lua execution context.
    local subproj = reaper.EnumProjects(-1, "")

    -- Set subproject master track channel count before rendering so the
    -- RPP-Prox output has the correct number of channels.
    if not channels_auto and manual_chans then
      local master = reaper.GetMasterTrack(subproj)
      if master then setTrackChannelCount(master, manual_chans) end
    end

    -- Paste copied video tracks at the top of the subproject track list
    if #video_chunks > 0 then
      pasteVideoTracksAtTop(video_chunks, subproj)
    end

    addMarkersToTimeSelection(tail_seconds)

    runCommand(40031)  -- View: Zoom Time Selection
    runCommand(42332)  -- Save project and render RPP-Prox

    if subproject_folder then
      local _, subproj_rpp_path = reaper.EnumProjects(-1, "")
      local subproj_dir = subproj_rpp_path and subproj_rpp_path:match("^(.*)[\\/][^\\/]-$")
      if subproj_dir then
        consolidateSubprojectMedia(subproj, subproj_dir .. "/Media")
        runCommand(40026)  -- File: Save project (persist relinked sources)
      end
    end

    if close_after then runCommand(40860) end  -- Close current project tab

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

    if run_dynamic_split then runCommand(42951) end  -- Dynamic split items using most recent settings

    runCommand(40635)  -- Clear time selection

    reaper.Undo_EndBlock("Create subproject from selected track(s)", -1)
  else
    -- Basic path: no time selection or items — just create and open
    local parentName = getCurrentProjectName()
    local original_record_path = beginSubprojectFolderOverride(final_name)
    runCommand(41997)
    runCommand(41816)
    endSubprojectFolderOverride(original_record_path)

    if #video_chunks > 0 then
      local subproj = reaper.EnumProjects(-1, "")
      pasteVideoTracksAtTop(video_chunks, subproj)
    end

    if close_after then
      runCommand(40026)  -- Save project
      runCommand(40860)  -- Close current project tab
    end

    reaper.Undo_EndBlock("Create subproject (basic path)", -1)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSize(ctx, 320, 0, ImGui.Cond_FirstUseEver)
  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then
    -- ---- 2-column table: left = input, right = label ----
    if ImGui.BeginTable(ctx, "##fields", 2) then
      ImGui.TableSetupColumn(ctx, "##input", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableSetupColumn(ctx, "##label", ImGui.TableColumnFlags_WidthFixed, 80)

      -- Row 1: Name
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, new_name = ImGui.InputTextWithHint(ctx, "##name", "optional", name_buf)
      name_buf = new_name
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Name")

      -- Row 2: Channels
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      if channels_auto then
        ImGui.BeginDisabled(ctx, true)
        ImGui.SetNextItemWidth(ctx, 110)
        ImGui.InputText(ctx, "##channels_display", "Auto", ImGui.InputTextFlags_ReadOnly)
        ImGui.EndDisabled(ctx)
      else
        ImGui.SetNextItemWidth(ctx, 110)
        local _, new_ch = ImGui.InputText(ctx, "##channels_val", channels_buf,
          ImGui.InputTextFlags_CharsDecimal)
        channels_buf = new_ch
      end
      ImGui.SameLine(ctx)
      local _, new_auto = ImGui.Checkbox(ctx, "Auto##ch_auto", channels_auto)
      channels_auto = new_auto
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Channels")

      -- Row 3: Tail
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, new_tail = ImGui.InputText(ctx, "##tail", tail_buf,
        ImGui.InputTextFlags_CharsDecimal)
      tail_buf = new_tail
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Tail  (sec)")

      ImGui.EndTable(ctx)
    end

    -- ---- 2-column options grid ----
    ImGui.Spacing(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, "Options")
    ImGui.PopStyleColor(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    if ImGui.BeginTable(ctx, "##options", 1) then
      ImGui.TableSetupColumn(ctx, "##opt0", ImGui.TableColumnFlags_WidthStretch)

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local _, new_copy_video = ImGui.Checkbox(ctx, "Copy Video Track(s)", copy_video)
      copy_video = new_copy_video

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local _, new_run_dynamic_split = ImGui.Checkbox(ctx, "Run Dynamic Split", run_dynamic_split)
      run_dynamic_split = new_run_dynamic_split

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local _, new_close_after = ImGui.Checkbox(ctx, "Close Subproject After Creation", close_after)
      close_after = new_close_after

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local _, new_version_track = ImGui.Checkbox(ctx, "Version Track (append _v01)", version_track)
      version_track = new_version_track
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, "Marks this as version 1 so Duplicate Subproject Version can find it and continue the sequence (v02, v03, ...).")
      end

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local _, new_subproject_folder = ImGui.Checkbox(ctx, "Use Subprojects Folder", subproject_folder)
      subproject_folder = new_subproject_folder
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, "Saves this subproject's .RPP and rendered audio into its own\n"
          .. "folder named after the subproject, inside a \"Subprojects\" folder\n"
          .. "in the project directory (e.g. Subprojects/<name>/).\n\n"
          .. "Also copies every non-video media file the subproject references\n"
          .. "into a \"Media\" subfolder there and relinks to the copies, so the\n"
          .. "subproject is self-contained. Video files are left referencing\n"
          .. "their original location.")
      end

      ImGui.EndTable(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Status line (gray text)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    local cur_sel = reaper.CountSelectedTracks(0)
    local track_word = cur_sel == 1 and "track" or "tracks"
    ImGui.Text(ctx, ("Create subproject from %d selected %s"):format(cur_sel, track_word))
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)

    -- Create button (disabled when no tracks are selected)
    local no_tracks = reaper.CountSelectedTracks(0) == 0
    if no_tracks then ImGui.BeginDisabled(ctx, true) end
    if theme.PrimaryButton(ctx, "Create", -1, 0, nil, theme.Icons.SQUARE_PLUS) then
      open = false
      reaper.SetExtState("CreateSubproject", "CopyVideoTracks", copy_video and "true" or "false", true)
      reaper.SetExtState("CreateSubproject", "CloseAfterCreation", close_after and "true" or "false", true)
      reaper.SetExtState("CreateSubproject", "RunDynamicSplit", run_dynamic_split and "true" or "false", true)
      reaper.SetExtState("CreateSubproject", "VersionTrack", version_track and "true" or "false", true)
      reaper.SetExtState("CreateSubproject", "SubprojectFolder", subproject_folder and "true" or "false", true)
      createSubproject()
    end
    if no_tracks then ImGui.EndDisabled(ctx) end

    -- Enter key as shortcut for Create
    if not no_tracks and (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)) then
      open = false
      reaper.SetExtState("CreateSubproject", "CopyVideoTracks", copy_video and "true" or "false", true)
      reaper.SetExtState("CreateSubproject", "CloseAfterCreation", close_after and "true" or "false", true)
      reaper.SetExtState("CreateSubproject", "RunDynamicSplit", run_dynamic_split and "true" or "false", true)
      reaper.SetExtState("CreateSubproject", "VersionTrack", version_track and "true" or "false", true)
      reaper.SetExtState("CreateSubproject", "SubprojectFolder", subproject_folder and "true" or "false", true)
      createSubproject()
    end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)

  if still_open and open then
    reaper.defer(loop)
  end
end

-- ============================================================
-- Entry point
-- ============================================================
reaper.defer(loop)
