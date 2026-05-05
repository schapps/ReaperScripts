-- @description Explode Selected Subprojects to Tracks
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Presents a ReaImGUI dialog showing how many subproject items are selected,
--   then explodes them into child tracks of their parent track.
--   Requires: Schapps Script Resources (install from this repository first).
-- @link https://www.stephenschappler.com
-- @changelog
--   5/2/26 - v1.0 Initial release

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
-- Context + state
-- ============================================================
local script_title = "EXPLODE SUBPROJECTS"
local ctx          = ImGui.CreateContext(script_title)

local WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
               | ImGui.WindowFlags_NoCollapse
               | ImGui.WindowFlags_AlwaysAutoResize
               | ImGui.WindowFlags_NoScrollWithMouse

local delete_items = false
local open         = true

-- ============================================================
-- Core explode logic (adapted from X-Raym / snooks v1.0.1)
-- ============================================================
local function CountChildTrack(track)
  local count = 0
  local depth = reaper.GetTrackDepth(track)
  local track_index = reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER')
  local count_tracks = reaper.CountTracks(0)
  for i = track_index, count_tracks - 1 do
    local tr = reaper.GetTrack(0, i)
    if reaper.GetTrackDepth(tr) > depth then count = count + 1 else break end
  end
  return count
end

local function getFilenameTrackActiveTake(item)
  if item == nil then return nil, nil end
  local tk = reaper.GetActiveTake(item)
  if tk == nil then return nil, nil end
  local pcm_source = reaper.GetMediaItemTake_Source(tk)
  local filename = reaper.GetMediaSourceFileName(pcm_source, "")
  local track = reaper.GetMediaItemTrack(item)
  return filename, track
end

local function getFileExtension(filename)
  return filename:sub(-3):upper()
end

local function getTrackTablePositions(project_table)
  local track_table_positions = {}
  local track_start = 0
  local track_count, track_closers = 0, 0
  for i = 1, #project_table do
    local s = project_table[i]
    if s:sub(3, 8) == "<TRACK" then
      track_count = track_count + 1
      track_start = i
    end
    if s:sub(3, 3) == ">" then
      if track_count > track_closers then
        track_closers = track_closers + 1
        track_table_positions[#track_table_positions + 1] = {
          track_start = track_start,
          track_end   = i,
        }
      end
    end
  end
  return track_table_positions
end

local function fileToTable(filename)
  local t = {}
  local file = io.open(filename, "r")
  if not file then return t end
  for line in file:lines() do
    table.insert(t, line)
  end
  table.insert(t, "")
  file:close()
  return t
end

local function tableToString(t)
  return table.concat(t, "\n")
end

local function SetTrackChunk(track, track_chunk)
  if not (track and track_chunk) then return end
  local fast_str = reaper.SNM_CreateFastString("")
  local ret
  if reaper.SNM_SetFastString(fast_str, track_chunk) then
    ret = reaper.SNM_GetSetObjectState(track, fast_str, true, false)
  end
  reaper.SNM_DeleteFastString(fast_str)
  return ret
end

local function explodeSubproject(filename, track, item)
  local t = fileToTable(filename)
  if #t == 0 then return end

  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  reaper.Main_OnCommand(40289, 0)  -- Item: Unselect all items
  reaper.SetMediaItemSelected(item, true)
  reaper.Main_OnCommand(42228, 0)  -- Item: Set item start/end to source media start/end
  reaper.BR_SetItemEdges(item, item_pos, item_pos + item_len)

  local track_number = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
  reaper.SetMediaTrackInfo_Value(track, 'I_FOLDERDEPTH', 1)
  local count_child = CountChildTrack(track)

  local track_table_positions = getTrackTablePositions(t)
  local new_tracks = {}
  local tmp_t = {}

  for i = 1, #track_table_positions do
    reaper.InsertTrackAtIndex(track_number + i - 1, false)
    local tptr = reaper.GetTrack(0, track_number + i - 1)
    table.insert(new_tracks, tptr)
    local s, e = track_table_positions[i].track_start, track_table_positions[i].track_end
    for ii = s, e do
      tmp_t[#tmp_t + 1] = t[ii]
    end
    SetTrackChunk(tptr, tableToString(tmp_t))
    tmp_t = {}
  end

  reaper.SetMediaTrackInfo_Value(
    reaper.GetTrack(0, count_child + #new_tracks - 1),
    'I_FOLDERDEPTH', -1
  )

  reaper.UpdateArrange()
end

-- ============================================================
-- Helpers
-- ============================================================
-- Returns total RPP item count and unique RPP file count.
local function countSubprojectItems()
  local total = 0
  local unique_files = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local filename, _ = getFilenameTrackActiveTake(item)
    if filename and getFileExtension(filename) == "RPP" then
      total = total + 1
      unique_files[filename] = true
    end
  end
  local unique = 0
  for _ in pairs(unique_files) do unique = unique + 1 end
  return total, unique
end

local function runExplode()
  -- Separate the list into: one explosion entry per unique RPP file (using
  -- the first item encountered for that file), plus all items to mute/delete.
  local explode_list = {}   -- ordered list of {filename, track, item} per unique RPP
  local seen_files  = {}    -- filename -> true, dedup guard
  local all_items   = {}    -- every RPP item to mute/delete

  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local filename, track = getFilenameTrackActiveTake(item)
    if filename and getFileExtension(filename) == "RPP" then
      table.insert(all_items, {item = item, track = track})
      if not seen_files[filename] then
        seen_files[filename] = true
        table.insert(explode_list, {filename = filename, track = track, item = item})
      end
    end
  end

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  for _, entry in ipairs(explode_list) do
    explodeSubproject(entry.filename, entry.track, entry.item)
  end

  for _, entry in ipairs(all_items) do
    if delete_items then
      reaper.DeleteTrackMediaItem(entry.track, entry.item)
    else
      reaper.SetMediaItemInfo_Value(entry.item, "B_MUTE", 1)
    end
  end

  reaper.Undo_EndBlock("Explode selected subprojects to child tracks", -1)
  reaper.UpdateArrange()
  reaper.PreventUIRefresh(-1)
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSize(ctx, 320, 0, ImGui.Cond_FirstUseEver)
  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then
    local total, unique = countSubprojectItems()
    local item_word = total == 1 and "item" or "items"
    local preview
    if unique == total then
      preview = ("Explode %d subproject %s to child tracks"):format(total, item_word)
    else
      local sub_word = unique == 1 and "subproject" or "subprojects"
      preview = ("Explode %d %s (%d unique %s) to child tracks"):format(total, item_word, unique, sub_word)
    end

    -- Preview line
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, preview)
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Options section
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, "Options")
    ImGui.PopStyleColor(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    local _, new_delete = ImGui.Checkbox(ctx, "Delete original item (default: mute)", delete_items)
    delete_items = new_delete

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Buttons: right-aligned Cancel | Explode
    local btn_w = 80
    local sp_x, _ = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
    local avail_w, _ = ImGui.GetContentRegionAvail(ctx)
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail_w - (btn_w * 2) - sp_x)

    if ImGui.Button(ctx, "Cancel", btn_w, 0) then
      open = false
    end

    ImGui.SameLine(ctx)

    local no_items = total == 0
    if no_items then ImGui.BeginDisabled(ctx, true) end
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x2C6B64FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x338077FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x2A5C56FF)
    if ImGui.Button(ctx, "Explode", btn_w, 0) then
      open = false
      runExplode()
    end
    ImGui.PopStyleColor(ctx, 3)
    if no_items then ImGui.EndDisabled(ctx) end

    if not no_items and (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)) then
      open = false
      runExplode()
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
