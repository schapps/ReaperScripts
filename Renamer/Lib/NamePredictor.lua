-- @noindex
-- NamePredictor: pure-Lua, scheme-aware autocomplete engine for Quick Naming
-- mode. Given the scheme's field tree and the raw text a user is free-typing,
-- predicts which fields have been confirmed so far, what the in-progress
-- trailing token could complete to, and ranked candidates for it.
--
-- Deliberately advisory, never mutates the field tree - unlike
-- AutoFillFromItem's reverse parser (schapps_The Last Renamer.lua), which
-- this mirrors structurally (same field-tree walk order, same TryMatchField
-- matching) but must not share mutation behavior with: Quick Naming and the
-- classic Naming tab are independent views over the same live field
-- objects, and this runs every keystroke, so writing to field.selected/
-- field.value here would silently corrupt the classic tab's widget state.
-- A local `shadow` table records this call's own provisional matches
-- instead, falling back to the field's live state only for id-gating.

local NamePredictor = {}

local Match    -- TryMatchField(field, parts, idx) -> match_type, match_val, parts_consumed (or nil)
local Split    -- SplitBySep(str, sep) -> parts
local Cap      -- Capitalize(str, capitalization) -> str

-- helpers = { TryMatchField = ..., SplitBySep = ..., Capitalize = ... }
-- Injected because these are `local function`s inside the main script's
-- AUTOFILL section, not globals - dofile'd modules can't see them
-- otherwise. See the main script for why NamePredictor.init() is called
-- near the bottom of the file (after those locals exist) rather than
-- alongside the other Lib modules' init() calls near the top.
function NamePredictor.init(helpers)
  Match = helpers.TryMatchField
  Split = helpers.SplitBySep
  Cap   = helpers.Capitalize
end

local function PrefixMatch(str, partial)
  if partial == "" then return true end
  if not str or str == "" then return false end
  return str:lower():sub(1, #partial) == partial:lower()
end

-- Shadow-aware lookups: prefer this call's own provisional match over the
-- field's live .selected/.value (which may be stale, unset - e.g. Quick
-- Naming opened before the classic tab ever rendered - or simply owned by
-- the classic tab's widgets).
local function ShadowSelected(field, shadow)
  local s = shadow[field]
  if s and s.match_type == "selected" then return s.match_val end
  return field.selected or field.default or 0
end

local function ShadowValue(field, shadow)
  local s = shadow[field]
  if s then return s.match_val end
  return field.value
end

-- Mirrors PassesIDCheck (main script), but resolves the parent's current
-- value through the shadow table first.
local function PassesIDCheckShadow(field, parent, shadow)
  if field.id == nil then return true end
  if not parent then return false end
  if type(field.id) == "boolean" then
    return ShadowValue(parent, shadow) == field.id
  end
  if type(parent.value) ~= "table" then return false end
  local selected_val = parent.value[ShadowSelected(parent, shadow)]
  if type(field.id) == "table" then
    for _, id in ipairs(field.id) do
      if selected_val == id then return true end
    end
    return false
  end
  return selected_val == field.id
end

-- Rank candidate completions for the in-progress trailing token against
-- `field`'s dropdown options / short codes / boolean labels. Free-text
-- string fields have nothing to rank - they just become `next_field` so the
-- UI can show a hint cue instead of a real completion.
--
-- For dropdown fields with a `short` array, `insert` is the short code, not
-- the full value - mirrors LoadField's own composition rule (main script:
-- "value = (field.selected and field.short) and field.short[field.selected]
-- or field.value[field.selected]"), i.e. a scheme that defines short codes
-- always composes the short code into the actual name, never the long form.
-- `label` still shows "Full Name  (CODE)" for readability (same format
-- SchemeVisualizer's inspector already uses), and `match_source` is
-- whichever string (full or short) `partial` actually matched, so the
-- caller can compute a ghost-text remainder against what the user is
-- literally typing rather than against `insert`, which may now be a
-- differently-sized string.
local function RankCandidates(field, partial)
  local out = {}
  if type(field.value) == "table" then
    local scored = {}
    for i, val in ipairs(field.value) do
      if val ~= "" then
        local short = field.short and field.short[i]
        local has_short = short and short ~= ""
        local match_source = nil
        if PrefixMatch(val, partial) then
          match_source = val
        elseif has_short and PrefixMatch(short, partial) then
          match_source = short
        end
        if match_source then
          scored[#scored + 1] = { index = i, text = val, short = has_short and short or nil, match_source = match_source }
        end
      end
    end
    -- With no partial typed yet, every option matches trivially on its full
    -- value (see the `match_source = val` branch above) - ranking those by
    -- match length would just sort the whole list by name length, unrelated
    -- to the scheme's own field.value order. Keep scheme order in that case;
    -- once the user is actually typing, rank shorter/closer matches first
    -- (e.g. an exact short-code hit ahead of a long value that merely shares
    -- the same prefix), falling back to scheme order for ties.
    table.sort(scored, function(a, b)
      if partial == "" then return a.index < b.index end
      if #a.match_source == #b.match_source then return a.index < b.index end
      return #a.match_source < #b.match_source
    end)
    for i = 1, #scored do
      local s = scored[i]
      local insert_raw = s.short or s.text
      local insert = Cap and Cap(insert_raw, field.capitalization) or insert_raw
      local label = s.short and (s.text .. "  (" .. s.short .. ")") or s.text
      out[#out + 1] = { label = label, insert = insert, match_source = s.match_source, field_index = s.index }
    end
  elseif type(field.value) == "boolean" then
    for _, label in ipairs({ field.btrue, field.bfalse }) do
      if label and label ~= "" and PrefixMatch(label, partial) then
        local text = Cap and Cap(label, field.capitalization) or label
        out[#out + 1] = { label = text, insert = text, match_source = label }
      end
    end
  end
  return out
end

-- Walk `fields` in scheme order, consuming confirmed `parts` against each
-- visible, text-bearing field. Mirrors LoadFields' strict id-gating (skip
-- entirely, don't recurse, when a field isn't currently visible) rather
-- than FillFields' lenient reverse-parse gating (which recurses into a
-- hidden field's children anyway) - prediction is about what the CURRENTLY
-- VISIBLE scheme structure expects next, not about tolerantly re-deriving
-- structure from an arbitrary existing name.
--
-- Number/enumeration fields and skip fields never correspond to a literal
-- typed token (numbers are auto-appended separately by the caller; skip
-- fields exist only to gate children and never emit into the name - see
-- LoadField's `unskippable` check), so both are stepped over without
-- consuming a part and never offered as suggestions - they just recurse
-- into their children for id-gating purposes, using shadow-or-live state.
local function Walk(fields, parent, shadow, ctx, parts)
  for _, field in ipairs(fields) do
    if ctx.next_field or ctx.stopped then return end
    if not PassesIDCheckShadow(field, parent, shadow) then
      -- not visible under current (shadow/live) selection; skip entirely
    elseif type(field.value) == "number" or field.numwild then
      if field.fields then Walk(field.fields, field, shadow, ctx, parts) end
    elseif field.skip then
      if field.fields then Walk(field.fields, field, shadow, ctx, parts) end
    else
      if ctx.idx <= #parts then
        local match_type, match_val, n = Match(field, parts, ctx.idx)
        if match_type then
          shadow[field] = { match_type = match_type, match_val = match_val }
          ctx.matched[#ctx.matched + 1] = { field = field, match_type = match_type, match_val = match_val }
          ctx.idx = ctx.idx + (n or 0)
          if field.fields then Walk(field.fields, field, shadow, ctx, parts) end
        else
          -- Typed text diverges from the scheme here: stop suggesting for
          -- the rest of the name (advisory, never enforced - see plan).
          ctx.stopped = true
        end
      else
        ctx.next_field = field
      end
    end
  end
end

-- Predict(fields, separator, typed_text) -> {
--   matched    = { {field, match_type, match_val}, ... },  -- confirmed tokens, in order
--   partial    = "abc",           -- the in-progress trailing token (never separator-terminated)
--   next_field = field_or_nil,    -- the field `partial` would complete, if any
--   candidates = { {label, insert, field_index}, ... },    -- ranked, capped at 8
-- }
function NamePredictor.Predict(fields, separator, typed_text)
  local result = { matched = {}, partial = "", next_field = nil, candidates = {} }
  if not fields or not separator or not typed_text then
    return result
  end

  local parts = Split(typed_text, separator)
  if typed_text:sub(-#separator) ~= separator then
    result.partial = parts[#parts] or ""
    parts[#parts] = nil
  end

  local ctx = { idx = 1, matched = result.matched, next_field = nil, stopped = false }
  Walk(fields, nil, {}, ctx, parts)

  result.next_field = ctx.next_field
  if ctx.next_field then
    result.candidates = RankCandidates(ctx.next_field, result.partial)
  end
  return result
end

return NamePredictor
