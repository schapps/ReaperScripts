-- @description Show Sequence Delay Times for Selected Items
-- @author Stephen Schappler
-- @version 2.0
-- @about
--   Show sequence delay times needed in seconds and ticks (for Scream) for selected items.
--   Opens a ReaImGUI window with one row per selected item (sorted by position),
--   showing the delay from the previous item and the offset from the first item,
--   in seconds and ticks. Click any value to copy it. Updates live as the selection changes.
--   Requires: Schapps Script Resources (install from this repository first).
-- @link https://www.stephenschappler.com
-- @changelog
--   11/19/26 - v2.0 Now a ReaImGUI window using the Schapps theme instead of a plain message box. Delays are shown in a table (one row per item, with delay from the previous item and offset from the first, in seconds and ticks, with seconds and ticks in different colors; click any value to copy it), update live as the selection changes, and can be copied to the clipboard.
--   7/30/24 Creating the script

-- ============================================================
-- ReaImGUI dependency check + bootstrap
-- ============================================================
local imgui_check = ({reaper.get_action_context()})[2]:match("^(.*[/\\])") .. "../Common/ReaImGuiCheck.lua"
if not reaper.file_exists(imgui_check) then
  reaper.MB("This script requires the latest \"Schapps ReaImGUI Theme\" package.\n\nInstall or update it via Extensions > ReaPack > Browse packages.", "Missing Dependency", 0)
  return
end
local ImGui = dofile(imgui_check)("0.10")
if not ImGui then return end

-- ============================================================
-- Theme module
-- ============================================================
local _, script_path, section_id, cmd_id = reaper.get_action_context()
local script_dir = script_path:match("^(.*[/\\])")
local theme_path = script_dir .. "Common/ReaImGuiTheme.lua"
if not reaper.file_exists(theme_path) then
  theme_path = script_dir .. "../Common/ReaImGuiTheme.lua"
end
local theme = dofile(theme_path)

-- ============================================================
-- Context + constants
-- ============================================================
local script_title = "Sequence Delay Times"
local ctx = ImGui.CreateContext(script_title)

local TICKS_PER_SECOND = 240
local COLOR_DIM = 0xA0A0A0FF

-- ============================================================
-- Data
-- ============================================================

-- Selected items sorted by position, each with its delay from the previous
-- item and offset from the first (seconds).
local function collectRows()
  local rows = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    local name = take and reaper.GetTakeName(take) or ""
    if name == "" then name = "(unnamed item)" end
    rows[#rows + 1] = {name = name, pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")}
  end
  table.sort(rows, function(a, b) return a.pos < b.pos end)

  local first = rows[1] and rows[1].pos or 0
  for i, row in ipairs(rows) do
    row.delay = i > 1 and (row.pos - rows[i - 1].pos) or nil
    row.offset = row.pos - first
  end
  return rows
end

local function fmtSec(s) return s and ("%.3f"):format(s) or "--" end
local function fmtTicks(s) return s and ("%.0f"):format(s * TICKS_PER_SECOND) or "--" end

-- Tab-separated text of the table, for pasting into a spreadsheet/doc.
local function rowsToText(rows)
  local lines = {"#\tItem\tDelay (s)\tDelay (ticks)\tFrom First (s)\tFrom First (ticks)"}
  for i, row in ipairs(rows) do
    lines[#lines + 1] = table.concat({
      i, row.name,
      row.delay and ("%.3f"):format(row.delay) or "",
      row.delay and fmtTicks(row.delay) or "",
      ("%.3f"):format(row.offset), fmtTicks(row.offset),
    }, "\t")
  end
  return table.concat(lines, "\n")
end

-- ============================================================
-- Helpers
-- ============================================================

-- Same hue, lower alpha -- for the secondary "From First" columns.
local function dimmed(color) return (color & 0xFFFFFF00) | 0xC0 end

local COPIED_SECS = 1.2
local copied = {text = nil, until_time = 0} -- last click-copied value
local hover_hint = false                    -- a copyable cell is hovered this frame

-- Right-aligned value in the current table cell (numbers line up that way).
-- With copy_text, the whole cell is a click target: hovering highlights it,
-- clicking copies copy_text to the clipboard. Tooltips are drawn after the
-- table (see drawCopyTooltip) so they use the body font, not the mono one.
local function valueCell(id, text, color, copy_text)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local avail_w = ImGui.GetContentRegionAvail(ctx)
  local text_w = ImGui.CalcTextSize(ctx, text)

  if copy_text then
    if ImGui.InvisibleButton(ctx, id, math.max(1, avail_w), ImGui.GetTextLineHeight(ctx)) then
      ImGui.SetClipboardText(ctx, copy_text)
      copied.text, copied.until_time = copy_text, reaper.time_precise() + COPIED_SECS
    end
    if ImGui.IsItemHovered(ctx) then
      hover_hint = true
      ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand)
      ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_CellBg, 0xFFFFFF14)
    end
  end

  ImGui.SetCursorScreenPos(ctx, x + math.max(0, avail_w - text_w), y)
  ImGui.TextColored(ctx, color, text)
end

local function drawCopyTooltip()
  if copied.text and reaper.time_precise() < copied.until_time then
    ImGui.SetTooltip(ctx, ("Copied %s"):format(copied.text))
  elseif hover_hint then
    ImGui.SetTooltip(ctx, "Click to copy")
  end
  hover_hint = false
end

-- Light up the toolbar button while the window is open.
local function setToggleState(state)
  reaper.SetToggleCommandState(section_id, cmd_id, state)
  reaper.RefreshToolbar2(section_id, cmd_id)
end

local COLUMNS = {
  {"#",            ImGui.TableColumnFlags_WidthFixed},
  {"Item",         ImGui.TableColumnFlags_WidthStretch},
  {"Delay (s)",          ImGui.TableColumnFlags_WidthFixed},
  {"Delay (ticks)",      ImGui.TableColumnFlags_WidthFixed},
  {"From First (s)",     ImGui.TableColumnFlags_WidthFixed},
  {"From First (ticks)", ImGui.TableColumnFlags_WidthFixed},
}

local function drawTable(rows)
  local flags = theme.TableFlags
             | ImGui.TableFlags_ScrollY
             | ImGui.TableFlags_SizingFixedFit
  local footer_h = theme.PrimaryButtonHeight(ctx) + ImGui.GetTextLineHeightWithSpacing(ctx)
                 + ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing) * 3
  if not ImGui.BeginTable(ctx, "delays", #COLUMNS, flags, 0, -footer_h) then return end

  ImGui.TableSetupScrollFreeze(ctx, 0, 1)
  for _, col in ipairs(COLUMNS) do
    ImGui.TableSetupColumn(ctx, col[1], col[2])
  end
  theme.TableHeadersRow(ctx)

  for i, row in ipairs(rows) do
    ImGui.TableNextRow(ctx)

    ImGui.TableNextColumn(ctx)
    ImGui.TextColored(ctx, COLOR_DIM, tostring(i))

    ImGui.TableNextColumn(ctx)
    ImGui.Text(ctx, row.name)
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, row.name) end

    -- Seconds in the Primary accent, ticks in the Secondary accent, so the
    -- two units are easy to tell apart at a glance; "From First" uses
    -- dimmer versions of the same two colors.
    local sec_color, tick_color = theme.GetAccentColor(), theme.GetSecondaryAccentColor()
    local has_delay = row.delay ~= nil
    local sec, ticks = fmtSec(row.delay), fmtTicks(row.delay)
    local off_sec, off_ticks = fmtSec(row.offset), fmtTicks(row.offset)

    theme.PushMonoFont(ctx)
    ImGui.PushID(ctx, i)
    ImGui.TableNextColumn(ctx)
    valueCell("##delay_s", sec, has_delay and sec_color or COLOR_DIM, has_delay and sec)
    ImGui.TableNextColumn(ctx)
    valueCell("##delay_t", ticks, has_delay and tick_color or COLOR_DIM, has_delay and ticks)
    ImGui.TableNextColumn(ctx)
    valueCell("##first_s", off_sec, dimmed(sec_color), off_sec)
    ImGui.TableNextColumn(ctx)
    valueCell("##first_t", off_ticks, dimmed(tick_color), off_ticks)
    ImGui.PopID(ctx)
    theme.PopMonoFont(ctx)
  end

  ImGui.EndTable(ctx)
  drawCopyTooltip()
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local copied_until = 0

local function loop()
  local rows = collectRows()

  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSize(ctx, 720, 360, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, script_title, true, ImGui.WindowFlags_NoCollapse)

  if visible then
    if #rows < 2 then
      ImGui.TextColored(ctx, COLOR_DIM, "Select at least two items to see the delays between them.")
    else
      drawTable(rows)

      local total = rows[#rows].offset
      ImGui.TextColored(ctx, COLOR_DIM, ("%d items  |  total span %s s (%s ticks)  |  %d ticks = 1 s")
        :format(#rows, fmtSec(total), fmtTicks(total), TICKS_PER_SECOND))

      local now = reaper.time_precise()
      local label = now < copied_until and "Copied!" or "Copy to Clipboard"
      if theme.PrimaryButton(ctx, label, -1, 0, nil, theme.Icons.COPY) then
        ImGui.SetClipboardText(ctx, rowsToText(rows))
        copied_until = now + 1.5
      end
    end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)

  if open then
    reaper.defer(loop)
  end
end

-- ============================================================
-- Entry point
-- ============================================================
setToggleState(1)
reaper.atexit(function() setToggleState(0) end)
reaper.defer(loop)
