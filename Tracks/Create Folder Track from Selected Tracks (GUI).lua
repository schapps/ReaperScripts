-- @description Create Folder Track from Selected Tracks (GUI)
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Wraps the selected tracks in a new folder track. The folder is inserted
--   where the first selected track sits and every selected track is moved
--   into it as a child.
--   Options:
--     - Folder Name: optional name for the new folder track.
--     - Name folder after first selected track: used when Folder Name is
--       left empty.
--     - Clear child track names: blanks the names of the moved tracks.
--   Requires: ReaImGUI, Schapps Script Resources (Common/ReaImGuiTheme.lua).
-- @link https://www.stephenschappler.com
-- @changelog
--   09/29/26 v1.0 - Initial release

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
local EXT_KEY    = "CreateFolderFromSelectedTracks"
local WIN_TITLE  = "CREATE FOLDER TRACK"
local DIM_TEXT   = 0xA0A0A0FF
local WIN_W      = 380

-- ============================================================
-- Settings. The two checkboxes persist to ExtState; the folder name is
-- per-use, so it lives only for the session and clears after each create.
-- ============================================================
local DEFAULTS = {
  name_from_first = false,
  clear_children  = false,
}

local S = { folder_name = "" }
local dirty = false

local function loadSettings()
  for k, default in pairs(DEFAULTS) do
    local raw = reaper.GetExtState(EXT_KEY, k)
    if raw == "" then S[k] = default else S[k] = raw == "true" end
  end
end

local function saveSettings()
  for k in pairs(DEFAULTS) do
    reaper.SetExtState(EXT_KEY, k, S[k] and "true" or "false", true)
  end
end

loadSettings()

-- ============================================================
-- Folder creation
-- ============================================================
local function trackName(track)
  local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  return name
end

-- An explicit Folder Name wins; the first selected track's name is the
-- fallback when that option is on. Read before the children are cleared.
local function resolveFolderName()
  if S.folder_name ~= "" then return S.folder_name end
  if S.name_from_first and reaper.CountSelectedTracks(0) > 0 then
    return trackName(reaper.GetSelectedTrack(0, 0))
  end
  return ""
end

local function createFolder()
  local n_sel = reaper.CountSelectedTracks(0)
  if n_sel == 0 then return end

  local children = {}
  for i = 0, n_sel - 1 do
    children[#children + 1] = reaper.GetSelectedTrack(0, i)
  end
  local folder_name = resolveFolderName()

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  -- Inserting at the first selected track's index puts the folder at that
  -- track's depth -- inside whatever folder it already lived in, if any.
  local idx = math.floor(reaper.GetMediaTrackInfo_Value(children[1], "IP_TRACKNUMBER")) - 1
  reaper.InsertTrackAtIndex(idx, true)
  local folder = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(folder, "P_NAME", folder_name, true)

  -- makePrevFolder = 1: the moved tracks become children of the track just
  -- before beforeTrackIdx, i.e. the new folder. Non-contiguous selections
  -- are gathered together under it.
  reaper.ReorderSelectedTracks(idx + 1, 1)

  if S.clear_children then
    for _, track in ipairs(children) do
      reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", true)
    end
  end

  reaper.SetOnlyTrackSelected(folder)

  reaper.Undo_EndBlock(
    ("Create folder track from %d selected track%s"):format(n_sel, n_sel == 1 and "" or "s"), -1)
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  S.folder_name = ""
end

-- ============================================================
-- Context
-- ============================================================
local ctx         = ImGui.CreateContext(WIN_TITLE)
local WIN_FLAGS   = ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_AlwaysAutoResize
local first_frame = true

-- ============================================================
-- UI helpers
-- ============================================================
local function tooltipLast(text)
  if text and ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
    ImGui.SetTooltip(ctx, text)
  end
end

local function sectionLabel(text)
  theme.PushBoldFont(ctx)
  ImGui.Text(ctx, text)
  theme.PopBoldFont(ctx)
end

local function checkField(label, key, tooltip)
  local _, v = ImGui.Checkbox(ctx, label .. "##" .. key, S[key])
  if v ~= S[key] then S[key] = v; dirty = true end
  tooltipLast(tooltip)
end

local function dimText(text)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
  ImGui.Text(ctx, text)
  ImGui.PopStyleColor(ctx)
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  dirty = false
  local color_count, var_count = theme.Push(ctx)

  local visible, open = ImGui.Begin(ctx, WIN_TITLE, true, WIN_FLAGS)

  if visible then
    local n_sel = reaper.CountSelectedTracks(0)

    -- ---- Folder name ----
    sectionLabel("FOLDER NAME")

    -- The hint previews the fallback name, so it's clear what an empty
    -- field will produce.
    local hint = "Optional"
    if S.name_from_first and n_sel > 0 then
      local first_name = trackName(reaper.GetSelectedTrack(0, 0))
      hint = first_name ~= "" and first_name or "(first track is unnamed)"
    end

    if first_frame then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, WIN_W)
    local _, name = ImGui.InputTextWithHint(ctx, "##folder_name", hint, S.folder_name)
    S.folder_name = name

    ImGui.Spacing(ctx)

    -- ---- Options ----
    sectionLabel("OPTIONS")
    checkField("Name folder after first selected track", "name_from_first",
      "Used when Folder Name is empty.\n" ..
      "With several tracks selected, the topmost one's name is used.")
    checkField("Clear child track names", "clear_children",
      "Blank the names of the selected tracks after moving them\n" ..
      "into the folder.")

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- ---- Create ----
    local can_create = n_sel > 0
    if not can_create then ImGui.BeginDisabled(ctx, true) end
    local do_create = theme.PrimaryButton(ctx, "Create Folder", WIN_W, 0, nil, theme.Icons.FOLDER)
      or (can_create and ImGui.IsWindowFocused(ctx) and (
            ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
            or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)))
    if not can_create then ImGui.EndDisabled(ctx) end

    local status_text = n_sel == 0 and "Select one or more tracks"
      or (n_sel .. (n_sel == 1 and " track selected" or " tracks selected"))
    local status_w = ImGui.CalcTextSize(ctx, status_text)
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + (WIN_W - status_w) / 2)
    dimText(status_text)

    -- Deferred until the frame's widgets are drawn, so the undo block never
    -- runs with widgets still queued behind it.
    if do_create then createFolder() end

    first_frame = false
    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)

  if dirty then saveSettings() end
  if open then reaper.defer(loop) end
end

-- ============================================================
-- Entry point
-- ============================================================
reaper.defer(loop)
