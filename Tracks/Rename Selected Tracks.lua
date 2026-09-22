-- @description Rename Selected Tracks
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Batch renaming for all selected tracks, in four independently
--   toggleable stages applied top to bottom:
--     1. Replace   - find/replace (literal or Lua pattern), optionally
--                    clearing the existing name first.
--     2. Trim      - drop N characters from the beginning and/or end, or
--                    keep only a character range.
--     3. Add       - prefix, suffix, and/or insert text at a character index.
--     4. Numbering - append/prepend an incrementing number or letter.
--   A live preview lists every name that will change before applying.
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
local EXT_KEY    = "RenameSelectedTracks"
local DIM_TEXT   = 0xA0A0A0FF
local ERROR_TEXT = 0xE06C6CFF
local ARROW_TEXT = 0x7FB8AEFF
local POS_LABELS = { "End", "Start", "At Index" }

-- Left settings rail / right preview split, following the geometry in
-- Items/Smart Export Selected Items (GUI).lua. Inside a bare BeginGroup,
-- anything sized -1 (tables, separators, buttons) fills the *window*, not
-- the rail -- so every such item below is given an explicit width, and the
-- indented ones get the rail width minus their own indent.
local LEFT_COL_W     = 336
local LEFT_PAD       = 10   -- breathing room between the rail's edges and its content
local TOP_PAD        = 8    -- matching breathing room above the first row
local RAIL_GUTTER    = 12   -- gap between the stages' content and the scrollbar
local INDENT         = 16
local LEFT_CONTENT_W = LEFT_COL_W - LEFT_PAD * 2
-- Recomputed each frame in loop(): the stages scroll inside a child window,
-- whose scrollbar plus RAIL_GUTTER eat into the width its content can use.
-- INNER_W is that usable width -- the rules span it, and the field tables
-- get it minus their own indent.
local INNER_W        = LEFT_CONTENT_W
local SECTION_W      = LEFT_CONTENT_W - INDENT      -- tables inside a section body
local SUB_W          = LEFT_CONTENT_W - INDENT * 2  -- tables inside a sub-option

-- Height of the pinned footer (rule + Apply + status), measured at the end
-- of each frame and used to size the scroll area above it on the next one.
-- Seeded with a close guess so the first frame lands near-right; the
-- measurement corrects it before anyone can see the difference.
local left_footer_h  = 64
local LABEL_W        = 136
local NUM_W          = 90
local RAIL_BG        = 0x222222FF  -- matches the theme's Col_ChildBg, so the
                                   -- stages' scroll child blends into the rail
local RULE_COLOR     = 0x3A3F45FF

-- ============================================================
-- Settings (persisted to ExtState). DEFAULTS doubles as the type map the
-- loader uses to coerce the string-only ExtState values back.
-- ============================================================
local DEFAULTS = {
  replace_on    = true,  find        = "", replace   = "",
  clear_name    = false, regex       = false, match_case = false,

  trim_on       = false, trim_begin  = 0, trim_end   = 0,
  range_on      = false, range_from  = 0, range_to   = 0,
  count_from_end = false,

  add_on        = false, prefix      = "", insert     = "", insert_idx = 0, suffix = "",

  num_on        = false, num_pos     = 1, num_idx    = 0, num_start = 1,
  num_places    = 0,     num_incr    = 1, num_sep    = "", num_az    = false,
}

local S = {}
local dirty = false

local function loadSettings()
  for k, default in pairs(DEFAULTS) do
    local raw = reaper.GetExtState(EXT_KEY, k)
    if raw == "" then
      S[k] = default
    elseif type(default) == "boolean" then
      S[k] = raw == "true"
    elseif type(default) == "number" then
      S[k] = tonumber(raw) or default
    else
      S[k] = raw
    end
  end
end

local function saveSettings()
  for k in pairs(DEFAULTS) do
    local v = S[k]
    if type(v) == "boolean" then v = v and "true" or "false" end
    reaper.SetExtState(EXT_KEY, k, tostring(v), true)
  end
end

loadSettings()

-- ============================================================
-- Name building
-- ============================================================

-- Literal (non-pattern) replace. Scans with plain string.find rather than
-- escaping the needle into a Lua pattern, so every character in both the
-- search and replacement text -- %, $, ^, (), [], etc. -- is treated as
-- itself. Case-insensitive matching scans a lowercased copy so offsets
-- still index the original, preserving the untouched text's own case.
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

-- Returns new_str, err. In pattern mode an invalid pattern (or a replacement
-- referencing a capture that doesn't exist) raises a Lua error, so gsub is
-- wrapped -- the message is surfaced in the UI instead of spilling to the
-- console on every frame the preview is rebuilt.
local function doReplace(str, find, repl, case_sensitive, patterns)
  if patterns then
    local ok, result = pcall(string.gsub, str, find, repl)
    if not ok then
      return str, (tostring(result):gsub("^.-:%d+:%s*", ""))
    end
    return result, nil
  end
  return (replaceLiteral(str, find, repl, case_sensitive)), nil
end

local function trimEnds(str, from_begin, from_end)
  local last = #str - math.max(from_end, 0)
  local first = 1 + math.max(from_begin, 0)
  if last < first then return "" end
  return str:sub(first, last)
end

-- Keeps only characters `from`..`to` (1-based, inclusive). 0 means "unset":
-- from 0 starts at the first character, to 0 runs to the last. With
-- count_from_end the indices are measured from the end of the string, so
-- from 1 to 3 keeps the last three characters.
local function takeRange(str, from, to, count_from_end)
  local len = #str
  if len == 0 then return "" end
  local first = (from > 0) and from or 1
  local last  = (to   > 0) and to   or len

  if count_from_end then
    first, last = len - last + 1, len - first + 1
  end

  first = math.max(first, 1)
  last  = math.min(last, len)
  if last < first then return "" end
  return str:sub(first, last)
end

-- 1-based character index; 0 or 1 both mean "at the beginning". An index
-- past the end appends.
local function insertAt(str, text, idx)
  local at = math.max(idx, 1)
  at = math.min(at, #str + 1)
  return str:sub(1, at - 1) .. text .. str:sub(at)
end

-- Spreadsheet-style letter sequence: 1=A, 26=Z, 27=AA, 28=AB, ...
local function toLetters(n)
  if n < 1 then return "" end
  local out = ""
  while n > 0 do
    local rem = (n - 1) % 26
    out = string.char(65 + rem) .. out
    n = math.floor((n - 1) / 26)
  end
  return out
end

local function numberToken(ordinal)
  local n = S.num_start + (ordinal - 1) * S.num_incr
  if S.num_az then return toLetters(n) end
  if S.num_places > 0 then
    return ("%0" .. math.floor(S.num_places) .. "d"):format(n)
  end
  return tostring(n)
end

-- Runs the four stages in order. `ordinal` is the track's 1-based position
-- within the selection, used by the numbering stage.
local function buildName(name, ordinal)
  local err

  if S.replace_on then
    if S.clear_name then name = "" end
    if S.find ~= "" then
      name, err = doReplace(name, S.find, S.replace, S.match_case, S.regex)
      if err then return name, err end
    end
  end

  if S.trim_on then
    if S.range_on then
      name = takeRange(name, S.range_from, S.range_to, S.count_from_end)
    else
      name = trimEnds(name, S.trim_begin, S.trim_end)
    end
  end

  if S.add_on then
    if S.insert ~= "" then name = insertAt(name, S.insert, S.insert_idx) end
    name = S.prefix .. name .. S.suffix
  end

  if S.num_on then
    local token = numberToken(ordinal)
    local sep   = S.num_sep
    local pos   = POS_LABELS[S.num_pos]
    if pos == "Start" then
      name = token .. sep .. name
    elseif pos == "End" then
      name = name .. sep .. token
    else
      name = insertAt(name, sep .. token, S.num_idx)
    end
  end

  return name, nil
end

local function anyStageOn()
  return S.replace_on or S.trim_on or S.add_on or S.num_on
end

-- Rebuilt every frame so the preview follows track selection and any name
-- edits made in REAPER while the window is open.
local function buildPreview()
  local changes, err = {}, nil
  if not anyStageOn() then return changes, err end

  local n_sel = reaper.CountSelectedTracks(0)
  for i = 0, n_sel - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    local new_name, e = buildName(name, i + 1)
    if e then return {}, e end
    if new_name ~= name then
      changes[#changes + 1] = {
        track = track,
        num   = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")),
        old   = name,
        new   = new_name,
      }
    end
  end

  return changes, err
end

local function applyChanges(changes)
  if #changes == 0 then return end
  reaper.Undo_BeginBlock()
  for _, c in ipairs(changes) do
    reaper.GetSetMediaTrackInfo_String(c.track, "P_NAME", c.new, true)
  end
  reaper.Undo_EndBlock(
    ("Rename %d selected track%s"):format(#changes, #changes == 1 and "" or "s"), -1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end

-- ============================================================
-- Context
-- ============================================================
local ctx       = ImGui.CreateContext("RENAME SELECTED TRACKS")
local WIN_FLAGS = ImGui.WindowFlags_NoCollapse

-- ============================================================
-- UI helpers
-- ============================================================

-- Disabled items don't register hover without HoveredFlags_AllowWhenDisabled,
-- and several tooltips here exist precisely to explain why a field is greyed.
local function tooltipLast(text)
  if text and ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
    ImGui.SetTooltip(ctx, text)
  end
end

-- Checkbox + bold label. Returns the section's enabled state; callers wrap
-- the section body in BeginDisabled when it's off.
local function sectionHeader(label, key)
  local _, v = ImGui.Checkbox(ctx, "##on_" .. key, S[key])
  if v ~= S[key] then S[key] = v; dirty = true end
  ImGui.SameLine(ctx)
  theme.PushBoldFont(ctx)
  ImGui.Text(ctx, label)
  theme.PopBoldFont(ctx)
  return S[key]
end

-- outer_w pins the table to the rail instead of the window: without it a
-- WidthStretch column stretches across the whole window, shoving the
-- preview column off the right edge.
local function beginFields(id, outer_w)
  if not ImGui.BeginTable(ctx, id, 2, 0, outer_w or SECTION_W, 0) then return false end
  ImGui.TableSetupColumn(ctx, "##l", ImGui.TableColumnFlags_WidthFixed, LABEL_W)
  ImGui.TableSetupColumn(ctx, "##f", ImGui.TableColumnFlags_WidthStretch)
  return true
end

local function fieldLabel(text)
  ImGui.TableNextRow(ctx)
  ImGui.TableSetColumnIndex(ctx, 0)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
  ImGui.Text(ctx, text)
  ImGui.PopStyleColor(ctx)
  ImGui.TableSetColumnIndex(ctx, 1)
end

local function textField(label, key)
  fieldLabel(label)
  ImGui.SetNextItemWidth(ctx, -1)
  local _, v = ImGui.InputText(ctx, "##" .. key, S[key])
  if v ~= S[key] then S[key] = v; dirty = true end
end

local function intField(label, key, min, tip)
  fieldLabel(label)
  ImGui.SetNextItemWidth(ctx, NUM_W)
  local _, v = ImGui.InputInt(ctx, "##" .. key, S[key], 1, 5)
  tooltipLast(tip)
  if min then v = math.max(v, min) end
  if v ~= S[key] then S[key] = v; dirty = true end
end

local function checkField(label, key, tooltip)
  local _, v = ImGui.Checkbox(ctx, label .. "##" .. key, S[key])
  if v ~= S[key] then S[key] = v; dirty = true end
  tooltipLast(tooltip)
end

-- ImGui.Separator() spans the window's content width inside a bare
-- BeginGroup, which would draw a line straight across the preview column --
-- so the rail's rules are drawn by hand at the rail's own width.
local function railRule(width)
  ImGui.Spacing(ctx)
  local sx, sy = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx),
    sx, sy, sx + (width or INNER_W), sy + 1, RULE_COLOR)
  ImGui.Dummy(ctx, 0, 1)
  ImGui.Spacing(ctx)
end

-- ============================================================
-- Sections
-- ============================================================
local function drawReplace()
  local on = sectionHeader("REPLACE", "replace_on")
  if not on then ImGui.BeginDisabled(ctx, true) end
  ImGui.Indent(ctx, INDENT)

  if beginFields("##replace_fields") then
    textField("Find:", "find")
    textField("Replace:", "replace")
    ImGui.EndTable(ctx)
  end

  ImGui.Spacing(ctx)
  checkField("Clear Existing Name", "clear_name",
    "Blank the name first, then build it from the stages below")
  -- Lua patterns have no case-insensitive flag, so Match Case is pinned on
  -- and disabled in pattern mode rather than silently doing nothing.
  if S.regex then ImGui.BeginDisabled(ctx, true) end
  local _, mc = ImGui.Checkbox(ctx, "Match Case##match_case", S.regex or S.match_case)
  if not S.regex and mc ~= S.match_case then S.match_case = mc; dirty = true end
  tooltipLast(S.regex and "Lua patterns are always case-sensitive" or nil)
  if S.regex then ImGui.EndDisabled(ctx) end
  checkField("Regular Expressions", "regex",
    "Treat Find as a Lua pattern (e.g. ^%a+ or [0-9]+).\n" ..
    "The replacement can reference captures as %1, %2, ...\n" ..
    "REAPER's Lua has patterns rather than full regex.")

  ImGui.Unindent(ctx, INDENT)
  if not on then ImGui.EndDisabled(ctx) end
end

local function drawTrim()
  local on = sectionHeader("TRIM", "trim_on")
  if not on then ImGui.BeginDisabled(ctx, true) end
  ImGui.Indent(ctx, INDENT)

  -- Range replaces the From Beginning/From End counts rather than stacking
  -- with them -- the two readings of "trim 2 from the front AND keep 3..6"
  -- contradict each other, so only one is live at a time.
  local trim_tip = S.range_on and "Disabled while Range is on" or nil
  if S.range_on then ImGui.BeginDisabled(ctx, true) end
  if beginFields("##trim_fields") then
    intField("From Beginning:", "trim_begin", 0, trim_tip)
    intField("From End:", "trim_end", 0, trim_tip)
    ImGui.EndTable(ctx)
  end
  if S.range_on then ImGui.EndDisabled(ctx) end

  ImGui.Spacing(ctx)
  checkField("Range", "range_on",
    "Keep only characters From..To (1-based, inclusive).\n" ..
    "0 means unset: From 0 starts at the first character,\n" ..
    "To 0 runs to the last.")

  if not S.range_on then ImGui.BeginDisabled(ctx, true) end
  ImGui.Indent(ctx, INDENT)
  if beginFields("##range_fields", SUB_W) then
    intField("From:", "range_from", 0)
    intField("To:", "range_to", 0)
    ImGui.EndTable(ctx)
  end
  ImGui.Spacing(ctx)
  checkField("Count From End", "count_from_end",
    "Measure From/To from the end of the name instead of\n" ..
    "the beginning, so From 1 To 3 keeps the last three characters.")
  ImGui.Unindent(ctx, INDENT)
  if not S.range_on then ImGui.EndDisabled(ctx) end

  ImGui.Unindent(ctx, INDENT)
  if not on then ImGui.EndDisabled(ctx) end
end

local function drawAdd()
  local on = sectionHeader("ADD", "add_on")
  if not on then ImGui.BeginDisabled(ctx, true) end
  ImGui.Indent(ctx, INDENT)

  if beginFields("##add_fields") then
    textField("Prefix:", "prefix")
    textField("Insert:", "insert")
    intField("At Index:", "insert_idx", 0,
      "1-based character index; 0 or 1 inserts at the beginning")
    textField("Suffix:", "suffix")
    ImGui.EndTable(ctx)
  end

  ImGui.Unindent(ctx, INDENT)
  if not on then ImGui.EndDisabled(ctx) end
end

local function drawNumbering()
  local on = sectionHeader("NUMBERING", "num_on")
  if not on then ImGui.BeginDisabled(ctx, true) end
  ImGui.Indent(ctx, INDENT)

  if beginFields("##num_fields") then
    fieldLabel("Position:")
    ImGui.SetNextItemWidth(ctx, NUM_W + 40)
    if ImGui.BeginCombo(ctx, "##num_pos", POS_LABELS[S.num_pos]) then
      for i, label in ipairs(POS_LABELS) do
        if ImGui.Selectable(ctx, label, S.num_pos == i) then
          S.num_pos = i; dirty = true
        end
        if S.num_pos == i then ImGui.SetItemDefaultFocus(ctx) end
      end
      ImGui.EndCombo(ctx)
    end

    -- Index only means anything for the "At Index" position
    local at_index = POS_LABELS[S.num_pos] == "At Index"
    if not at_index then ImGui.BeginDisabled(ctx, true) end
    intField("Index:", "num_idx", 0,
      (not at_index) and 'Only used when Position is "At Index"' or nil)
    if not at_index then ImGui.EndDisabled(ctx) end

    intField("Starting Number:", "num_start")

    -- Zero-padding is meaningless for letters
    if S.num_az then ImGui.BeginDisabled(ctx, true) end
    intField("Number of Places:", "num_places", 0,
      S.num_az and "Zero-padding doesn't apply to letters" or nil)
    if S.num_az then ImGui.EndDisabled(ctx) end

    intField("Increment:", "num_incr")
    textField("Separator:", "num_sep")
    ImGui.EndTable(ctx)
  end

  ImGui.Spacing(ctx)
  checkField("Use A..Z", "num_az",
    "Letters instead of digits: 1=A, 26=Z, 27=AA.\n" ..
    "Starting Number and Increment still apply.")

  ImGui.Unindent(ctx, INDENT)
  if not on then ImGui.EndDisabled(ctx) end
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  dirty = false
  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSizeConstraints(ctx, LEFT_COL_W + 240, 0, 3000, 10000)
  ImGui.SetNextWindowSize(ctx, 880, 720, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "RENAME SELECTED TRACKS", true, WIN_FLAGS)

  if visible then
    local n_sel = reaper.CountSelectedTracks(0)

    -- Built once up front, before any widget can mutate S this frame, so the
    -- Apply button and the preview beside it always act on the same list --
    -- what you see listed is exactly what Apply writes.
    local changes, err = buildPreview()

    -- ---- Left column: settings rail ----
    -- avail_h is "from here to the bottom of the window at its current
    -- size", so the rail's tint stretches the full height rather than
    -- stopping at the last field.
    local _, avail_h = ImGui.GetContentRegionAvail(ctx)
    local lx0, ly0 = ImGui.GetCursorScreenPos(ctx)
    ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx),
      lx0, ly0, lx0 + LEFT_COL_W, ly0 + avail_h, RAIL_BG, 4)

    -- The stages scroll inside a child sized to whatever the footer leaves,
    -- so its tables lose the scrollbar's width.
    local sb_w = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ScrollbarSize)
    INNER_W   = LEFT_CONTENT_W - sb_w - RAIL_GUTTER
    SECTION_W = INNER_W - INDENT
    SUB_W     = INNER_W - INDENT * 2

    ImGui.BeginGroup(ctx)
    -- Indent shifts every subsequent item's left edge by LEFT_PAD; paired
    -- with sizing content to LEFT_CONTENT_W so nothing touches the rail's
    -- edges. Must be un-indented before EndGroup below.
    ImGui.Indent(ctx, LEFT_PAD)
    ImGui.Dummy(ctx, 0, TOP_PAD)

    -- ---- Scrolling stages ----
    -- A child window here is safe as long as EndChild is called
    -- unconditionally (see Renamer/Lib/QuickNamingGui.lua's note): skipping
    -- it when BeginChild returns false is what unbalances ReaImGui's window
    -- stack. The child's background is the theme's Col_ChildBg, the same
    -- color as the rail, so the scroll region is invisible.
    local stages_h = math.max(avail_h - TOP_PAD * 2 - left_footer_h, 120)
    local stages_visible = ImGui.BeginChild(ctx, "##stages", LEFT_CONTENT_W, stages_h)
    if stages_visible then
      drawReplace()
      railRule()
      drawTrim()
      railRule()
      drawAdd()
      railRule()
      drawNumbering()
    end
    ImGui.EndChild(ctx)

    -- ---- Pinned footer ----
    local _, footer_top_y = ImGui.GetCursorScreenPos(ctx)

    -- Full rail width: the footer is outside the scroll area, so no
    -- scrollbar to clear.
    railRule(LEFT_CONTENT_W)

    -- Apply: explicit width rather than -1, which would fill to the
    -- window's edge instead of the rail's.
    local can_apply = #changes > 0 and not err
    if not can_apply then ImGui.BeginDisabled(ctx, true) end
    local do_apply = theme.PrimaryButton(ctx, "Apply", LEFT_CONTENT_W, 0, nil, theme.Icons.PENCIL)
      or (can_apply and ImGui.IsWindowFocused(ctx) and (
            ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
            or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)))
    if not can_apply then ImGui.EndDisabled(ctx) end

    local status_text = n_sel .. (n_sel == 1 and " track selected" or " tracks selected")
    local status_w = ImGui.CalcTextSize(ctx, status_text)
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + (LEFT_CONTENT_W - status_w) / 2)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
    ImGui.Text(ctx, status_text)
    ImGui.PopStyleColor(ctx)

    local _, footer_bottom_y = ImGui.GetCursorScreenPos(ctx)
    left_footer_h = footer_bottom_y - footer_top_y

    ImGui.Dummy(ctx, 0, TOP_PAD)
    ImGui.Unindent(ctx, LEFT_PAD)
    ImGui.EndGroup(ctx)

    -- ---- Right column: live preview ----
    -- Gap is 20 + LEFT_PAD: the left group's measured bounding box ends
    -- LEFT_PAD short of the tint rect's right edge (its content is inset),
    -- so the offset needs that back to read as an even 20px gutter.
    ImGui.SameLine(ctx, 0, 20 + LEFT_PAD)

    ImGui.BeginGroup(ctx)
    ImGui.Dummy(ctx, 0, TOP_PAD)  -- aligns with the rail's first row

    theme.PushBoldFont(ctx)
    ImGui.Text(ctx, "PREVIEW")
    theme.PopBoldFont(ctx)

    if err then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, ERROR_TEXT)
      ImGui.Text(ctx, "Pattern error: " .. err)
    else
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
      ImGui.Text(ctx, ("%d of %d selected track%s will be renamed"):format(
        #changes, n_sel, n_sel == 1 and "" or "s"))
    end
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)

    -- Plain in-window rows rather than a scrolling child: nesting a
    -- BeginChild inside these groups is what triggered the ReaImGui
    -- window-stack assertion documented in Smart Export's preview.
    if #changes == 0 then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
      if n_sel == 0 then
        ImGui.Text(ctx, "Select one or more tracks.")
      elseif not anyStageOn() then
        ImGui.Text(ctx, "Enable a stage on the left.")
      elseif not err then
        ImGui.Text(ctx, "No changes with the current settings.")
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

    ImGui.EndGroup(ctx)

    -- Deferred until both columns are drawn, so the rename and its undo
    -- block never run with widgets still queued behind it.
    if do_apply then applyChanges(changes) end

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
