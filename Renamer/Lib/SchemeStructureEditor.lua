-- @noindex
-- SchemeStructureEditor: pure logic + file I/O for inserting a brand-new
-- YAML field block (any type, top-level or nested) into a scheme file.
--
-- Unlike SchemeEditor.lua (which only ever rewrites ONE existing line),
-- this module splices whole new multi-line blocks into the file - still
-- following the same "never fully re-serialize the document" philosophy:
-- locate the exact splice point via content-matching against the raw file,
-- read once, mutate an in-memory line array, write once.
--
-- Depends on SchemeEditor.lua (injected via init(), since dofile'd chunks
-- don't share this repo's `local` variables) for ReadRawLines,
-- EscapePattern, FindFieldBlockRange, QuoteBareToken, and the structural
-- snapshot/undo functions.

local M = {}

local Editor

function M.init(scheme_editor)
  Editor = scheme_editor
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~ SERIALIZATION ~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

local function EscapeDquote(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

-- Samples the file's prevailing inline-list quoting convention (single-
-- quoted like UCS.yaml vs. bare like Example.yaml) from a bounded window
-- around the insertion point, so a new field doesn't look like a
-- stylistic outlier next to its new siblings. Falls back to a whole-file
-- scan, then to nil (bare) if the file has no inline lists at all. Only
-- samples actual `value:`/`short:` dropdown-option lines - NOT any
-- bracketed list (e.g. a scheme's own `illegal: ["...", ...]`/`find: [...]`
-- top-level settings use a different, unrelated quoting convention and
-- would otherwise get sampled first since they sit near the top of the file).
local function DetectPrevailingListStyle(lines, hint_line)
  local function scan(from, to, step)
    for i = from, to, step do
      if lines[i] then
        local q = lines[i]:match("^%s*value%s*:%s*%[%s*(['\"])") or
                  lines[i]:match("^%s*short%s*:%s*%[%s*(['\"])")
        if q then return q end
      end
    end
  end
  if hint_line then
    local found = scan(hint_line, math.max(1, hint_line - 40), -1)
    if found then return found end
    found = scan(hint_line, math.min(#lines, hint_line + 40), 1)
    if found then return found end
  end
  return scan(1, #lines, 1)
end

local function SerializeList(items, style)
  local parts = {}
  for _, item in ipairs(items) do
    parts[#parts + 1] = Editor.QuoteBareToken(tostring(item), style.quote_char, true)
  end
  return table.concat(parts, ", ")
end

-- field.id can be a single scalar, a table of scalars (list-form id, e.g.
-- Example.yaml's `id: [Dogs, Cats]`), or a boolean (for a boolean parent).
local function SerializeIdValue(id, style)
  if type(id) == "table" then
    local parts = {}
    for _, v in ipairs(id) do
      local tok, err = Editor.QuoteBareToken(tostring(v), style.quote_char, true)
      if not tok then return nil, err end
      parts[#parts + 1] = tok
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  elseif type(id) == "boolean" then
    return tostring(id)
  else
    return Editor.QuoteBareToken(tostring(id), style.quote_char, false)
  end
end

-- Given a plain Lua table describing a new field's desired properties (see
-- ValidateFieldSpec below for the accepted shape), returns an array of
-- freshly-formatted YAML line strings (no trailing newline), indented for
-- insertion at `item_indent` (the indentation of this new entry's own "-"
-- dash), or nil, error if the spec is invalid or unsafe to serialize.
function M.SerializeNewFieldBlock(field_spec, item_indent, style)
  local pad_item = string.rep(" ", item_indent)
  local pad_prop = string.rep(" ", item_indent + 2)
  local out = {}
  local function emit(s) out[#out + 1] = s end

  local label_tok, lerr = Editor.QuoteBareToken(field_spec.label, style.quote_char, false)
  if not label_tok then return nil, lerr end

  if field_spec.id ~= nil then
    local id_tok, ierr = SerializeIdValue(field_spec.id, style)
    if not id_tok then return nil, ierr end
    emit(pad_item .. "- id: " .. id_tok)
    emit(pad_prop .. "field: " .. label_tok)
  else
    emit(pad_item .. "- field: " .. label_tok)
  end

  if field_spec.required then emit(pad_prop .. "required: true") end
  if field_spec.skip then emit(pad_prop .. "skip: true") end

  if field_spec.type == "dropdown" then
    emit(pad_prop .. "value: [" .. SerializeList(field_spec.options, style) .. "]")
    if field_spec.short and #field_spec.short > 0 then
      emit(pad_prop .. "short: [" .. SerializeList(field_spec.short, style) .. "]")
    end
    if field_spec.default then
      emit(pad_prop .. "default: " .. tostring(math.floor(field_spec.default)))
    end

  elseif field_spec.type == "text" then
    local val_tok, verr = Editor.QuoteBareToken(field_spec.value or "", style.quote_char, false)
    if not val_tok then return nil, verr end
    emit(pad_prop .. "value: " .. val_tok)
    if field_spec.hint and field_spec.hint ~= "" then
      emit(pad_prop .. 'hint: "' .. EscapeDquote(field_spec.hint) .. '"')
    end

  elseif field_spec.type == "boolean" then
    emit(pad_prop .. "value: " .. tostring(not not field_spec.value))
    -- Always emit BOTH, even as "" - matching every existing hand-authored
    -- boolean field in the real scheme corpus. The main script's renderer
    -- does `field.value and field.btrue or field.bfalse`; omitting either
    -- key (rather than writing it as an empty string) leaves that
    -- attribute genuinely nil, which crashes with "attempt to concatenate
    -- a nil value" the moment that branch is actually taken.
    emit(pad_prop .. 'btrue: "' .. EscapeDquote(field_spec.btrue or "") .. '"')
    emit(pad_prop .. 'bfalse: "' .. EscapeDquote(field_spec.bfalse or "") .. '"')

  elseif field_spec.type == "number" then
    emit(pad_prop .. "value: " .. tostring(tonumber(field_spec.value) or 0))
    if field_spec.zeroes then emit(pad_prop .. "zeroes: " .. tostring(math.floor(field_spec.zeroes))) end
    if field_spec.singles ~= nil then emit(pad_prop .. "singles: " .. tostring(not not field_spec.singles)) end

  else
    return nil, "Unknown field type: " .. tostring(field_spec.type)
  end

  if field_spec.capitalization and field_spec.capitalization ~= "" and field_spec.capitalization ~= "None" then
    emit(pad_prop .. "capitalization: " .. field_spec.capitalization)
  end
  if field_spec.separator and field_spec.separator ~= "" then
    emit(pad_prop .. 'separator: "' .. EscapeDquote(field_spec.separator) .. '"')
  end
  if field_spec.help and field_spec.help ~= "" then
    emit(pad_prop .. 'help: "' .. EscapeDquote(field_spec.help) .. '"')
  end

  return out
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~ VALIDATION ~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

local function ValidateFieldSpec(field_spec, is_child)
  if not field_spec.label or field_spec.label:match("^%s*$") then
    return false, "Field name cannot be blank."
  end
  if field_spec.type == "dropdown" then
    if not field_spec.options or #field_spec.options == 0 then
      return false, "A dropdown field needs at least one option."
    end
    for _, v in ipairs(field_spec.options) do
      if v == "" or (type(v) == "string" and v:match("^%s*$")) then
        return false, "Dropdown options cannot be blank."
      end
    end
  elseif field_spec.type ~= "text" and field_spec.type ~= "boolean" and field_spec.type ~= "number" then
    return false, "Unknown field type."
  end
  -- Deliberately no cross-sibling name-uniqueness check: the real scheme
  -- corpus already legitimately reuses the same label (e.g. "Manufacturer")
  -- across different id branches, so that rule would reject valid authoring.
  if is_child and field_spec.id == nil then
    return false, "A child field needs at least one id condition selected."
  end
  return true
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~ INSERT ~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Re-locates `field` in a freshly re-read `lines` array (never trusts
-- cached line numbers from scheme-load time across a commit), returning
-- its current item_indent, block_start_line, block_end_line, or
-- nil, nil, nil, err on failure.
local function ReverifyField(lines, field)
  local start = field and field.__block_start_line
  if not start or not lines[start] then
    return nil, nil, nil, "Scheme file changed on disk since it was loaded. Please reload the scheme and try again."
  end
  local pattern = "field%s*:%s*['\"]?" .. Editor.EscapePattern(field.field) .. "['\"]?%s*$"
  local field_line
  if lines[start]:match(pattern) then
    field_line = start
  elseif lines[start + 1] and lines[start + 1]:match(pattern) then
    field_line = start + 1
  end
  if not field_line then
    return nil, nil, nil, "Scheme file changed on disk since it was loaded. Please reload the scheme and try again."
  end
  local item_indent, block_start, block_end = Editor.FindFieldBlockRange(lines, field_line)
  if not item_indent then
    return nil, nil, nil, "Could not confidently re-locate this field. Please reload the scheme and try again."
  end
  return item_indent, block_start, block_end
end

-- `target` is one of:
--   { kind = "top_level_append" }
--   { kind = "top_level_after", ref_field = <field> }
--   { kind = "child_append", parent_field = <field> }
--   { kind = "child_after", parent_field = <field>, ref_field = <field> }
-- Phase 1's GUI only ever produces the "_append" forms; the "_after" shapes
-- exist now so later reordering can reuse this same primitive.
--
-- Does one read, one in-memory splice, one write per commit.
function M.InsertFieldBlock(source_path, top_level_fields, target, field_spec)
  if not Editor.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    local lines = Editor.ReadRawLines(source_path)
    if not lines then error("Could not read scheme file.") end

    local insert_after_line, item_indent

    if target.kind == "top_level_append" or target.kind == "top_level_after" then
      local anchor = target.ref_field or top_level_fields[#top_level_fields]
      if not anchor then error("This scheme has no top-level fields to anchor a new field after.") end
      local ii, _, be, err = ReverifyField(lines, anchor)
      if err then error(err) end
      item_indent, insert_after_line = ii, be

    else -- "child_append" / "child_after"
      local parent = target.parent_field
      local pii, _, pbe, perr = ReverifyField(lines, parent)
      if perr then error(perr) end

      if parent.fields and #parent.fields > 0 then
        local last_child = target.ref_field or parent.fields[#parent.fields]
        local ii, _, be, cerr = ReverifyField(lines, last_child)
        if cerr then error(cerr) end
        item_indent, insert_after_line = ii, be
      else
        -- No `fields:` key yet: insert one at the parent's own property
        -- indent, then the new child block one level deeper, both
        -- appended at the very end of the parent's (currently childless) block.
        local fields_key_indent = pii + 2
        table.insert(lines, pbe + 1, string.rep(" ", fields_key_indent) .. "fields:")
        insert_after_line = pbe + 1
        item_indent = pii + 4
      end
    end

    local style = { quote_char = DetectPrevailingListStyle(lines, insert_after_line) }
    local new_block, serr = M.SerializeNewFieldBlock(field_spec, item_indent, style)
    if not new_block then error(serr) end

    for i, l in ipairs(new_block) do
      table.insert(lines, insert_after_line + i, l)
    end

    -- No trailing "\n" appended here, matching SchemeEditor.WriteSchemeList's
    -- exact convention - ReadRawLines' line-splitting already produces a
    -- phantom empty trailing element for a file that ends in a newline
    -- (see its "(content..'\n'):gmatch" pattern), so table.concat alone
    -- naturally restores exactly one trailing newline; appending another
    -- here would double it.
    local content = table.concat(lines, "\n")
    local f = assert(io.open(source_path, "wb"))
    f:write(content)
    f:close()
  end)

  if not ok then
    return false, tostring(result)
  end
  return true
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~ EDIT ~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Finds the line where `field`'s OWN properties end, within its already-
-- located block [block_start, block_end]. If it has a nested `fields:` key
-- (i.e. existing children), that line - and everything after it - must be
-- left completely untouched by an edit; only replacing field.field/id/
-- value/etc requires regenerating [block_start, own_props_end]. Returns
-- block_end itself when there's no `fields:` key (no children to preserve).
local function FindOwnPropsEnd(lines, item_indent, block_start, block_end)
  local prop_indent = item_indent + 2
  for i = block_start + 1, block_end do
    if lines[i]:match("%S") then
      local indent = #(lines[i]:match("^(%s*)") or "")
      if indent == prop_indent and lines[i]:match("^%s*fields%s*:%s*$") then
        return i - 1
      end
    end
  end
  return block_end
end

-- Replaces `field`'s own properties (label, id, value, required, help,
-- etc) with a freshly-serialized version reflecting `field_spec`, reusing
-- the exact same serializer as field creation - WITHOUT touching any
-- existing nested `fields:` key or children, which are left exactly as-is.
--
-- Refuses (before touching anything) if ANY of this field's own current
-- property lines contain a `$wildcard` reference. `field.__wildcard_key`/
-- `__id_wildcard_key` (set by AttachSourceLocations) only cover the common
-- `value:`/`id:` cases and are checked earlier as a cheap fast-fail in
-- CommitEditField, but acendan.loadYaml's wildcard substitution is a blind
-- textual replace across the WHOLE file - a $name can appear in `hint:`,
-- `help:`, `separator:`, or any other scalar property too (confirmed: this
-- codebase's own Example.yaml uses `hint: $bodyHint`). So this function
-- does its own general, authoritative scan of the field's current raw
-- lines for any `$name` occurrence at all, rather than trusting only the
-- narrower pre-computed flags - naively regenerating a line containing one
-- would silently replace the shared reference with a disconnected literal
-- copy. This check (and the field re-verification, and serialization) all
-- happen BEFORE SnapshotSchemeFile, so a refused edit never takes a
-- backup or pushes an undo entry for something that didn't actually happen.
--
-- One read, one in-memory splice, one write, same as every other
-- write-back feature this session.
function M.ReplaceFieldProperties(source_path, field, field_spec)
  local lines = Editor.ReadRawLines(source_path)
  if not lines then return false, "Could not read scheme file." end

  local item_indent, block_start, block_end, err = ReverifyField(lines, field)
  if err then return false, err end

  local own_props_end = FindOwnPropsEnd(lines, item_indent, block_start, block_end)

  for i = block_start, own_props_end do
    if lines[i]:match("%$[%w_]+") then
      return false, "This field's properties include a shared $wildcard reference - editing it here " ..
        "would replace the reference with a fixed copy. Edit the wildcard-backed value directly " ..
        "(right-click the dropdown itself), or hand-edit the YAML for this property."
    end
  end

  local style = { quote_char = DetectPrevailingListStyle(lines, block_start) }
  local new_lines, serr = M.SerializeNewFieldBlock(field_spec, item_indent, style)
  if not new_lines then return false, serr end

  if not Editor.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    for i = own_props_end, block_start, -1 do
      table.remove(lines, i)
    end
    for i, l in ipairs(new_lines) do
      table.insert(lines, block_start - 1 + i, l)
    end

    local content = table.concat(lines, "\n")
    local f = assert(io.open(source_path, "wb"))
    f:write(content)
    f:close()
  end)

  if not ok then
    return false, tostring(result)
  end
  return true
end

-- Orchestration: validates and replaces `field`'s properties, returning
-- ok, err, reload_requests (an empty array on success, same policy as
-- CommitCreateField/CommitDeleteField - nothing meaningful to reselect).
--
-- The field.__wildcard_key/__id_wildcard_key check here is a cheap,
-- early fast-fail for the common cases (avoids even reading the file);
-- ReplaceFieldProperties does the authoritative, general check covering
-- any OTHER property that might also reference a wildcard.
function M.CommitEditField(source_path, field, field_spec, is_child)
  if not source_path then return false, "No scheme file path available." end
  if field.__wildcard_key or field.__id_wildcard_key then
    return false, "This field's value or visibility condition is a shared $wildcard reference - " ..
      "editing it here would replace the reference with a fixed copy. Edit the wildcard-backed " ..
      "list directly (right-click the dropdown itself) instead."
  end

  local vok, verr = ValidateFieldSpec(field_spec, is_child)
  if not vok then return false, verr end

  local rok, rerr = M.ReplaceFieldProperties(source_path, field, field_spec)
  if not rok then return false, rerr end

  return true, nil, {}
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~ EXTRACT TO WILDCARD ~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Turns a field's own literal dropdown value into a brand-new shared
-- "$name: [ ... ]" definition, replacing the field's `value:` line with a
-- `$name` reference - the inverse of the substitution pass. Belongs here
-- (not SchemeEditor.lua) because, like InsertFieldBlock, it touches TWO
-- separate regions of the file (the field's own block AND a brand-new
-- top-level line) in one commit.
--
-- Only ever touches `value:` - `short:` (if present) and any nested
-- `fields:`/children stay exactly as they are: every real wildcard in the
-- scheme corpus (Example.yaml's $countries/$bodyHint) has no companion
-- "short wildcard", so short codes remain field-owned.
function M.CommitExtractToWildcard(source_path, field, wildcard_name)
  if not source_path then return false, "No scheme file path available." end
  if type(field.value) ~= "table" then
    return false, "Only dropdown fields can be extracted to a shared wildcard."
  end
  if field.__wildcard_key then
    return false, "This field's value is already a shared $wildcard reference."
  end
  if not wildcard_name or wildcard_name:match("^%s*$") then
    return false, "Wildcard name cannot be blank."
  end
  if not wildcard_name:match("^[%w_]+$") then
    return false, "Wildcard names can only contain letters, numbers, and underscores."
  end

  local lines = Editor.ReadRawLines(source_path)
  if not lines then return false, "Could not read scheme file." end

  for _, def in ipairs(Editor.ListWildcardDefinitions(source_path)) do
    if def.name == wildcard_name then
      return false, "A wildcard named $" .. wildcard_name .. " already exists."
    end
  end

  local item_indent, block_start, block_end, verr = ReverifyField(lines, field)
  if verr then return false, verr end

  local own_props_end = FindOwnPropsEnd(lines, item_indent, block_start, block_end)
  local value_line, value_indent
  for i = block_start, own_props_end do
    local indent, v = lines[i]:match("^(%s*)value%s*:%s*%[")
    if indent then value_line, value_indent = i, indent; break end
  end
  if not value_line then
    return false, "Could not locate this field's own value list (unsupported/multi-line format)."
  end

  local anchor_line
  for i, line in ipairs(lines) do
    if line:match("^fields%s*:%s*$") then anchor_line = i; break end
  end
  if not anchor_line then
    return false, "Could not find this scheme's top-level 'fields:' key to anchor the new wildcard."
  end

  local style = { quote_char = DetectPrevailingListStyle(lines, value_line) }
  local bracket_body = "[" .. SerializeList(field.value, style) .. "]"

  if not Editor.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    lines[value_line] = value_indent .. "value: $" .. wildcard_name
    table.insert(lines, anchor_line, "$" .. wildcard_name .. ": " .. bracket_body)
    local content = table.concat(lines, "\n")
    local f = assert(io.open(source_path, "wb"))
    f:write(content)
    f:close()
  end)
  if not ok then return false, tostring(result) end
  return true, nil, {}
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~ DELETE ~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Recursive count of every nested field under `field` (not including
-- `field` itself) - used by the GUI's delete-confirmation warning text.
function M.CountDescendants(field)
  if not field.fields then return 0 end
  local count = 0
  for _, child in ipairs(field.fields) do
    count = count + 1 + M.CountDescendants(child)
  end
  return count
end

-- Was this entry the sole item in its parent's `fields:` array? The line
-- immediately before its own dash is the `fields:` key itself ONLY if this
-- is the FIRST child (any other sibling's preceding line would be the end
-- of the PRIOR sibling's block, never the `fields:` key) - and it's also
-- the LAST child if nothing at the same item_indent follows it. Returns the
-- `fields:` key's line number if both hold (sole child - caller should
-- remove this line too), else nil. Shared by DeleteFieldBlock and
-- CommitReparentField's removal-from-old-location step - both leave an
-- orphaned `fields:` key behind in exactly the same shape.
local function DetectOrphanedFieldsKey(lines, item_indent, block_start, block_end)
  local candidate = block_start - 1
  if lines[candidate] and lines[candidate]:match("^%s*fields%s*:%s*$") then
    local candidate_indent = #(lines[candidate]:match("^(%s*)") or "")
    if candidate_indent == item_indent - 2 then
      local next_line = lines[block_end + 1]
      local has_next_sibling = next_line and next_line:match("^%s*%-") and
        #(next_line:match("^(%s*)") or "") == item_indent
      if not has_next_sibling then
        return candidate
      end
    end
  end
  return nil
end

-- Removes `field`'s entire block (its own properties AND its whole nested
-- subtree) from the file - one read, one in-memory splice, one write, per
-- the project's established "never touch the file more than once per
-- commit" philosophy.
--
-- If this was the ONLY child in its parent's `fields:` array, also removes
-- that now-orphaned `fields:` key. This is NOT cosmetic: confirmed directly
-- against the real YAML parser that a `fields:` key with nothing indented
-- under it fails to parse ("unexpected token 'dedent'") whenever anything
-- follows at shallower-or-equal indentation - which is always the case
-- here, since `fields:` is always the last line emitted for a field (see
-- SerializeNewFieldBlock).
function M.DeleteFieldBlock(source_path, field)
  if not Editor.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    local lines = Editor.ReadRawLines(source_path)
    if not lines then error("Could not read scheme file.") end

    local item_indent, block_start, block_end, err = ReverifyField(lines, field)
    if err then error(err) end

    local fields_key_line = DetectOrphanedFieldsKey(lines, item_indent, block_start, block_end)

    for i = block_end, block_start, -1 do
      table.remove(lines, i)
    end
    if fields_key_line then
      table.remove(lines, fields_key_line)
    end

    local content = table.concat(lines, "\n")
    local f = assert(io.open(source_path, "wb"))
    f:write(content)
    f:close()
  end)

  if not ok then
    return false, tostring(result)
  end
  return true
end

-- Orchestration: deletes `field` and returns ok, err, reload_requests - an
-- empty array again, same as CommitCreateField (nothing to reselect after
-- a delete; EnsureLayout already clears the inspector's selection on any reload).
function M.CommitDeleteField(source_path, field)
  if not source_path then return false, "No scheme file path available." end

  local ok, err = M.DeleteFieldBlock(source_path, field)
  if not ok then return false, err end

  return true, nil, {}
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~ REORDER ~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Swaps `field` with its adjacent sibling in `direction` (-1 = up, +1 =
-- down) within `siblings` (either top_level_fields or a parent's
-- `.fields`). True siblings always share the same item_indent (dashes in
-- one YAML sequence share one indent by definition), so this is a pure
-- block swap - no re-indentation needed, unlike reparenting.
function M.CommitMoveFieldBlock(source_path, siblings, field, direction)
  if not source_path then return false, "No scheme file path available." end

  local index = nil
  for i, f in ipairs(siblings) do
    if f == field then index = i; break end
  end
  if not index then return false, "Could not find this field among its siblings." end

  local target_index = index + direction
  if target_index < 1 or target_index > #siblings then
    return false, "Cannot move further in that direction."
  end
  local target_field = siblings[target_index]

  local lines = Editor.ReadRawLines(source_path)
  if not lines then return false, "Could not read scheme file." end

  local _, fbs, fbe, ferr = ReverifyField(lines, field)
  if ferr then return false, ferr end
  local _, tbs, tbe, terr = ReverifyField(lines, target_field)
  if terr then return false, terr end

  -- Re-verified line numbers, not array order, decide which block is
  -- actually first in the file.
  local earlier_start, earlier_end, later_start, later_end
  if fbs < tbs then
    earlier_start, earlier_end, later_start, later_end = fbs, fbe, tbs, tbe
  else
    earlier_start, earlier_end, later_start, later_end = tbs, tbe, fbs, fbe
  end

  local earlier_block = { table.unpack(lines, earlier_start, earlier_end) }
  local gap = { table.unpack(lines, earlier_end + 1, later_start - 1) }
  local later_block = { table.unpack(lines, later_start, later_end) }

  if not Editor.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    local swapped = {}
    for _, l in ipairs(later_block) do swapped[#swapped + 1] = l end
    for _, l in ipairs(gap) do swapped[#swapped + 1] = l end
    for _, l in ipairs(earlier_block) do swapped[#swapped + 1] = l end

    for i = later_end, earlier_start, -1 do
      table.remove(lines, i)
    end
    for i, l in ipairs(swapped) do
      table.insert(lines, earlier_start - 1 + i, l)
    end

    local content = table.concat(lines, "\n")
    local f = assert(io.open(source_path, "wb"))
    f:write(content)
    f:close()
  end)
  if not ok then return false, tostring(result) end
  return true, nil, {}
end

-- Moves `field` to sit immediately after `ref_field`, both already in
-- `siblings` (the same parent's list) - a generalization of
-- CommitMoveFieldBlock from "swap two ADJACENT blocks" to "extract one
-- block and reinsert it anywhere else in the same list". No reindentation
-- needed (true siblings always share one item_indent), unlike reparenting.
-- Used by the Visual Editor's drag-and-drop: dropping a field onto one of
-- its own current siblings reorders it to sit right after that sibling,
-- immediately, no confirmation popup (nothing about parent/id-condition is
-- changing, so there's nothing left to confirm).
function M.CommitReorderFieldTo(source_path, siblings, field, ref_field)
  if not source_path then return false, "No scheme file path available." end
  if field == ref_field then return false, "Cannot move a field after itself." end

  local lines = Editor.ReadRawLines(source_path)
  if not lines then return false, "Could not read scheme file." end

  local _, field_start, field_end, ferr = ReverifyField(lines, field)
  if ferr then return false, ferr end
  local _, ref_start, ref_end, rerr = ReverifyField(lines, ref_field)
  if rerr then return false, rerr end

  local field_lines = { table.unpack(lines, field_start, field_end) }
  local removed_count = field_end - field_start + 1

  -- If ref_field's block sits AFTER field's old position, removing field's
  -- block first shifts every later line number (including ref's) up by
  -- removed_count - if ref sits BEFORE field instead, it's untouched by
  -- that removal.
  local adj_ref_end = ref_end
  if field_start < ref_start then
    adj_ref_end = ref_end - removed_count
  end

  if not Editor.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    for i = field_end, field_start, -1 do
      table.remove(lines, i)
    end
    local insert_at = adj_ref_end + 1
    for i, l in ipairs(field_lines) do
      table.insert(lines, insert_at - 1 + i, l)
    end

    local content = table.concat(lines, "\n")
    local f = assert(io.open(source_path, "wb"))
    f:write(content)
    f:close()
  end)
  if not ok then return false, tostring(result) end
  return true, nil, {}
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~ REPARENT ~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Does `root`'s subtree contain `candidate` (by reference, at any depth,
-- not including `root` itself)? Used to refuse moving a field into itself
-- or into one of its own descendants - either would corrupt the file (you'd
-- be nesting a block inside a piece of itself that's simultaneously being
-- removed from that same location).
function M.ContainsField(root, candidate)
  if not root.fields then return false end
  for _, child in ipairs(root.fields) do
    if child == candidate or M.ContainsField(child, candidate) then
      return true
    end
  end
  return false
end

-- Rewrites the block's header (its first 1-2 lines: the `- id: X` / `field:
-- Y` pair, or a bare `- field: Y`) to reflect `new_id_value`, given the
-- block has ALREADY been reindented to `pad_item`/`pad_prop` (item_indent
-- and item_indent+2, respectively). `had_id` says whether the ORIGINAL
-- block had an id line. Returns the new header lines (1 or 2) and how many
-- of the original (already-reindented) lines they replace (also 1 or 2) -
-- the caller splices these in place of that many lines at the front of the
-- block, leaving everything after the header (remaining own properties,
-- any nested `fields:` + descendants) completely untouched.
local function RewriteBlockHeaderForReparent(reindented_lines, had_id, new_id_value, pad_item, pad_prop, style)
  local label_line = had_id and reindented_lines[2] or reindented_lines[1]
  local label = label_line:match("field%s*:%s*(.-)%s*$")

  if new_id_value == nil then
    -- Moving to a context with no id condition (top-level, or a plain
    -- append under a parent that doesn't filter by id).
    return { pad_item .. "- field: " .. label }, had_id and 2 or 1
  end

  local id_tok, ierr = SerializeIdValue(new_id_value, style)
  if not id_tok then return nil, ierr end
  return { pad_item .. "- id: " .. id_tok, pad_prop .. "field: " .. label }, had_id and 2 or 1
end

-- Moves `field` (and its whole nested subtree) to a new location - either
-- under a different parent, to/from top-level, or from top-level into a
-- parent. `target` reuses InsertFieldBlock's exact target shapes
-- (`{kind="top_level_append"}` / `{kind="child_append", parent_field=...}`);
-- `new_id_value` is the id condition to assign under the new parent (nil
-- for top-level, or a parent that doesn't filter by id).
--
-- Every line in the subtree is reindented by a uniform delta (new minus old
-- item_indent) - safe because every property/child line in a field's block
-- is, by construction, indented MORE than its own dash (see
-- FindFieldBlockRange's comment), so shifting all of them by the same
-- amount preserves the whole subtree's relative structure. Only the
-- header (id/field line(s)) is regenerated; everything else - remaining
-- own properties, nested `fields:`, every descendant - is preserved
-- byte-for-byte, just reindented, never regenerated.
function M.CommitReparentField(source_path, top_level_fields, field, target, new_id_value)
  if not source_path then return false, "No scheme file path available." end

  if target.kind == "child_append" or target.kind == "child_after" then
    local parent = target.parent_field
    if parent == field or M.ContainsField(field, parent) then
      return false, "Cannot move a field into itself or one of its own descendants."
    end
    if type(parent.value) ~= "table" and type(parent.value) ~= "boolean" then
      return false, "Only dropdown or checkbox fields can have conditional children."
    end
    for _, c in ipairs(parent.fields or {}) do
      if c == field then
        return false, "This field is already under that parent - use Edit Field... to change its id-condition instead."
      end
    end
  end

  local lines = Editor.ReadRawLines(source_path)
  if not lines then return false, "Could not read scheme file." end

  local old_item_indent, block_start, block_end, ferr = ReverifyField(lines, field)
  if ferr then return false, ferr end

  local insert_after_line, new_item_indent, fields_key_insert_line, fields_key_indent

  if target.kind == "top_level_append" or target.kind == "top_level_after" then
    local anchor = target.ref_field or top_level_fields[#top_level_fields]
    if not anchor or anchor == field then
      return false, "This scheme has no other top-level fields to anchor the move after."
    end
    local ii, _, be, aerr = ReverifyField(lines, anchor)
    if aerr then return false, aerr end
    new_item_indent, insert_after_line = ii, be

  else -- "child_append" / "child_after"
    local parent = target.parent_field
    local pii, _, pbe, perr = ReverifyField(lines, parent)
    if perr then return false, perr end

    -- `field` is never already among parent.fields here (guarded above), so
    -- a non-empty list always means a `fields:` key genuinely already
    -- exists on disk under this DIFFERENT parent - safe to anchor after its
    -- last real child without any risk of duplicating that key.
    if parent.fields and #parent.fields > 0 then
      local last_child = target.ref_field or parent.fields[#parent.fields]
      local ii, _, be, cerr = ReverifyField(lines, last_child)
      if cerr then return false, cerr end
      new_item_indent, insert_after_line = ii, be
    else
      fields_key_indent = pii + 2
      fields_key_insert_line = pbe + 1
      new_item_indent = pii + 4
    end
  end

  local had_id = field.id ~= nil
  local style = { quote_char = DetectPrevailingListStyle(lines, block_start) }
  local delta = new_item_indent - old_item_indent
  local pad_item = string.rep(" ", new_item_indent)
  local pad_prop = string.rep(" ", new_item_indent + 2)

  local reindented = {}
  for i = block_start, block_end do
    local line = lines[i]
    if line:match("%S") then
      if delta >= 0 then
        reindented[#reindented + 1] = string.rep(" ", delta) .. line
      else
        local stripped = line:match("^" .. string.rep(" ", -delta) .. "(.*)$")
        if not stripped then return false, "Could not reindent this field's subtree for the new location." end
        reindented[#reindented + 1] = stripped
      end
    else
      reindented[#reindented + 1] = line
    end
  end

  local header_lines, herr = RewriteBlockHeaderForReparent(reindented, had_id, new_id_value, pad_item, pad_prop, style)
  if not header_lines then return false, herr end
  local consumed = had_id and 2 or 1
  local new_block = {}
  for _, l in ipairs(header_lines) do new_block[#new_block + 1] = l end
  for i = consumed + 1, #reindented do new_block[#new_block + 1] = reindented[i] end

  local orphaned_fields_key = DetectOrphanedFieldsKey(lines, old_item_indent, block_start, block_end)

  if not Editor.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  -- Exactly one of these two is ever set (the "existing children" branch
  -- sets insert_after_line; the "needs a brand new fields: key" branch
  -- sets fields_key_insert_line instead) - unify them into one anchor line
  -- number so the ordering check below has a real number to compare
  -- against either way. Comparing directly against insert_after_line alone
  -- crashed ("attempt to compare nil with number") whenever the target
  -- parent had no existing children yet, since insert_after_line stays nil
  -- in exactly that case - a real bug, not covered by any existing test
  -- fixture (every prior reparent test happened to target a parent that
  -- already had at least one child).
  local anchor_line = insert_after_line or fields_key_insert_line

  local ok, result = pcall(function()
    -- Remove the old block (and its now-orphaned `fields:` key, if any)
    -- FIRST if it sits AFTER the insertion point, so removing it doesn't
    -- shift the insertion point's line number out from under us; insert
    -- first if the old block sits BEFORE the insertion point instead.
    if block_start > anchor_line then
      for i = block_end, block_start, -1 do table.remove(lines, i) end
      if orphaned_fields_key then table.remove(lines, orphaned_fields_key) end

      if fields_key_insert_line then
        table.insert(lines, fields_key_insert_line, string.rep(" ", fields_key_indent) .. "fields:")
        insert_after_line = fields_key_insert_line
      end
      for i, l in ipairs(new_block) do
        table.insert(lines, insert_after_line + i, l)
      end
    else
      if fields_key_insert_line then
        table.insert(lines, fields_key_insert_line, string.rep(" ", fields_key_indent) .. "fields:")
        insert_after_line = fields_key_insert_line
      end
      for i, l in ipairs(new_block) do
        table.insert(lines, insert_after_line + i, l)
      end

      for i = block_end, block_start, -1 do table.remove(lines, i) end
      if orphaned_fields_key then table.remove(lines, orphaned_fields_key) end
    end

    local content = table.concat(lines, "\n")
    local f = assert(io.open(source_path, "wb"))
    f:write(content)
    f:close()
  end)
  if not ok then return false, tostring(result) end
  return true, nil, {}
end

-- Proxies for SchemeEditor's undo stack, so SchemeStructureEditorGui.lua
-- doesn't need its own separate dependency on SchemeEditor (it already
-- depends on this module) - "undo" is conceptually part of structure
-- editing, even though the snapshot storage lives in SchemeEditor.lua for
-- adjacency to BackupSchemeFile's identical directory/session-state logic.
function M.HasUndo()
  return Editor.HasUndo()
end

function M.PopUndoSnapshot()
  return Editor.PopUndoSnapshot()
end

-- Proxies for SchemeEditor's wildcard-management functions - same rationale
-- as the undo proxies above: SchemeStructureEditorGui.lua only ever depends
-- on this module, not SchemeEditor.lua directly.
function M.ListWildcardDefinitions(source_path)
  return Editor.ListWildcardDefinitions(source_path)
end

function M.CommitEditWildcardList(source_path, name, new_items)
  return Editor.CommitEditWildcardList(source_path, name, new_items)
end

function M.CommitEditWildcardScalar(source_path, name, new_value)
  return Editor.CommitEditWildcardScalar(source_path, name, new_value)
end

function M.CommitRenameWildcard(source_path, old_name, new_name)
  return Editor.CommitRenameWildcard(source_path, old_name, new_name)
end

function M.CommitDeleteWildcard(source_path, name)
  return Editor.CommitDeleteWildcard(source_path, name)
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~ ORCHESTRATION ~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Phase-1 orchestration: validates, inserts, and returns ok, err,
-- reload_requests. reload_requests is always an EMPTY array (not nil) on
-- success - nothing was previously selected to restore (this is a create,
-- not an edit of something existing), but a non-nil array is still what
-- the caller's existing convention uses to trigger the mandatory reload
-- that makes the new field actually show up.
function M.CommitCreateField(source_path, top_level_fields, target, field_spec)
  if not source_path then return false, "No scheme file path available." end

  local is_child = (target.kind == "child_append" or target.kind == "child_after")
  local vok, verr = ValidateFieldSpec(field_spec, is_child)
  if not vok then return false, verr end

  local iok, ierr = M.InsertFieldBlock(source_path, top_level_fields, target, field_spec)
  if not iok then return false, ierr end

  return true, nil, {}
end

return M
