-- @noindex
-- QuickNamingGui: the "Quick Naming" tab content - one big free-type
-- text box instead of per-field widgets, with live scheme-aware
-- autocomplete (inline ghost text previewing the top-ranked next value, plus
-- an always-visible list of that field's other candidates underneath) and a
-- live "Current Name / New Name" preview table. Advisory only: typed text is
-- never forced to match the scheme.
--
-- Rendered inline as one of the main window's tab-bar panes (see
-- NamingModeTabItem in the main script) - not its own top-level window -
-- via DrawTabContent(ctx, wgt), called with the same wgt table the classic
-- Scheme Naming tab uses. Still follows the SchemeEditor/SchemeEditorGui
-- init(helpers) injection convention, since dofile'd modules can't see the
-- main script's locals/globals at the time they're dofile'd.

local QuickNamingGui = {}

local Predictor   -- NamePredictor module
local Helpers     -- { PreviewRename, ApplyQuickName, LoadTargets, FindField, PadZeroes, GetSelectedItemName, HasExportScript, RunExportScript }
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
--
-- Only ever attached together with InputTextFlags_CallbackAlways alone (see
-- DrawTabContent below) - never combined with CallbackCharFilter below on
-- the same InputText call - so this function never needs to branch on
-- EventFlag; whenever it runs, it's always this one event type.
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

-- Lua pattern magic characters - see BuildCharFilterBody below.
local MAGIC_PATTERN_CHARS = "^$()%.[]*+-?"

-- Builds the EEL body for a CharFilter-only callback (attached only via
-- InputTextFlags_CallbackCharFilter, never combined with CallbackAlways
-- above - see DrawTabContent below - so, symmetrically with
-- MakeReplaceCallback, this never needs an EventFlag check either):
-- live-substitutes, as the user types, each `find` entry that reduces to a
-- single literal (non-pattern-magic) character - e.g. a space - with `replace`, via the
-- callback's EventChar variable (a plain character code, writable only
-- during this event - "Modify EventChar to replace, or EventChar = 0 to
-- discard"). Only a single-character find entry paired with a 0-or-1-
-- character replace reduces to a single EventChar swap; anything longer (a
-- multi-char pattern, or a multi-char replacement) cannot be expressed as a
-- single incoming character becoming a single outgoing one, so those are
-- left to only show up in the Preview table below, exactly as before this
-- function existed. Returns nil if nothing here qualifies.
local function BuildCharFilterBody(data)
  if not data.find or not data.replace or #data.replace > 1 then return nil end
  local replace_code = #data.replace == 1 and data.replace:byte() or 0
  local lines = {}
  for _, pattern in ipairs(data.find) do
    if #pattern == 1 and not MAGIC_PATTERN_CHARS:find(pattern, 1, true) then
      lines[#lines + 1] = string.format("(EventChar == %d) ? (EventChar = %d);", pattern:byte(), replace_code)
    end
  end
  if #lines == 0 then return nil end
  return table.concat(lines, " ")
end

-- Compiled once per scheme and cached (see wgt.quick.char_filter_fn in
-- DrawTabContent below), not per-call like MakeReplaceCallback - the
-- character mapping only depends on `body`, which is static for as long as
-- the same `data` table is in use.
local function MakeCharFilterCallback(ctx, body)
  local fn = reaper.ImGui_CreateFunctionFromEEL(body)
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

-- Escapes a string for safe use inside a Lua pattern - same convention as
-- SchemeEditor.lua's own EscapePattern, duplicated here rather than shared
-- since this module has no other dependency on that one.
local function EscapePattern(s)
  return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
end

-- Strips a trailing "<separator><digits>" token (e.g. "_01", "_12") from a
-- captured item name - used by "Capture Name" below. Without this, the
-- captured text would carry over whatever enumeration the item already
-- had, and BuildFullName would then append a SECOND one on top of it
-- (e.g. "Amb_Bed_01" captured, then renamed again, becomes
-- "Amb_Bed_01_02" instead of "Amb_Bed_02"). Leaves the name untouched if
-- it doesn't end in that shape (no separator, or no trailing digits).
local function StripTrailingEnumeration(name, separator)
  if not separator or separator == "" then return name end
  return (name:gsub(EscapePattern(separator) .. "%d+$", ""))
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

-- Floor (unscaled px, scaled at the call site) for the Preview table's
-- height - the table otherwise fills whatever room is left after reserving
-- space for the Targets footer (see the table-sizing code below), which
-- could go arbitrarily small/negative on a short window; this keeps it at
-- a sane minimum instead, letting the child overflow/scroll rather than the
-- table itself collapsing.
local QUICK_PREVIEW_TABLE_HEIGHT = 110

-- Always-visible list of the next field's candidate values, rendered inline
-- below the input (not a popup - the ghost text above already covers the
-- "type ahead" flow; this is the complementary "or just click one" flow,
-- and a persistent list also doubles as a glanceable preview of what the
-- next section of the name is expected to look like, per field). Narrows
-- automatically since `candidates` is already partial-filtered by the
-- caller (NamePredictor.Predict).
-- `selected_idx` (1-based, or nil) is a fully manual highlight - Quick
-- Naming's own child region is drawn with WindowFlags_NoNavInputs (see
-- DrawTabContent), so Dear ImGui's built-in keyboard-nav focus-shifting
-- never runs inside it at all: Up/Down/Tab are only ever seen via our own
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

-- Renders Quick Naming's content for the currently loaded scheme
-- (`wgt.data`) and the currently selected target/mode (`wgt.target`/
-- `wgt.mode`, same fields the classic Scheme Naming tab uses). Called every
-- frame the "Quick Naming" tab is active; the caller (NamingModeTabItem in
-- the main script) already owns the surrounding BeginTabItem/EndTabItem
-- pair, so this only needs to draw content, not manage its own window
-- lifetime - no return value.
function QuickNamingGui.DrawTabContent(ctx, wgt)
  if not wgt.data or not wgt.data.fields then return end
  wgt.quick = wgt.quick or { text = "" }

  local data = wgt.data
  local enumeration = BuildEnumeration(data)
  -- Captured before PreviewRename below mutates enumeration.start (via
  -- SanitizeName's in-place increment, once per previewed row) - the badge
  -- should always read the scheme's true configured starting number, not
  -- whatever this frame's preview pass advanced it to.
  local badge_start = enumeration.start
  local full_name = BuildFullName(wgt.quick.text, enumeration)
  local preview_rows, preview_err = Helpers.PreviewRename(wgt.target, wgt.mode, full_name, enumeration)

  -- Wraps this tab's content in its own child region purely to scope
  -- WindowFlags_NoNavInputs (unchanged rationale below) to just here,
  -- without affecting the rest of the shared main window/tab bar.
  -- Plain size_w=0/size_h=0 ("use remaining parent window size" on both
  -- axes, per BeginChild's own doc) rather than an AutoResize child flag -
  -- the main window is always plainly resizable (WINDOW_FLAGS has no
  -- AlwaysAutoResize, see the main script) and its size is whatever the
  -- user last manually resized it to (wgt.window_w/window_h, shared
  -- uniformly across both naming-mode tabs), so there's always real
  -- "remaining space" here for 0,0 to fill. An earlier version tried
  -- ChildFlags_AutoResizeX|AutoResizeY here, which was wrong for a
  -- different reason: several widgets below (the name InputText, the
  -- Preview table) themselves ask for "however much available width there
  -- currently is" via GetContentRegionAvail - inside an AutoResizeX child,
  -- that created a self-shrinking feedback loop
  -- (available width -> small content -> child shrinks to fit -> even less
  -- available width next frame), squeezing everything into a narrow column
  -- instead of filling the window. Plain 0,0 sizing also means this child
  -- (and everything inside it) properly tracks the outer window if the
  -- user manually resizes it, rather than staying pinned to its first
  -- auto-computed size.
  --
  -- NoNavInputs: "no keyboard/gamepad navigation within the window" (per
  -- its doc entry) - keeps Dear ImGui's own nav-highlight from wandering
  -- between the input/list/button in response to arrow keys, which is what
  -- previously made Down jump from the input to the list-as-a-whole and
  -- then straight past it to the Rename button. (An earlier revision of
  -- this comment claimed this flag also disables SetKeyboardFocusHere -
  -- that was a misread; the *item*-level ItemFlags_NoNav is the one whose
  -- doc text mentions disabling SetKeyboardFocusHere, and this flag's own
  -- text doesn't say that at all. Switching away from it broke nothing
  -- about focus restoration - it just brought back the wandering
  -- nav-highlight outline, so it's back.) Mouse clicks on every widget
  -- still work normally; this only affects keyboard/gamepad-driven focus.
  --
  -- Per BeginChild's own doc ("Begin and BeginChild are the only odd ones
  -- out"), EndChild must always be called regardless of this return value -
  -- only the body below is skipped when not visible.
  local visible = reaper.ImGui_BeginChild(ctx, "##quick_naming", 0, 0,
      reaper.ImGui_ChildFlags_None(), reaper.ImGui_WindowFlags_NoNavInputs())
  if visible then
    reaper.ImGui_SeparatorText(ctx, data.title or "Name")
    local prediction = Predictor.Predict(data.fields, data.separator, wgt.quick.text)

    -- Matches the classic tab's big Rename/Export buttons (same 1.5x scale
    -- of the current font). Stays pushed through the ghost-text draw below
    -- too, not just the InputText itself, since DrawGhostText measures via
    -- CalcTextSize against whatever font is currently active - popping
    -- early would size the ghost text using the wrong (smaller) font.
    reaper.ImGui_PushFont(ctx, acendan.ImGui_Styles.font, reaper.ImGui_GetFontSize(ctx) * BIG_FONT_SCALE)

    -- Reserve room for the Capture Name button, the "x" clear button, and
    -- the enum badge, all drawn after the input at normal
    -- (non-BIG_FONT_SCALE) size. Flat pixel budget rather than measured via
    -- CalcTextSize, since measuring "Capture Name" accurately here would
    -- mean doing it at the WRONG, currently-pushed BIG_FONT_SCALE font
    -- (this call runs before PopFont below) - all three trailing labels are
    -- short/stable, so a generous flat reservation is simpler and safe.
    reaper.ImGui_SetNextItemWidth(ctx, reaper.ImGui_GetContentRegionAvail(ctx) - 250)
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
    --
    -- Not cleared unconditionally here: for a click-driven accept (needs_
    -- refocus=true), SetKeyboardFocusHere() was just requested moments ago,
    -- and it's not certain the widget is *already* active by the time this
    -- same InputText() call runs the "Always" callback - if it isn't yet
    -- (focus lands starting next frame instead), the callback attached this
    -- frame silently never fires, and clearing pending_replace regardless
    -- would drop the swap entirely. Keeping it set (and re-attaching the
    -- callback) until IsItemActive() actually reports true retries this
    -- safely: once confirmed active, the callback has necessarily already
    -- had its chance to run that same call, so it's safe to stop retrying.
    local input_flags, input_callback = reaper.ImGui_InputTextFlags_None(), nil
    if wgt.quick.pending_replace ~= nil then
      input_flags = reaper.ImGui_InputTextFlags_CallbackAlways()
      input_callback = MakeReplaceCallback(ctx, wgt.quick.pending_replace)
      -- Safety cap: if the widget somehow never reports active (e.g. this
      -- whole timing theory is wrong), give up after a few frames instead
      -- of recompiling a fresh EEL function indefinitely every frame.
      wgt.quick.pending_replace_tries = (wgt.quick.pending_replace_tries or 0) + 1
    else
      -- No pending Accept/Clear this frame: attach the live find/replace
      -- CharFilter callback instead (see BuildCharFilterBody), so a typed
      -- space (etc.) is substituted the instant it's typed, not just in the
      -- Preview table below. Compiled once per scheme and cached, not
      -- rebuilt every keystroke - the character mapping only depends on the
      -- scheme (`data`), which is static for as long as the same `data`
      -- table is in use. A scheme reload/switch always produces a
      -- brand-new `data` table (see LoadScheme in the main script), which
      -- naturally invalidates this cache via the identity check below.
      if wgt.quick.char_filter_data ~= data then
        wgt.quick.char_filter_data = data
        local body = BuildCharFilterBody(data)
        wgt.quick.char_filter_fn = body and MakeCharFilterCallback(ctx, body) or nil
      end
      if wgt.quick.char_filter_fn then
        input_flags = reaper.ImGui_InputTextFlags_CallbackCharFilter()
        input_callback = wgt.quick.char_filter_fn
      end
    end

    local changed, new_text = reaper.ImGui_InputText(ctx, "##quick_name", wgt.quick.text, input_flags, input_callback)
    -- Captured right after the InputText call so the "x" clear button below
    -- (drawn at normal, non-BIG_FONT_SCALE size) can be sized to match its
    -- height instead of being visibly shorter than the enlarged name box.
    local _, input_h = reaper.ImGui_GetItemRectSize(ctx)
    if changed then wgt.quick.text = new_text end
    wgt.quick.input_was_active = reaper.ImGui_IsItemActive(ctx)
    if wgt.quick.input_was_active or (wgt.quick.pending_replace_tries or 0) > 5 then
      wgt.quick.pending_replace = nil
      wgt.quick.pending_replace_tries = nil
    end

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

    -- Drops the currently selected item's raw take name into the box,
    -- unparsed (unlike the classic tab's own "Capture Name", which parses a
    -- selected item's name into the scheme's per-field values - meaningless
    -- here, since Quick Naming has just one free-type box, not fields),
    -- minus any trailing enumeration token (see StripTrailingEnumeration
    -- above) - same pending_replace/want_focus mechanism as Accept()/
    -- ClearText() above, since this is a mouse click, not a keystroke, and
    -- needs the same in-place active-buffer rewrite to actually stick.
    -- No-ops if nothing is selected (or it has no name), same as the
    -- classic tab's own "Capture Name" button silently no-op-ing on no
    -- selection.
    local function CaptureName()
      local name = Helpers.GetSelectedItemName()
      if not name then return end
      wgt.quick.pending_replace = StripTrailingEnumeration(name, data.separator)
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

    -- Sized to input_h on the height axis only (auto width, since "Capture"
    -- needs more room than a single "x" glyph) so it still visually lines
    -- up with the name box and the square clear button to its right.
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushItemFlag(ctx, reaper.ImGui_ItemFlags_NoTabStop(), true)
    if reaper.ImGui_Button(ctx, "Capture Name##quick_capture_name", 0, input_h) then CaptureName() end
    reaper.ImGui_PopItemFlag(ctx)
    acendan.ImGui_Tooltip("Captures the name of the currently selected item into the box above.")

    -- Same "x##<id> + NoTabStop + clear tooltip" convention
    -- SchemeEditorGui.ComboBox/AutoFillComboBox use for their own clear
    -- buttons, but sized to input_h (the name box's own height, captured
    -- above) on both axes - square, and matching the box's BIG_FONT_SCALE
    -- height - rather than SmallButton's tight, normal-size auto-fit, which
    -- left it visibly shorter than the enlarged input next to it.
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushItemFlag(ctx, reaper.ImGui_ItemFlags_NoTabStop(), true)
    if reaper.ImGui_Button(ctx, "x##quick_name_clear", input_h, input_h) then ClearText() end
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

    reaper.ImGui_SeparatorText(ctx, "Preview")
    reaper.ImGui_TextDisabled(ctx, "Rename " .. #preview_rows .. " " .. ((wgt.target or "items"):lower()))
    local table_flags = reaper.ImGui_TableFlags_Borders() | reaper.ImGui_TableFlags_RowBg() |
        reaper.ImGui_TableFlags_ScrollY()
    local content_y0 = reaper.ImGui_GetCursorPosY(ctx)
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    -- Fills whatever room is actually left in this child after the table,
    -- reserving exact space for the "Targets" section drawn below it. That
    -- footer's real height (including the item-spacing between the table
    -- and "Targets", which a per-widget estimate kept missing by a few px -
    -- just enough for this child's content to overflow its available
    -- height and leave a permanent vertical scrollbar) is measured AFTER
    -- it's drawn - see the cursor-pos delta below - and reused here one
    -- frame late. Self-corrects within a frame if the row count changes
    -- (e.g. picking a Target), and floors at the original fixed baseline
    -- so the table doesn't collapse to nothing (letting the child
    -- overflow/scroll instead) once the window gets smaller than the
    -- footer alone needs.
    local scale = acendan.ImGui_GetScale()
    local footer_h = wgt.quick.targets_footer_h or
        (reaper.ImGui_GetTextLineHeightWithSpacing(ctx) + 3 * reaper.ImGui_GetFrameHeightWithSpacing(ctx))
    local table_h = math.max(QUICK_PREVIEW_TABLE_HEIGHT * scale, avail_h - footer_h)
    if reaper.ImGui_BeginTable(ctx, "quick_naming_preview", 2, table_flags, avail_w, table_h) then
      reaper.ImGui_TableSetupColumn(ctx, "Current Name")
      reaper.ImGui_TableSetupColumn(ctx, "New Name")
      reaper.ImGui_TableHeadersRow(ctx)
      for i, row in ipairs(preview_rows) do
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        reaper.ImGui_Text(ctx, row.current)
        reaper.ImGui_TableSetColumnIndex(ctx, 1)
        -- Nothing typed yet (PreviewRename still runs with a blank name so
        -- the table lists the matched targets immediately on selection,
        -- mirroring nvk.tools) - show a muted placeholder instead of a
        -- blank cell, so an empty New Name column reads as "nothing typed"
        -- rather than looking broken.
        if row.new == "" then
          reaper.ImGui_TextDisabled(ctx, "<empty>")
        else
          reaper.ImGui_Text(ctx, row.new)
        end
      end
      reaper.ImGui_EndTable(ctx)
    end

    reaper.ImGui_Spacing(ctx)
    -- A fresh enumeration table, NOT the `enumeration` local from the top of
    -- this frame: that one was already consumed by PreviewRename above
    -- (which runs unconditionally every frame to feed the live table), and
    -- SanitizeName increments `.start` in place as it goes - reusing it here
    -- would mean the real rename picks up wherever the preview pass left
    -- the counter (e.g. starting at 4 for a 3-item preview that ran right
    -- before this click), instead of starting fresh from the scheme's
    -- actual Enumeration value.
    local function DoRename()
      wgt.quick.error = nil
      local apply_enumeration = BuildEnumeration(data)
      local apply_name = BuildFullName(wgt.quick.text, apply_enumeration)
      Helpers.ApplyQuickName(wgt.target, wgt.mode, apply_name, apply_enumeration)
    end

    -- Same styling (color, 1.5x font) and SameLine spacing as the classic
    -- Scheme Naming tab's Rename/Export buttons (see TabNaming in the main
    -- script) - kept visually consistent across both naming modes rather
    -- than picking arbitrary new colors here.
    reaper.ImGui_PushFont(ctx, acendan.ImGui_Styles.font, reaper.ImGui_GetFontSize(ctx) * BIG_FONT_SCALE)
    if invalid then reaper.ImGui_BeginDisabled(ctx) end
    acendan.ImGui_Button("Rename", DoRename, {86, 64, 110})
    local _, button_h = reaper.ImGui_GetItemRectSize(ctx)
    if invalid then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_PopFont(ctx)
    acendan.ImGui_Tooltip("Pro Tip: You can press the 'Enter' key to trigger renaming from the name field above.")

    local has_export = Helpers.HasExportScript()
    reaper.ImGui_SameLine(ctx, 0, 10)
    if not has_export then reaper.ImGui_BeginDisabled(ctx) end
    reaper.ImGui_PushFont(ctx, acendan.ImGui_Styles.font, reaper.ImGui_GetFontSize(ctx) * BIG_FONT_SCALE)
    acendan.ImGui_Button("Export", Helpers.RunExportScript, {70, 160, 210})
    reaper.ImGui_PopFont(ctx)
    acendan.ImGui_Tooltip("Runs the export script configured in the Settings tab.")
    if not has_export then reaper.ImGui_EndDisabled(ctx) end

    -- Scoped to this window's own focus (resolves against the child window
    -- created by BeginChild above, not a top-level window - a child becomes
    -- Dear ImGui's "focused window" once an item inside it gains keyboard
    -- focus, which this module's own SetKeyboardFocusHere auto-focus logic
    -- above already ensures happens): a bare IsKeyReleased check is true
    -- regardless of which window/tab currently has focus, which would fire
    -- this alongside (or instead of) whichever the user actually meant to
    -- submit - e.g. another floating window like the Scheme Visual Editor.
    local enter_submit = not invalid and reaper.ImGui_IsWindowFocused(ctx) and
        reaper.ImGui_IsKeyReleased(ctx, reaper.ImGui_Key_Enter())
    if enter_submit then DoRename() end

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

    reaper.ImGui_SeparatorText(ctx, "Targets")
    Helpers.LoadTargets()
    -- Feeds next frame's footer_h above - measured as "everything drawn
    -- from content_y0 onward, minus the table's own height" so the
    -- item-spacing ImGui inserts after the table is folded into the
    -- reserved footer rather than silently dropped.
    wgt.quick.targets_footer_h = (reaper.ImGui_GetCursorPosY(ctx) - content_y0) - table_h
  end
  reaper.ImGui_EndChild(ctx)
end

return QuickNamingGui
