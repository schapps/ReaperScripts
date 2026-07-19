-- @noindex
-- QuickNamingGui: the "Quick Naming" alternate window - one big free-type
-- text box instead of per-field widgets, with live scheme-aware
-- autocomplete (inline ghost text previewing the top-ranked next value, plus
-- an always-visible list of that field's other candidates underneath) and a
-- live "Current Name / New Name" preview table. Advisory only: typed text is
-- never forced to match the scheme.
--
-- Mirrors SchemeVisualizer.lua's DrawWindow(ctx, data) -> open contract and
-- the SchemeEditor/SchemeEditorGui init(helpers) injection convention,
-- since dofile'd modules can't see the main script's locals/globals at the
-- time they're dofile'd.

local QuickNamingGui = {}

local Predictor   -- NamePredictor module
local Helpers     -- { PreviewRename, ApplyQuickName, LoadTargets, FindField, PadZeroes }
local acendan     -- shared style/tooltip/scale helper table (same one every other Lib module gets)

function QuickNamingGui.init(name_predictor, helpers, acendan_helpers)
  Predictor = name_predictor
  Helpers   = helpers
  acendan   = acendan_helpers
end

-- Rewrites an ACTIVE InputText's buffer content in place, via ReaImGui's
-- InputTextCallback_DeleteChars/InsertChars, instead of the earlier
-- approach of bumping the widget's id to force a reload. The id-bump
-- worked for getting the new text to stick, but combined with the
-- SetKeyboardFocusHere() needed to refocus a freshly-idd widget, it always
-- seemed to select-all the new text - two different attempts at
-- suppressing that selection via an InputTextCallback_ClearSelection()
-- callback (unconditional, then gated behind a Function_SetValue signal)
-- both failed to visibly fix it, suggesting Dear ImGui applies that
-- auto-select-all *after* "Always" callbacks run, not before, so clearing
-- it from inside one can't win. Editing the SAME widget instance's buffer
-- in place - while it never loses "active" status at all - never enters
-- that "freshly (re)focused" codepath in the first place, so there's
-- nothing for Dear ImGui to auto-select-all in response to.
--
-- The replacement text has to be embedded directly in the compiled EEL
-- source (Lua values can't be passed into an already-running callback -
-- Function_SetValue exists but didn't reliably work for a similar signal
-- here either), so this compiles a small one-off function per call rather
-- than reusing a single cached one like the rest of this codebase's
-- ImGui_Function usage does. Only runs on user-driven accept/clear actions
-- (not every frame), so the recompile cost is negligible. Also throws in an
-- InputTextCallback_ClearSelection() as a harmless best-effort extra, in
-- case a genuine focus-loss-then-regain (see needs_refocus in Accept()
-- below) still selects something despite the in-place edit.
local function EscapeEelString(str)
  return (str:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

local function MakeReplaceCallback(ctx, new_text)
  local code = string.format(
    "InputTextCallback_DeleteChars(0, strlen(#Buf)); InputTextCallback_InsertChars(0, \"%s\"); " ..
    "InputTextCallback_ClearSelection();",
    EscapeEelString(new_text))
  local fn = reaper.ImGui_CreateFunctionFromEEL(code)
  reaper.ImGui_Attach(ctx, fn)
  return fn
end

local GHOST_COLOR = 0x999999AA

-- Same scale the classic tab's big Rename/Export buttons use (see TabNaming
-- in the main script) - keeps Quick Naming's name box/options list visually
-- consistent with the rest of this tool rather than picking an arbitrary
-- new size.
local BIG_FONT_SCALE = 1.5

-- Builds the enumeration table Rename()/SanitizeName() expect, from the
-- scheme's "Enumeration" field (see LoadField's number branch in the main
-- script, which does this inline while also drawing that field's widget -
-- Quick Naming never draws it, so this just reads the field's last-set
-- value directly).
local function BuildEnumeration(data)
  local field = Helpers.FindField(data.fields, "Enumeration")
  if not field then
    return { start = 1, zeroes = 1, singles = false, wildcard = "$enum", sep = data.separator }
  end
  return {
    start    = field.value,
    zeroes   = field.zeroes or 1,
    singles  = field.singles or false,
    wildcard = "$enum",
    sep      = data.separator,
  }
end

-- The name actually sent to PreviewRename/Rename: the user's free-typed
-- text plus the scheme's enumeration token, transparently auto-appended -
-- the user never has to type or know about the token syntax; the
-- non-editable badge drawn next to the input communicates that numbering
-- is active.
local function BuildFullName(typed_text, enumeration)
  if typed_text == "" then return "" end
  return typed_text .. enumeration.sep .. enumeration.wildcard
end

-- Renders inline gray "ghost" completion text after the real InputText's
-- typed content (VSCode-style). No caret-position API exists anywhere in
-- ReaImGui's InputText binding, so this only ever completes the trailing
-- end of the buffer - consistent with every other input in this codebase,
-- which always round-trips the whole string, never a cursor index.
--
-- Deliberately NOT gated on IsItemActive: this is meant to work as a
-- glanceable "here's what the scheme expects next" guide (including before
-- the box has ever been clicked into, e.g. the very first field's hint on
-- an empty box), not just while actively mid-edit.
local function DrawGhostText(ctx, typed_text, remainder)
  if not remainder or remainder == "" then return end
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1 = select(1, reaper.ImGui_GetItemRectMax(ctx))
  -- FramePadding is pushed as {4, 3} * ui_scale (see acendan.ImGui_Styles.vars
  -- / .scalable in the main script) - x and y padding differ, and both scale
  -- with the user's UI scale setting, so both must be read here rather than
  -- assumed to be a single flat constant.
  local scale = acendan.ImGui_GetScale()
  local pad_x, pad_y = 4 * scale, 3 * scale
  local typed_w = reaper.ImGui_CalcTextSize(ctx, typed_text)
  local draw_x = x0 + pad_x + typed_w
  -- Suppress once there's no reliable room left to draw at - ReaImGui
  -- doesn't expose InputText's internal horizontal scroll offset, so once
  -- typed text is long enough to scroll, there's no way to know where its
  -- visible end actually is.
  if draw_x >= x1 - pad_x then return end
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddText(draw_list, draw_x, y0 + pad_y, GHOST_COLOR, remainder)
end

local MAX_VISIBLE_OPTIONS = 6

-- Always-visible list of the next field's candidate values, rendered inline
-- below the input (not a popup - the ghost text above already covers the
-- "type ahead" flow; this is the complementary "or just click one" flow,
-- and a persistent list also doubles as a glanceable preview of what the
-- next section of the name is expected to look like, per field). Narrows
-- automatically since `candidates` is already partial-filtered by the
-- caller (NamePredictor.Predict).
-- `selected_idx` (1-based, or nil) is a fully manual highlight - Quick
-- Naming's own window is drawn with WindowFlags_NoNavInputs (see
-- DrawWindow), so Dear ImGui's built-in keyboard-nav focus-shifting never
-- runs inside it at all: Up/Down/Tab are only ever seen via our own
-- IsKeyPressed polling, never consumed to hop focus between the input, this
-- list, and the Rename button. (An earlier version tried to hand off to
-- Dear ImGui's own nav system instead - SetKeyboardFocusHere into the first
-- row, then let its native Up/Down cycle the rest - but that hand-off
-- proved flaky in practice: nav focus would occasionally drop out of the
-- list back to whole-window-level after an accept, since Dear ImGui also
-- moves nav focus on layout changes we don't fully control here.)
local function DrawOptionsList(ctx, candidates, selected_idx, on_accept)
  local visible_rows = math.min(#candidates, MAX_VISIBLE_OPTIONS)
  local height = visible_rows * reaper.ImGui_GetTextLineHeightWithSpacing(ctx)
  if reaper.ImGui_BeginListBox(ctx, "##quick_naming_options", -1, height) then
    for i, c in ipairs(candidates) do
      local is_selected = i == selected_idx
      if reaper.ImGui_Selectable(ctx, c.label, is_selected) then on_accept(c) end
      if is_selected then reaper.ImGui_SetScrollHereY(ctx) end
    end
    reaper.ImGui_EndListBox(ctx)
  end
end

-- Applies `candidate` to the end of `text`, replacing the in-progress
-- partial token (so casing from Capitalize() wins over whatever case the
-- user actually typed) and appending the scheme separator only if another
-- field still follows - determined by re-running prediction one token
-- ahead rather than guessing from tree position.
local function AcceptCandidate(data, text, partial, candidate)
  local prefix = text:sub(1, #text - #partial)
  local new_text = prefix .. candidate.insert
  local followup = Predictor.Predict(data.fields, data.separator, new_text .. data.separator)
  if followup.next_field then new_text = new_text .. data.separator end
  return new_text
end

-- Renders the "Quick Naming" window for the currently loaded scheme
-- (`wgt.data`) and the currently selected target/mode (`wgt.target`/
-- `wgt.mode`, same fields the classic Naming tab uses). Returns `open`:
-- false once the user closes the window - the caller should clear its own
-- show-flag and stop calling DrawWindow until it's reopened.
function QuickNamingGui.DrawWindow(ctx, wgt)
  if not wgt.data or not wgt.data.fields then return true end
  -- targets_h: a reasonable guess for the very first frame, before the
  -- Targets section has ever been measured (see the preview-table sizing
  -- below) - immediately replaced with a real measurement afterward.
  wgt.quick = wgt.quick or { text = "", targets_h = 120 }

  local data = wgt.data
  local enumeration = BuildEnumeration(data)
  -- Captured before PreviewRename below mutates enumeration.start (via
  -- SanitizeName's in-place increment, once per previewed row) - the badge
  -- should always read the scheme's true configured starting number, not
  -- whatever this frame's preview pass advanced it to.
  local badge_start = enumeration.start
  local full_name = BuildFullName(wgt.quick.text, enumeration)
  local preview_rows, preview_err = Helpers.PreviewRename(wgt.target, wgt.mode, full_name, enumeration)

  acendan.ImGui_PushStyles()
  reaper.ImGui_SetNextWindowSize(ctx, 560, 480, reaper.ImGui_Cond_FirstUseEver())
  -- The window title doubles as Dear ImGui's identity for it - if this
  -- string changed frame-to-frame (it used to include the live item count),
  -- ImGui would see a *different* window on every selection change and
  -- flicker-close/reopen it. Keep it stable; the item count is shown in the
  -- body instead (near "Preview", below).
  local title = "Quick Text Naming - " .. (data.title or "")
  -- NoNavInputs: keeps Dear ImGui's own keyboard-nav focus-shifting out of
  -- this window entirely, so Up/Down/Tab are only ever seen via our own
  -- IsKeyPressed polling below - see the long comment on DrawOptionsList
  -- for why (an earlier attempt relying on Dear ImGui's native nav to
  -- cycle the options list was flaky). Mouse clicks on every widget still
  -- work normally; this only affects keyboard/gamepad-driven focus.
  local rv, open = reaper.ImGui_Begin(ctx, title, true, reaper.ImGui_WindowFlags_NoNavInputs())
  if rv then
    reaper.ImGui_SeparatorText(ctx, data.title or "Name")
    local prediction = Predictor.Predict(data.fields, data.separator, wgt.quick.text)

    -- Matches the classic tab's big Rename/Export buttons (same 1.5x scale
    -- of the current font). Stays pushed through the ghost-text draw below
    -- too, not just the InputText itself, since DrawGhostText measures via
    -- CalcTextSize against whatever font is currently active - popping
    -- early would size the ghost text using the wrong (smaller) font.
    reaper.ImGui_PushFont(ctx, acendan.ImGui_Styles.font, reaper.ImGui_GetFontSize(ctx) * BIG_FONT_SCALE)

    -- Reserve room for the "x" clear button and the enum badge, both drawn
    -- after the input at normal (non-BIG_FONT_SCALE) size.
    reaper.ImGui_SetNextItemWidth(ctx, reaper.ImGui_GetContentRegionAvail(ctx) - 120)
    -- Auto-focus the name box the moment the window (re)appears, or after a
    -- mouse click (on the options list or the "x" button) stole focus away
    -- from it (see needs_refocus in Accept()/ClearText() below) - both need
    -- the *upcoming* widget to receive focus, which is what
    -- SetKeyboardFocusHere's default (no offset) targets. Tab-accept does
    -- NOT need this: this whole window is NoNavInputs (see the Begin() call
    -- above), so Tab never nav-shifts focus away from the input in the
    -- first place - it's still here the whole time, no refocus needed.
    if reaper.ImGui_IsWindowAppearing(ctx) or wgt.quick.want_focus then
      reaper.ImGui_SetKeyboardFocusHere(ctx)
      wgt.quick.want_focus = false
    end

    -- Tab is read as a plain global key-state check, captured independently
    -- of whatever InputText itself does with the keypress. By default,
    -- pressing Tab while an InputText is focused shifts keyboard nav focus
    -- to the next widget (and, if AllowTabInput were set instead, inserts a
    -- literal tab character - tried that first, but it diverges from the
    -- widget's own internal edit-buffer in a way that isn't cleanly
    -- discardable) - moot here anyway since NoNavInputs already stops Tab
    -- from nav-shifting focus in this window, but the flag doesn't stop
    -- InputText from still trying to insert a tab character absent
    -- AllowTabInput, so this stays a plain key-state check rather than
    -- relying on IsItemActive timing.
    local tab_pressed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Tab()) and
        not reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
    -- Accept fires whether nav focus is still on the name box or has moved
    -- into the options list below (see DrawOptionsList) - both read last
    -- frame's settled state, one frame of lag that's imperceptible in
    -- practice.
    local accept = tab_pressed and (wgt.quick.input_was_active or wgt.quick.list_nav_idx ~= nil)

    -- wgt.quick.pending_replace (set by Accept()/ClearText() below) is
    -- consumed here, one frame later, via MakeReplaceCallback - see its
    -- comment for why this rewrites the buffer in place rather than
    -- swapping wgt.quick.text directly. "" is a valid pending value (a
    -- clear), so the check is for non-nil, not truthiness of the text.
    local input_flags, input_callback = reaper.ImGui_InputTextFlags_None(), nil
    if wgt.quick.pending_replace ~= nil then
      input_flags = reaper.ImGui_InputTextFlags_CallbackAlways()
      input_callback = MakeReplaceCallback(ctx, wgt.quick.pending_replace)
    end
    wgt.quick.pending_replace = nil

    local changed, new_text = reaper.ImGui_InputText(ctx, "##quick_name", wgt.quick.text, input_flags, input_callback)
    if changed then wgt.quick.text = new_text end
    wgt.quick.input_was_active = reaper.ImGui_IsItemActive(ctx)

    -- needs_refocus: false for Tab (NoNavInputs means it never lost focus),
    -- true for a mouse click (on an options-list row or the "x" button
    -- below) that genuinely moved focus elsewhere first.
    local function Accept(candidate, needs_refocus)
      wgt.quick.pending_replace = AcceptCandidate(data, wgt.quick.text, prediction.partial, candidate)
      if needs_refocus then wgt.quick.want_focus = true end
      wgt.quick.list_nav_idx = nil
    end

    local function ClearText()
      wgt.quick.pending_replace = ""
      wgt.quick.want_focus = true
      wgt.quick.list_nav_idx = nil
    end

    -- wgt.quick.list_nav_idx (manually driven by the Up/Down handling
    -- below) is whichever row is currently highlighted; it drives both the
    -- ghost text and what Tab accepts, defaulting to the top-ranked
    -- candidate until the user has actually arrowed onto a row. A stale
    -- index (candidate set changed since) is dropped so ghost text/Tab
    -- don't silently point at the wrong item.
    local candidates = prediction.candidates
    if changed and wgt.quick.list_nav_idx then wgt.quick.list_nav_idx = nil end
    if wgt.quick.list_nav_idx and wgt.quick.list_nav_idx > #candidates then
      wgt.quick.list_nav_idx = nil
    end
    -- Manual increment/decrement, clamped (not wrapped) to the candidate
    -- count - see DrawOptionsList for why this doesn't rely on Dear ImGui's
    -- own nav system. Gated on the name box (or the list itself) having
    -- been the active element, same last-frame-state reasoning as `accept`
    -- above, so arrowing around unrelated widgets elsewhere never bleeds
    -- into this.
    if (wgt.quick.input_was_active or wgt.quick.list_nav_idx ~= nil) and #candidates > 0 then
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow()) then
        wgt.quick.list_nav_idx = math.min((wgt.quick.list_nav_idx or 0) + 1, #candidates)
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow()) then
        wgt.quick.list_nav_idx = math.max((wgt.quick.list_nav_idx or 2) - 1, 1)
      end
    end

    local top = (wgt.quick.list_nav_idx and candidates[wgt.quick.list_nav_idx]) or candidates[1]
    if top then
      -- Sliced from match_source (whichever of the full value / short code
      -- `partial` actually matched), not from `insert` - for a field with a
      -- short code, insert is that code (see RankCandidates), which can be
      -- a completely different length than what the user is literally
      -- typing toward, so slicing insert here could go out of range or
      -- show a nonsense fragment.
      local remainder = top.match_source:sub(#prediction.partial + 1)
      DrawGhostText(ctx, wgt.quick.text, remainder)
      -- No `remainder ~= ""` requirement: even a fully-typed exact match
      -- (nothing left to visually complete) should still accept on Tab, so
      -- a short-code field swaps in its code rather than silently doing
      -- nothing just because the user finished typing the long form.
      if accept then Accept(top, false) end
    elseif prediction.next_field and prediction.partial == "" then
      -- Free-text field (e.g. a "Body" string field): nothing to rank, but
      -- still worth a non-acceptable structural cue so the scheme stays
      -- discoverable even where there's no real completion to offer.
      DrawGhostText(ctx, wgt.quick.text, "(" .. prediction.next_field.field .. ")")
    end
    reaper.ImGui_PopFont(ctx)

    -- Mirrors the exact "x##<id> SmallButton + NoTabStop + clear tooltip"
    -- convention SchemeEditorGui.ComboBox/AutoFillComboBox already use for
    -- their own clear buttons.
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushItemFlag(ctx, reaper.ImGui_ItemFlags_NoTabStop(), true)
    if reaper.ImGui_SmallButton(ctx, "x##quick_name_clear") then ClearText() end
    reaper.ImGui_PopItemFlag(ctx)
    acendan.ImGui_Tooltip("Clear the name box.")

    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextDisabled(ctx, "#" .. Helpers.PadZeroes(badge_start, enumeration.zeroes))
    acendan.ImGui_Tooltip("Numbering is added automatically based on this scheme's Enumeration field.")

    if #candidates >= 1 then
      reaper.ImGui_PushFont(ctx, acendan.ImGui_Styles.font, reaper.ImGui_GetFontSize(ctx) * BIG_FONT_SCALE)
      -- Clicking a row is a genuine mouse-driven focus loss (needs_refocus =
      -- true), unlike Tab above.
      DrawOptionsList(ctx, candidates, wgt.quick.list_nav_idx, function(c) Accept(c, true) end)
      reaper.ImGui_PopFont(ctx)
    else
      wgt.quick.list_nav_idx = nil
    end

    local invalid = not wgt.target and "Please set a renaming target!" or
        (wgt.target and not wgt.mode) and ("Please set a renaming mode for target: " .. wgt.target) or
        (wgt.quick.text == "" and "Type a name above!") or nil

    reaper.ImGui_PushFont(ctx, acendan.ImGui_Styles.font, reaper.ImGui_GetFontSize(ctx) * BIG_FONT_SCALE)
    if invalid then reaper.ImGui_BeginDisabled(ctx) end
    local rename_clicked = reaper.ImGui_Button(ctx, "Rename")
    local _, button_h = reaper.ImGui_GetItemRectSize(ctx)
    if invalid then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_PopFont(ctx)
    acendan.ImGui_Tooltip("Pro Tip: You can press the 'Enter' key to trigger renaming from the name field above.")

    -- Scoped to this window's own focus, same reasoning as the matching fix
    -- in the classic tab's TabNaming()/TabMetadata(): a bare IsKeyReleased
    -- check is true regardless of which floating window currently has
    -- focus, which would fire this alongside (or instead of) whichever
    -- window the user actually meant to submit.
    local enter_submit = not invalid and reaper.ImGui_IsWindowFocused(ctx) and
        reaper.ImGui_IsKeyReleased(ctx, reaper.ImGui_Key_Enter())

    if rename_clicked or enter_submit then
      wgt.quick.error = nil
      -- A fresh enumeration table, NOT the `enumeration` local from the top
      -- of this frame: that one was already consumed by PreviewRename above
      -- (which runs unconditionally every frame to feed the live table),
      -- and SanitizeName increments `.start` in place as it goes - reusing
      -- it here would mean the real rename picks up wherever the preview
      -- pass left the counter (e.g. starting at 4 for a 3-item preview that
      -- ran right before this click), instead of starting fresh from the
      -- scheme's actual Enumeration value.
      local apply_enumeration = BuildEnumeration(data)
      local apply_name = BuildFullName(wgt.quick.text, apply_enumeration)
      Helpers.ApplyQuickName(wgt.target, wgt.mode, apply_name, apply_enumeration)
    end
    -- SameLine puts this text at the button's top, not centered - the
    -- button is drawn at BIG_FONT_SCALE (taller) while this status message
    -- stays normal-sized, so nudge it down by half the height difference.
    local function DrawStatusMessage(color, text)
      reaper.ImGui_SameLine(ctx)
      local text_h = reaper.ImGui_GetTextLineHeight(ctx)
      reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + (button_h - text_h) / 2)
      reaper.ImGui_TextColored(ctx, color, text)
    end

    if invalid then
      DrawStatusMessage(0xFFFF00BB, invalid)
    elseif wgt.quick.error then
      DrawStatusMessage(0xFF0000FF, wgt.quick.error)
    elseif preview_err then
      DrawStatusMessage(0xFF8080FF, preview_err)
    end

    reaper.ImGui_SeparatorText(ctx, "Preview")
    reaper.ImGui_TextDisabled(ctx, "Rename " .. #preview_rows .. " " .. ((wgt.target or "items"):lower()))
    local table_flags = reaper.ImGui_TableFlags_Borders() | reaper.ImGui_TableFlags_RowBg() |
        reaper.ImGui_TableFlags_ScrollY()
    -- Reserve room below the table for the Targets section using its
    -- *actual* rendered height from last frame (measured below, via
    -- BeginGroup/EndGroup + GetItemRectSize), not a hand-estimated formula -
    -- an earlier version guessed "separator + 3 widget rows", but
    -- SeparatorText's real height apparently doesn't match GetTextLine
    -- HeightWithSpacing exactly, so the guess under-reserved by a small,
    -- constant amount - enough to make the window's own scrollbar appear
    -- permanently, regardless of how tall the window was resized, since
    -- the shortfall was a fixed pixel error rather than something that
    -- scales away with more space. Measuring instead of guessing self-
    -- corrects within a frame no matter what LoadTargets() ends up drawing.
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    if reaper.ImGui_BeginTable(ctx, "quick_naming_preview", 2, table_flags, avail_w, avail_h - wgt.quick.targets_h) then
      reaper.ImGui_TableSetupColumn(ctx, "Current Name")
      reaper.ImGui_TableSetupColumn(ctx, "New Name")
      reaper.ImGui_TableHeadersRow(ctx)
      for i, row in ipairs(preview_rows) do
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        reaper.ImGui_Text(ctx, row.current)
        reaper.ImGui_TableSetColumnIndex(ctx, 1)
        reaper.ImGui_Text(ctx, row.new)
      end
      reaper.ImGui_EndTable(ctx)
    end

    reaper.ImGui_BeginGroup(ctx)
    reaper.ImGui_SeparatorText(ctx, "Targets")
    Helpers.LoadTargets()
    reaper.ImGui_EndGroup(ctx)
    local _, targets_h = reaper.ImGui_GetItemRectSize(ctx)
    wgt.quick.targets_h = targets_h

    reaper.ImGui_End(ctx)
  end
  acendan.ImGui_PopStyles()

  return open
end

return QuickNamingGui
