-- @description Find and Replace in Track Names
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Finds and replaces text in the names of all selected tracks.
--   Shows a live preview of every name that will change before applying.
--   Options: match case, and Lua pattern mode for regex-style matching
--   with %1 capture references in the replacement.
--   Requires: ReaImGUI, Schapps Script Resources (Common/ReaImGuiTheme.lua).
-- @link https://www.stephenschappler.com
-- @changelog
--   09/21/26 v1.0 - Initial release

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
local EXT_KEY      = "FindReplaceTrackNames"
local DIM_TEXT     = 0xA0A0A0FF
local ERROR_TEXT   = 0xE06C6CFF
local ARROW_TEXT   = 0x7FB8AEFF

-- ============================================================
-- Context + persisted state
-- ============================================================
local ctx       = ImGui.CreateContext("FIND AND REPLACE TRACK NAMES")
local WIN_FLAGS = ImGui.WindowFlags_NoCollapse

local find_buf     = reaper.GetExtState(EXT_KEY, "Find")
local replace_buf  = reaper.GetExtState(EXT_KEY, "Replace")
local match_case   = reaper.GetExtState(EXT_KEY, "MatchCase")   == "true"
local use_patterns = reaper.GetExtState(EXT_KEY, "UsePatterns") == "true"

local function saveOptions()
  reaper.SetExtState(EXT_KEY, "Find",        find_buf,    true)
  reaper.SetExtState(EXT_KEY, "Replace",     replace_buf, true)
  reaper.SetExtState(EXT_KEY, "MatchCase",   match_case   and "true" or "false", true)
  reaper.SetExtState(EXT_KEY, "UsePatterns", use_patterns and "true" or "false", true)
end

-- ============================================================
-- Replacement
-- ============================================================

-- Literal (non-pattern) replace. Done by scanning with plain string.find
-- rather than escaping the needle into a Lua pattern, so every character
-- in both the search and replacement text -- %, $, ^, (), [], etc. -- is
-- treated as itself with no escaping rules for the user to think about.
-- Case-insensitive matching scans a lowercased copy so offsets still line
-- up with the original string, preserving the untouched text's own case.
local function replaceLiteral(str, find, repl, case_sensitive)
  local out, pos, count = {}, 1, 0
  local haystack = case_sensitive and str  or str:lower()
  local needle   = case_sensitive and find or find:lower()

  while true do
    local from, to = haystack:find(needle, pos, true)
    if not from then break end
    out[#out + 1] = str:sub(pos, from - 1)
    out[#out + 1] = repl
    pos   = to + 1
    count = count + 1
  end
  out[#out + 1] = str:sub(pos)

  return table.concat(out), count
end

-- Returns new_name, count, err. In pattern mode an invalid pattern (or a
-- replacement referencing a capture that doesn't exist) raises a Lua error,
-- so gsub is wrapped -- the message is surfaced in the UI instead of
-- spilling to the console on every frame the preview is rebuilt.
local function applyReplacement(name, find, repl, case_sensitive, patterns)
  if patterns then
    local ok, result, count = pcall(string.gsub, name, find, repl)
    if not ok then
      return name, 0, (tostring(result):gsub("^.-:%d+:%s*", ""))
    end
    return result, count, nil
  end
  local result, count = replaceLiteral(name, find, repl, case_sensitive)
  return result, count, nil
end

-- Builds the list of pending changes for the current selection + settings.
-- Recomputed every frame so the preview follows track selection and name
-- edits made in REAPER while the window is open.
local function buildPreview()
  local changes, total_hits, err = {}, 0, nil
  if find_buf == "" then return changes, total_hits, err end

  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    local new_name, count, e = applyReplacement(name, find_buf, replace_buf, match_case, use_patterns)
    if e then return {}, 0, e end
    if count > 0 and new_name ~= name then
      changes[#changes + 1] = {
        track = track,
        num   = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")),
        old   = name,
        new   = new_name,
      }
      total_hits = total_hits + count
    end
  end

  return changes, total_hits, err
end

local function applyChanges(changes)
  if #changes == 0 then return end
  reaper.Undo_BeginBlock()
  for _, c in ipairs(changes) do
    reaper.GetSetMediaTrackInfo_String(c.track, "P_NAME", c.new, true)
  end
  reaper.Undo_EndBlock(
    ("Find and replace in %d track name%s"):format(#changes, #changes == 1 and "" or "s"), -1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSize(ctx, 460, 420, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "FIND AND REPLACE TRACK NAMES", true, WIN_FLAGS)

  if visible then
    local n_sel = reaper.CountSelectedTracks(0)

    -- ---- Status ----
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
    ImGui.Text(ctx, n_sel .. (n_sel == 1 and " track selected" or " tracks selected"))
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)

    -- ---- Find / Replace fields ----
    -- No InputTextFlags_EnterReturnsTrue here: with that flag ReaImGui only
    -- hands back the edited buffer on the frame Enter is pressed, so the
    -- value passed in below stays stale while typing and the field re-seeds
    -- from it (losing the text) the moment it deactivates. Enter-to-apply is
    -- handled on the Replace button instead, as elsewhere in this repo.
    if ImGui.BeginTable(ctx, "##fields", 2) then
      ImGui.TableSetupColumn(ctx, "##label", ImGui.TableColumnFlags_WidthFixed, 60)
      ImGui.TableSetupColumn(ctx, "##input", ImGui.TableColumnFlags_WidthStretch)

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, "Find")
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, new_find = ImGui.InputText(ctx, "##find", find_buf)
      if new_find ~= find_buf then
        find_buf = new_find
        saveOptions()
      end

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, "Replace")
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, new_repl = ImGui.InputText(ctx, "##replace", replace_buf)
      if new_repl ~= replace_buf then
        replace_buf = new_repl
        saveOptions()
      end

      ImGui.EndTable(ctx)
    end

    ImGui.Spacing(ctx)

    -- ---- Options ----
    -- Lua patterns are always case-sensitive (there's no case-insensitive
    -- flag), so Match case is pinned on and disabled in pattern mode
    -- rather than silently doing nothing.
    if use_patterns then ImGui.BeginDisabled(ctx, true) end
    local _, new_case = ImGui.Checkbox(ctx, "Match case", use_patterns or match_case)
    if not use_patterns and new_case ~= match_case then
      match_case = new_case
      saveOptions()
    end
    if use_patterns then ImGui.EndDisabled(ctx) end
    if ImGui.IsItemHovered(ctx) and use_patterns then
      ImGui.SetTooltip(ctx, "Lua patterns are always case-sensitive")
    end

    ImGui.SameLine(ctx, 0, 20)
    local _, new_pat = ImGui.Checkbox(ctx, "Use Lua patterns", use_patterns)
    if new_pat ~= use_patterns then
      use_patterns = new_pat
      saveOptions()
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx,
        "Treat Find as a Lua pattern (e.g. ^%a+ or [0-9]+).\n" ..
        "The replacement can reference captures as %1, %2, ...\n" ..
        "Off: Find and Replace are matched literally.")
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- ---- Preview ----
    local changes, total_hits, err = buildPreview()

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
    if err then
      ImGui.PopStyleColor(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, ERROR_TEXT)
      ImGui.Text(ctx, "Pattern error: " .. err)
    elseif find_buf == "" then
      ImGui.Text(ctx, "Preview")
    else
      ImGui.Text(ctx, ("Preview -- %d name%s, %d match%s"):format(
        #changes,    #changes   == 1 and "" or "s",
        total_hits,  total_hits == 1 and "" or "es"))
    end
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)

    -- Leave room below the list for the Apply button + its spacing
    local btn_h      = theme.PrimaryButtonHeight(ctx)
    local _, spacing = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
    local list_h     = select(2, ImGui.GetContentRegionAvail(ctx)) - btn_h - spacing * 2

    -- Per BeginChild's own doc, EndChild must be called regardless of this
    -- return value -- only the body below is skipped when not visible.
    local list_visible = ImGui.BeginChild(ctx, "##preview", 0, math.max(list_h, 60),
      ImGui.ChildFlags_Borders)
    if list_visible then
      if #changes == 0 then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
        if n_sel == 0 then
          ImGui.Text(ctx, "Select one or more tracks.")
        elseif find_buf == "" then
          ImGui.Text(ctx, "Enter text to find.")
        elseif not err then
          ImGui.Text(ctx, "No matches in the selected track names.")
        end
        ImGui.PopStyleColor(ctx)
      else
        for _, c in ipairs(changes) do
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
          ImGui.Text(ctx, ("%d."):format(c.num))
          ImGui.PopStyleColor(ctx)
          ImGui.SameLine(ctx)
          ImGui.Text(ctx, c.old == "" and "(unnamed)" or c.old)
          ImGui.SameLine(ctx)
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, ARROW_TEXT)
          ImGui.Text(ctx, "\u{2192}")
          ImGui.PopStyleColor(ctx)
          ImGui.SameLine(ctx)
          ImGui.Text(ctx, c.new == "" and "(unnamed)" or c.new)
        end
      end
    end
    ImGui.EndChild(ctx)

    ImGui.Spacing(ctx)

    -- ---- Apply ----
    local can_apply = #changes > 0 and not err
    if not can_apply then ImGui.BeginDisabled(ctx, true) end
    local do_replace = theme.PrimaryButton(ctx, "Replace", -1, 0, nil, theme.Icons.PENCIL)
      or (can_apply and ImGui.IsWindowFocused(ctx) and (
            ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
            or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)))
    if do_replace then
      applyChanges(changes)
    end
    if not can_apply then ImGui.EndDisabled(ctx) end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)

  if open then reaper.defer(loop) end
end

-- ============================================================
-- Entry point
-- ============================================================
reaper.defer(loop)
