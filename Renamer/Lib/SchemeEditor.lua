-- @noindex
-- SchemeEditor: pure logic + file I/O for locating and rewriting dropdown
-- option lists inside a scheme .yaml file, without touching any other byte
-- of the file (no reaper.ImGui_* calls here, and no reference to the main
-- script's `wgt` state - see SchemeEditorGui.lua for the GUI-facing half).

local M = {}

local backed_up_paths = {}
local config = { backups_dir = nil, sep = nil, dir_exists = nil, msg = nil }

local undo_stack = {}
local MAX_UNDO_DEPTH = 20

function M.init(opts)
  config.backups_dir = opts.backups_dir
  config.sep         = opts.sep
  config.dir_exists  = opts.dir_exists
  config.msg         = opts.msg
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~ SCHEME SOURCE LOCATIONS ~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Locates, in the raw scheme .yaml file on disk, the exact line of each
-- field's `value:`/`short:` inline list, so the GUI's context menus can
-- append/reorder entries there without disturbing the rest of the file.

-- Exported: reused by SchemeStructureEditor.lua for locating/re-verifying
-- field blocks, not just this file's own line-level lookups.
function M.EscapePattern(s)
  return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
end

function M.ReadRawLines(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*all")
  f:close()
  local lines = {}
  for l in (content .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    lines[#lines + 1] = l
  end
  return lines
end
local EscapePattern = M.EscapePattern
local ReadRawLines  = M.ReadRawLines

-- Parse a single-line inline list "key: [ 'a', 'b', c ]" into an array of
-- unquoted string values, or nil if this line isn't a single-line flow list.
local function ParseInlineListLine(line, key)
  local body = line:match("^%s*" .. key .. "%s*:%s*%[(.-)%]%s*$")
  if not body then return nil end
  local items = {}
  for item in (body .. ","):gmatch("(.-),") do
    item = item:match("^%s*(.-)%s*$")
    if item ~= "" then
      items[#items + 1] = item:match("^'(.*)'$") or item:match('^"(.*)"$') or item
    end
  end
  return items
end

local function ListsEqual(a, b)
  if not a or not b or #a ~= #b then return false end
  for i = 1, #a do
    if tostring(a[i]) ~= tostring(b[i]) then return false end
  end
  return true
end

local function FindForward(lines, from, field_name)
  local pattern = "field%s*:%s*['\"]?" .. EscapePattern(field_name) .. "['\"]?%s*$"
  for i = from, #lines do
    if lines[i]:match(pattern) then return i end
  end
  return nil
end

-- Scan forward from `from` for a `key: [...]` line whose parsed content
-- exactly matches `expected`, bounded to the same YAML mapping as the
-- `field:` line at `field_line` (stops at a dedent, a new "- " sibling
-- entry, or another `field:` key, whichever comes first).
local function FindMatchingListLine(lines, from, field_line, key, expected)
  local field_indent = #(lines[field_line]:match("^(%s*)") or "")
  for i = from, #lines do
    local line = lines[i]
    if line:match("%S") then
      local indent = #(line:match("^(%s*)") or "")
      if indent < field_indent then break end
      if indent == field_indent and (line:match("^%s*%-") or line:match("^%s*field%s*:")) then break end
    end
    local parsed = ParseInlineListLine(line, key)
    if parsed and ListsEqual(parsed, expected) then return i end
  end
  return nil
end

-- Scan forward from `from` (bounded exactly like FindMatchingListLine) for a
-- "`key`: $name" line - a reference to a top-level "$name: [...]" wildcard
-- definition elsewhere in the file, substituted textually before parsing
-- (see acendan.loadYaml's "Replace $wildcards" pass). Returns the wildcard
-- name (without the leading $), or nil.
local function FindWildcardRef(lines, from, field_line, key)
  local field_indent = #(lines[field_line]:match("^(%s*)") or "")
  for i = from, #lines do
    local line = lines[i]
    if line:match("%S") then
      local indent = #(line:match("^(%s*)") or "")
      if indent < field_indent then break end
      if indent == field_indent and (line:match("^%s*%-") or line:match("^%s*field%s*:")) then break end
    end
    local name = line:match("^%s*" .. key .. "%s*:%s*%$([%w_]+)%s*$")
    if name then return name end
  end
  return nil
end

-- Find the single top-level "$name: [ ... ]" definition line anywhere in the
-- file (wildcard definitions live wherever they're declared, typically near
-- the top - not bounded to any field's block) whose parsed content matches
-- `expected`, as a safety check against a stale/tampered file.
local function FindWildcardDefinitionLine(lines, name, expected)
  local key_pattern = "%$" .. EscapePattern(name)
  for i = 1, #lines do
    local parsed = ParseInlineListLine(lines[i], key_pattern)
    if parsed and ListsEqual(parsed, expected) then return i end
  end
  return nil
end

-- Given a field's already-located primary line (via FindForward), finds its
-- own YAML sequence-item dash line and the full line range of its block -
-- its own remaining properties, its own `fields:` key if any, and its
-- entire nested descendant subtree. Two shapes occur in this schema:
-- either the field's own line IS the dash line ("- field: X"), or the dash
-- is one line up and one indent level shallower, fused with a preceding
-- `id:` ("- id: Y" / "field: X" on the next line - scanned backward rather
-- than assumed to be always exactly one line up, in case a field is ever
-- hand-authored with an unusual property order).
--
-- The block's end is the last line before the next line at indent <= the
-- dash's own indent ("item_indent"). This is simpler than it looks: every
-- property/child belonging to this entry is necessarily indented MORE than
-- its own dash (entering a nested `fields:` array only ever adds
-- indentation, never returns to a shallower level within the same entry),
-- while the next sibling's dash is always exactly at item_indent (dashes
-- in one YAML sequence share one indent by definition) - so a plain
-- `indent <= item_indent` check finds the boundary with no need for the
-- dash-vs-field-key disambiguation FindMatchingListLine needs (that
-- function searches *within* one field's own props using the field-line's
-- raw indent, a narrower and more ambiguous problem than finding this
-- entry's own outer boundary).
--
-- Returns item_indent, block_start_line, block_end_line, or nil if the
-- dash line can't be confidently located.
local function FindFieldBlockRange(lines, field_line)
  local field_line_indent = #(lines[field_line]:match("^(%s*)") or "")
  local block_start_line, item_indent

  if lines[field_line]:match("^%s*%-") then
    block_start_line, item_indent = field_line, field_line_indent
  else
    for i = field_line - 1, 1, -1 do
      local indent = #(lines[i]:match("^(%s*)") or "")
      if lines[i]:match("^%s*%-") and indent == field_line_indent - 2 then
        block_start_line, item_indent = i, indent
        break
      end
      if indent < field_line_indent - 2 then break end
    end
    if not block_start_line then return nil end
  end

  local block_end_line = #lines
  for i = block_start_line + 1, #lines do
    if lines[i]:match("%S") then
      if #(lines[i]:match("^(%s*)") or "") <= item_indent then
        block_end_line = i - 1
        break
      end
    end
  end
  while block_end_line > block_start_line and not lines[block_end_line]:match("%S") do
    block_end_line = block_end_line - 1
  end

  return item_indent, block_start_line, block_end_line
end
M.FindFieldBlockRange = FindFieldBlockRange

-- Walks `fields` in the same depth-first, document order as the GUI's field
-- renderer, attaching field.__value_line / field.__short_line (1-based line
-- numbers in the raw file) wherever a confident match is found. A field
-- whose value is a `$wildcard` reference resolves to the shared wildcard
-- definition's line instead (and gets field.__wildcard_key set, so the GUI
-- can warn that edits there affect every field sharing that definition).
-- Fields that can't be confidently located (multi-line lists, etc) are
-- simply left without a location, disabling their context menu.
--
-- Multiple fields resolving to the *same* line (only possible via a shared
-- wildcard) each get field.__shared_fields set to the list of sibling field
-- objects on that line, so add/reorder operations can re-resolve every
-- affected field's selection, not just the one the user directly edited.
function M.AttachSourceLocations(fields, path)
  local lines = ReadRawLines(path)
  if not lines then return end
  local cursor = 1
  local by_line = {}
  local function walk(list)
    for _, field in ipairs(list) do
      local field_line = FindForward(lines, cursor, field.field)
      if field_line then
        field.__field_line = field_line
        local item_indent, block_start, block_end = FindFieldBlockRange(lines, field_line)
        if item_indent then
          field.__item_indent, field.__block_start_line, field.__block_end_line = item_indent, block_start, block_end
        end
        -- A child field's `id:` can itself be a $wildcard reference (e.g.
        -- Example.yaml's Headquarters: `id: $countries`), substituted to a
        -- literal list before parsing just like a wildcard `value:` - flag
        -- it the same way, so anything regenerating this field's `id:`
        -- line (the structural edit form) knows not to silently flatten
        -- the reference into a literal copy.
        if field.id ~= nil and block_start and lines[block_start] then
          local wc_name = lines[block_start]:match("^%s*%-%s*id%s*:%s*%$([%w_]+)%s*$")
          if wc_name then
            field.__id_wildcard_key = wc_name
          end
        end
        cursor = field_line + 1
        if type(field.value) == "table" then
          field.__value_line = FindMatchingListLine(lines, cursor, field_line, "value", field.value)
          if not field.__value_line then
            local wc_name = FindWildcardRef(lines, cursor, field_line, "value")
            if wc_name then
              local def_line = FindWildcardDefinitionLine(lines, wc_name, field.value)
              if def_line then
                field.__value_line = def_line
                field.__wildcard_key = wc_name
              end
            end
          end
          if field.short then
            field.__short_line = FindMatchingListLine(lines, cursor, field_line, "short", field.short)
          end
        end
        cursor = math.max(cursor, (field.__value_line or field_line) + 1, (field.__short_line or field_line) + 1)
        if field.__value_line then
          by_line[field.__value_line] = by_line[field.__value_line] or {}
          table.insert(by_line[field.__value_line], field)
        end
      end
      if field.fields then walk(field.fields) end
    end
  end
  walk(fields)

  for _, group in pairs(by_line) do
    if #group > 1 then
      for _, field in ipairs(group) do
        local others = {}
        for _, other in ipairs(group) do
          if other ~= field then others[#others + 1] = other end
        end
        field.__shared_fields = others
      end
    end
  end
end

-- Walk an ordinal index chain (as stamped onto field.__path by the main
-- script's LoadFields) back down a freshly (re)loaded fields tree to find
-- "the same" field again.
function M.LookupFieldByPath(fields, path)
  local list = fields
  local field = nil
  for _, idx in ipairs(path or {}) do
    if not list then return nil end
    field = list[idx]
    if not field then return nil end
    list = field.fields
  end
  return field
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~ SCHEME WRITE-BACK ~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Rewrites a single value:/short: line to reflect a new set of items (an
-- append, for add-item, or a permutation, for reorder) - every other byte
-- of the file (comments, other fields, wildcards) is untouched.

-- Split a "[ ... ]" body into raw, still-quoted tokens (trimmed of only
-- outer whitespace), preserving each token's exact original text.
local function ParseRawTokens(body)
  local tokens = {}
  for tok in (body .. ","):gmatch("(.-),") do
    tok = tok:match("^%s*(.-)%s*$")
    if tok ~= "" then tokens[#tokens + 1] = tok end
  end
  return tokens
end

local function UnquoteToken(tok)
  return tok:match("^'(.*)'$") or tok:match('^"(.*)"$') or tok
end

-- Given a value and the quoting convention to use, return a safely-quoted
-- (or bare, if safe) YAML token. `quote_char` (the file's detected
-- LIST-ITEM quoting convention, e.g. UCS.yaml's single-quotes) only forces
-- quoting when `for_list_item` is true - it has no bearing on standalone
-- scalars (field/id labels, a bare `value:`), which are a different,
-- unrelated stylistic axis (every field label in UCS.yaml is bare even
-- though its list items are single-quoted; forcing quote_char onto labels
-- too was a real bug caught by the edit-field test suite - editing any
-- field in a single-quote-style file like UCS.yaml was quoting its label
-- unnecessarily, e.g. `- field: 'Category'` instead of `- field: Category`).
-- Otherwise, quote only if the value would be unsafe left bare.
-- `for_list_item` narrows/widens which characters count as unsafe:
--   - A standalone scalar (a field/id label, or a bare `value:`) is safe
--     with embedded spaces (e.g. "A Useful Prefix", "Is SFX?" are bare in
--     the real corpus) - it only needs quoting for chars that would break
--     key:value parsing (a leading/embedded `:`) or a few flow-list-unsafe
--     characters, in case it's later re-read back into a list context.
--   - An item inside an inline [ ... ] flow list is comma-delimited, and
--     this codebase's vendored YAML parser (Lib/yaml.lua) cannot parse an
--     unquoted item containing ANY whitespace, not just leading/trailing
--     (confirmed by reproducing "expected comma" against the real parser
--     with a bare multi-word item) - every existing multi-word list item
--     in the real scheme corpus is quoted for exactly this reason (e.g.
--     'Non-Player Character', 'User Interface', 'Dirt & Sand'); single-word
--     items are bare. This shipped as a real bug once already (a live user
--     hit the "expected comma" parser error creating a dropdown with a
--     multi-word option) before this whitespace check existed.
-- Exported: shared by SerializeListLine (list items) and
-- SchemeStructureEditor.lua's new-field serializer (labels/ids/scalars).
function M.QuoteBareToken(val, quote_char, for_list_item)
  val = tostring(val)
  if for_list_item and quote_char then
    if val:find(quote_char, 1, true) then
      return nil, "Value cannot contain the " .. quote_char .. " character used to quote this list."
    end
    return quote_char .. val .. quote_char
  end
  if for_list_item then
    if val == "" or val:match("[,%[%]#]") or val:match("%s") or val:match("^['\"]") then
      return "'" .. val .. "'"
    end
  else
    if val == "" or val:match("[,%[%]#:]") or val:match("^%s") or val:match("%s$") or val:match("^['\"]") then
      return "'" .. val .. "'"
    end
  end
  return val
end

-- Given the raw text of a "key: [ ... ]" line and the desired final array
-- of item values (in order), return a new line reflecting that array.
-- Items that already existed on the line are reused byte-for-byte (so a
-- pure reorder changes only ordering/commas, never an item's own text);
-- genuinely new items are freshly quoted to match the line's existing
-- convention. Returns nil, error if the line isn't a supported single-line
-- inline list, or if a new item is incompatible with the line's quoting.
function M.SerializeListLine(line, items)
  local indent, key, gap, body, tail = line:match("^(%s*)([%$%a][%w_]*:)(%s*)%[(.-)%](%s*)$")
  if not body then
    return nil, "Unsupported line format (not a single-line [ ... ] list)."
  end

  local by_value = {}
  for _, tok in ipairs(ParseRawTokens(body)) do
    local val = UnquoteToken(tok)
    by_value[val] = by_value[val] or {}
    table.insert(by_value[val], tok)
  end

  local first_item = body:match("^%s*([^,]+)")
  local quote_char = first_item and first_item:match("^%s*(['\"])") or nil

  local out = {}
  for _, item in ipairs(items) do
    local val = tostring(item)
    local queue = by_value[val]
    if queue and #queue > 0 then
      out[#out + 1] = table.remove(queue, 1)
    else
      local serialized, qerr = M.QuoteBareToken(val, quote_char, true)
      if not serialized then
        return nil, "New item cannot contain the " .. quote_char .. " character used to quote this list."
      end
      out[#out + 1] = serialized
    end
  end

  return indent .. key .. gap .. "[" .. table.concat(out, ", ") .. "]" .. tail
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~ WILDCARD MANAGEMENT ~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- $name definitions are file-level, not attached to any one field - unlike
-- everything above (which locates ONE field's own lines), these operate on
-- the whole file: discovering every "$name: ..." definition, finding every
-- OTHER line that references one, and renaming/deleting/editing them.
--
-- Discovery is deliberately anchored the same way the real substitution
-- pass is (see the main script's loadYaml: `line:sub(1,1) == "$"`) - a
-- wildcard definition has NO leading whitespace, confirmed against the only
-- real scheme that uses them (Example.yaml's `$bodyHint`/`$countries` sit
-- at column 0, siblings of `title:`/`separator:`, not nested under `fields:`).

-- Every "$name: ..." definition line in the file, in file order. `is_list`
-- distinguishes a "$name: [ ... ]" wildcard (parsed into `items`) from a
-- scalar one (kept as raw, unparsed `raw_value` text - e.g. `$bodyHint`'s
-- plain sentence). Used both by the "Manage Wildcards" popup and by
-- SchemeStructureEditor's extract-to-wildcard (to check a chosen name isn't
-- already taken).
function M.ListWildcardDefinitions(source_path)
  local lines = ReadRawLines(source_path)
  if not lines then return {} end
  local defs = {}
  for i, line in ipairs(lines) do
    if line:sub(1, 1) == "$" then
      local name = line:match("^%$([%w_]+)%s*:")
      if name then
        local items = ParseInlineListLine(line, "%$" .. EscapePattern(name))
        if items then
          defs[#defs + 1] = { name = name, line = i, is_list = true, items = items }
        else
          local raw_value = line:match("^%$[%w_]+%s*:%s*(.*)$")
          defs[#defs + 1] = { name = name, line = i, is_list = false, raw_value = raw_value or "" }
        end
      end
    end
  end
  return defs
end

-- Every line (other than a "$name: ..." definition line itself) that
-- references $name - not just `value:`/`id:`, since the real substitution
-- pass is a blind textual replace that can hit ANY scalar property (see
-- SchemeStructureEditor's ReplaceFieldProperties, which discovered
-- Example.yaml's `hint: $bodyHint`). The trailing `%f[%W]` frontier is a
-- zero-width assertion (matches a position, consumes no characters) so a
-- search for "$countries" doesn't false-positive on some other, longer
-- name that happens to share that prefix (e.g. "$countriesExtra").
function M.FindWildcardUsageLines(lines, name)
  local pattern = "%$" .. EscapePattern(name) .. "%f[%W]"
  local usages = {}
  for i, line in ipairs(lines) do
    if not (line:sub(1, 1) == "$" and line:match("^%$" .. EscapePattern(name) .. "%s*:")) then
      if line:find(pattern) then
        usages[#usages + 1] = i
      end
    end
  end
  return usages
end

-- Re-finds `$name`'s own definition line fresh (never trusts a cached line
-- number), or nil, err if it no longer looks like a wildcard definition.
local function FindWildcardDefLineNow(lines, name)
  for i, line in ipairs(lines) do
    if line:sub(1, 1) == "$" and line:match("^%$" .. EscapePattern(name) .. "%s*:") then
      return i
    end
  end
  return nil, "Could not find $" .. name .. "'s definition. Please reload the scheme and try again."
end

-- Rewrites $name's own "[ ... ]" definition line to reflect `new_items`,
-- exactly like WriteSchemeList does for a field's own list - reuses
-- SerializeListLine so existing items keep their original quoting/text and
-- only genuinely new ones are freshly quoted.
function M.CommitEditWildcardList(source_path, name, new_items)
  local lines = ReadRawLines(source_path)
  if not lines then return false, "Could not read scheme file." end

  local def_line, ferr = FindWildcardDefLineNow(lines, name)
  if not def_line then return false, ferr end

  local new_line, serr = M.SerializeListLine(lines[def_line], new_items)
  if not new_line then return false, serr end

  if not M.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    lines[def_line] = new_line
    local f = assert(io.open(source_path, "wb"))
    f:write(table.concat(lines, "\n"))
    f:close()
  end)
  if not ok then return false, tostring(result) end
  return true
end

-- Rewrites $name's own scalar definition line to `new_value`, using the
-- same bare-vs-quoted scalar convention as a field's own value/label
-- (QuoteBareToken with for_list_item=false) - e.g. Example.yaml's
-- `$bodyHint: I Am A Good Filename` is entirely bare despite the spaces,
-- because none of its characters are actually unsafe left bare.
function M.CommitEditWildcardScalar(source_path, name, new_value)
  local lines = ReadRawLines(source_path)
  if not lines then return false, "Could not read scheme file." end

  local def_line, ferr = FindWildcardDefLineNow(lines, name)
  if not def_line then return false, ferr end

  local val_tok, verr = M.QuoteBareToken(new_value or "", nil, false)
  if not val_tok then return false, verr end
  local new_line = "$" .. name .. ": " .. val_tok

  if not M.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    lines[def_line] = new_line
    local f = assert(io.open(source_path, "wb"))
    f:write(table.concat(lines, "\n"))
    f:close()
  end)
  if not ok then return false, tostring(result) end
  return true
end

-- Renames $old_name to $new_name everywhere: its own definition line AND
-- every usage site found by FindWildcardUsageLines, in one read/write pair.
-- Each affected line is rewritten with a single gsub using the same
-- frontier-bounded pattern as FindWildcardUsageLines - since the frontier
-- assertion consumes no characters, the matched (and replaced) text is
-- exactly "$old_name", leaving anything that follows on the line untouched.
function M.CommitRenameWildcard(source_path, old_name, new_name)
  if not new_name or new_name:match("^%s*$") then
    return false, "New name cannot be blank."
  end
  if not new_name:match("^[%w_]+$") then
    return false, "Wildcard names can only contain letters, numbers, and underscores."
  end
  if new_name == old_name then
    return false, "That's already this wildcard's name."
  end

  local lines = ReadRawLines(source_path)
  if not lines then return false, "Could not read scheme file." end

  local def_line, ferr = FindWildcardDefLineNow(lines, old_name)
  if not def_line then return false, ferr end

  for _, def in ipairs(M.ListWildcardDefinitions(source_path)) do
    if def.name == new_name then
      return false, "A wildcard named $" .. new_name .. " already exists."
    end
  end

  local usage_lines = M.FindWildcardUsageLines(lines, old_name)

  if not M.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    local pattern = "%$" .. EscapePattern(old_name) .. "%f[%W]"
    local replacement = "$" .. new_name
    lines[def_line] = lines[def_line]:gsub(pattern, replacement)
    for _, i in ipairs(usage_lines) do
      lines[i] = lines[i]:gsub(pattern, replacement)
    end
    local f = assert(io.open(source_path, "wb"))
    f:write(table.concat(lines, "\n"))
    f:close()
  end)
  if not ok then return false, tostring(result) end
  return true
end

-- Deletes $name's definition line entirely - refuses (no backup taken, no
-- change made) if anything still references it, since removing a still-used
-- wildcard would silently turn every reference into a literal, unresolved
-- "$name" string once the substitution pass no longer finds a definition.
function M.CommitDeleteWildcard(source_path, name)
  local lines = ReadRawLines(source_path)
  if not lines then return false, "Could not read scheme file." end

  local def_line, ferr = FindWildcardDefLineNow(lines, name)
  if not def_line then return false, ferr end

  local usage_lines = M.FindWildcardUsageLines(lines, name)
  if #usage_lines > 0 then
    return false, "$" .. name .. " is still used by " .. #usage_lines ..
      " line(s) in this file. Remove or edit those references first."
  end

  if not M.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    table.remove(lines, def_line)
    local f = assert(io.open(source_path, "wb"))
    f:write(table.concat(lines, "\n"))
    f:close()
  end)
  if not ok then return false, tostring(result) end
  return true
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~ ROOT SETTINGS MANAGEMENT ~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- The scheme's root-level keys (separator/illegal/find/replace/maxchars/
-- dupes - see the wiki's "Root" section) sit at column 0, siblings of
-- `title:`/`fields:`. Same shape as a "$name: ..." wildcard definition
-- (found above), just without the `$` prefix and - unlike a wildcard, which
-- always already exists once created - frequently absent from the file
-- entirely (most real schemes omit several of these six keys), so every
-- commit function here has to handle "insert a new line" as the common
-- case, not just "rewrite an existing line".

-- Column-0-anchored (no leading %s*) so a root key is never confused with a
-- same-named field-level key - e.g. Example.yaml has a field-local
-- `separator: " "` override nested under one of its fields.
local function FindRootKeyLineNow(lines, key)
  local pattern = "^" .. key .. "%s*:"
  for i, line in ipairs(lines) do
    if line:match(pattern) then return i end
  end
  return nil
end

-- A brand-new root key is inserted immediately before the top-level
-- `fields:` line - present at column 0 in every real scheme file, and the
-- natural boundary between root settings and the field list.
local function FindRootInsertionLine(lines)
  for i, line in ipairs(lines) do
    if line:match("^fields%s*:") then return i end
  end
  return #lines + 1
end

-- Fixed set of internal keys this module knows about - never escaped user
-- input, so FindRootKeyLineNow's pattern concatenation is safe.
local ROOT_SCALAR_KEYS = { separator = true, replace = true, maxchars = true, dupes = true }
local ROOT_LIST_KEYS   = { illegal = true, find = true }

-- Reads all six root settings fresh from disk (never relies on the parsed
-- wgt.data table) - same convention as ListWildcardDefinitions. Returns
-- { separator = { present, value }, illegal = { present, items }, ... }.
-- Scalar values are unquoted text; the GUI layer (not this one) interprets
-- maxchars as numeric and dupes as boolean, matching how the existing
-- "Number" field type keeps its own tonumber(form.num_value) conversion in
-- SchemeStructureEditorGui.lua rather than pushing it down here.
function M.ListRootSettings(source_path)
  local lines = ReadRawLines(source_path)
  local result = {}
  for key in pairs(ROOT_SCALAR_KEYS) do
    result[key] = { present = false, value = nil }
  end
  for key in pairs(ROOT_LIST_KEYS) do
    result[key] = { present = false, items = nil }
  end
  if not lines then return result end

  for key in pairs(ROOT_SCALAR_KEYS) do
    local line_no = FindRootKeyLineNow(lines, key)
    if line_no then
      local raw = lines[line_no]:match("^" .. key .. "%s*:%s*(.-)%s*$")
      result[key] = { present = true, value = raw and UnquoteToken(raw) or "" }
    end
  end
  for key in pairs(ROOT_LIST_KEYS) do
    local line_no = FindRootKeyLineNow(lines, key)
    if line_no then
      local items = ParseInlineListLine(lines[line_no], key)
      result[key] = { present = true, items = items or {} }
    end
  end
  return result
end

-- Rewrites (or, if absent, inserts before `fields:`) a root "key: value"
-- line - the root-key equivalent of CommitEditWildcardScalar. `key` must be
-- one of ROOT_SCALAR_KEYS (separator/replace/maxchars/dupes); `new_value`
-- is always passed as a string (the GUI converts dupes/maxchars via
-- tostring/string.format before calling this).
function M.CommitEditRootScalar(source_path, key, new_value)
  local lines = ReadRawLines(source_path)
  if not lines then return false, "Could not read scheme file." end

  local val_tok, verr = M.QuoteBareToken(new_value or "", nil, false)
  if not val_tok then return false, verr end
  local new_line = key .. ": " .. val_tok

  if not M.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    local line_no = FindRootKeyLineNow(lines, key)
    if line_no then
      lines[line_no] = new_line
    else
      table.insert(lines, FindRootInsertionLine(lines), new_line)
    end
    local f = assert(io.open(source_path, "wb"))
    f:write(table.concat(lines, "\n"))
    f:close()
  end)
  if not ok then return false, tostring(result) end
  return true
end

-- Rewrites (or, if absent, inserts before `fields:`) a root "key: [ ... ]"
-- line - the root-key equivalent of CommitEditWildcardList. `key` must be
-- one of ROOT_LIST_KEYS (illegal/find). When the key is absent, hands
-- SerializeListLine a synthetic "key: []" template so every item takes the
-- normal fresh-quoting path, rather than duplicating that quoting logic here.
function M.CommitEditRootList(source_path, key, new_items)
  local lines = ReadRawLines(source_path)
  if not lines then return false, "Could not read scheme file." end

  local line_no = FindRootKeyLineNow(lines, key)
  local template = line_no and lines[line_no] or (key .. ": []")
  local new_line, serr = M.SerializeListLine(template, new_items)
  if not new_line then return false, serr end

  if not M.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    if line_no then
      lines[line_no] = new_line
    else
      table.insert(lines, FindRootInsertionLine(lines), new_line)
    end
    local f = assert(io.open(source_path, "wb"))
    f:write(table.concat(lines, "\n"))
    f:close()
  end)
  if not ok then return false, tostring(result) end
  return true
end

-- Deletes a root key's line entirely - backs each row's "Clear" button,
-- restoring whatever hardcoded fallback the main script uses when the key
-- is absent (e.g. illegal's default character list). No usage-reference
-- guard like CommitDeleteWildcard needs, since root settings aren't
-- referenced by $name elsewhere in the file. No-ops (returns true) if the
-- key is already absent.
function M.CommitRemoveRootKey(source_path, key)
  local lines = ReadRawLines(source_path)
  if not lines then return false, "Could not read scheme file." end

  local line_no = FindRootKeyLineNow(lines, key)
  if not line_no then return true end

  if not M.SnapshotSchemeFile(source_path) then
    return false, "Backup failed; no changes were made."
  end

  local ok, result = pcall(function()
    table.remove(lines, line_no)
    local f = assert(io.open(source_path, "wb"))
    f:write(table.concat(lines, "\n"))
    f:close()
  end)
  if not ok then return false, tostring(result) end
  return true
end

-- Copies source_path into Backups/Schemes/ once per file per session, before
-- the first write-back to that file. A failed backup blocks the write.
function M.BackupSchemeFile(source_path)
  if backed_up_paths[source_path] then return true end

  local backup_dir = config.backups_dir .. "Schemes" .. config.sep
  if not config.dir_exists(backup_dir) then
    reaper.RecursiveCreateDirectory(backup_dir, 0)
    if not config.dir_exists(backup_dir) then
      config.msg("Error creating scheme backups directory:\n\n" .. backup_dir, "The Last Renamer")
      return false
    end
  end

  local base = source_path:match("[^/\\]+$") or "scheme.yaml"
  local backup_path = backup_dir .. base:gsub("%.yaml$", "") .. "_" .. os.date("%Y%m%d_%H%M%S") .. ".yaml"

  local ok, err = pcall(function()
    local f_in = assert(io.open(source_path, "rb"))
    local content = f_in:read("*all")
    f_in:close()
    local f_out = assert(io.open(backup_path, "wb"))
    f_out:write(content)
    f_out:close()
  end)
  if not ok then
    config.msg("Could not create a backup before editing the scheme file:\n\n" .. tostring(err) ..
      "\n\nNo changes were made.", "The Last Renamer")
    return false
  end

  backed_up_paths[source_path] = true
  return true
end

-- Always-fresh, per-write timestamped backup for structural edits (create/
-- delete/move a field block) - distinct from BackupSchemeFile's once-per-
-- session policy above, which stays as-is for the lower-risk list-edit
-- features (add item / reorder). Also pushes the same content onto the
-- in-memory undo stack, so a structural edit gets both an on-disk snapshot
-- and an in-session "Undo Last Change" available immediately.
function M.SnapshotSchemeFile(source_path)
  local backup_dir = config.backups_dir .. "Schemes" .. config.sep
  if not config.dir_exists(backup_dir) then
    reaper.RecursiveCreateDirectory(backup_dir, 0)
    if not config.dir_exists(backup_dir) then
      config.msg("Error creating scheme backups directory:\n\n" .. backup_dir, "The Last Renamer")
      return false
    end
  end

  local ok, content = pcall(function()
    local f = assert(io.open(source_path, "rb"))
    local c = f:read("*all")
    f:close()
    return c
  end)
  if not ok then
    config.msg("Could not read the scheme file before editing:\n\n" .. tostring(content), "The Last Renamer")
    return false
  end

  local base = source_path:match("[^/\\]+$") or "scheme.yaml"
  local backup_path = backup_dir .. base:gsub("%.yaml$", "") .. "_" .. os.date("%Y%m%d_%H%M%S") .. "_struct.yaml"

  local wok, werr = pcall(function()
    local f_out = assert(io.open(backup_path, "wb"))
    f_out:write(content)
    f_out:close()
  end)
  if not wok then
    config.msg("Could not create a backup before this structural edit:\n\n" .. tostring(werr) ..
      "\n\nNo changes were made.", "The Last Renamer")
    return false
  end

  M.PushUndoSnapshot(source_path, content)
  return true
end

function M.PushUndoSnapshot(source_path, content)
  undo_stack[#undo_stack + 1] = { path = source_path, content = content }
  if #undo_stack > MAX_UNDO_DEPTH then
    table.remove(undo_stack, 1)
  end
end

function M.HasUndo()
  return #undo_stack > 0
end

-- Pops and restores the most recent structural-edit snapshot (a pure
-- restore, not a redo - there is no redo stack). Returns ok, err, path -
-- the caller compares `path` against wgt.data.__scheme_path /
-- wgt.meta.__scheme_path to know which one to reload.
function M.PopUndoSnapshot()
  local entry = table.remove(undo_stack)
  if not entry then return false, "Nothing to undo." end
  local ok, err = pcall(function()
    local f = assert(io.open(entry.path, "wb"))
    f:write(entry.content)
    f:close()
  end)
  if not ok then
    return false, "Failed to restore previous version:\n\n" .. tostring(err)
  end
  return true, nil, entry.path
end

-- Rewrites a single line (by 1-based line number) of source_path to reflect
-- `items`. Backs up first; re-verifies the target line still looks like a
-- value/short list (in case the file changed on disk since it was loaded)
-- before touching anything.
function M.WriteSchemeList(source_path, line_number, items)
  if not M.BackupSchemeFile(source_path) then return false end

  local ok, result = pcall(function()
    local f = assert(io.open(source_path, "rb"))
    local content = f:read("*all")
    f:close()

    local newline = content:find("\r\n") and "\r\n" or "\n"
    local lines = {}
    for l in (content .. "\n"):gmatch("([^\r\n]*)\r?\n") do
      lines[#lines + 1] = l
    end

    local target = lines[line_number]
    if not target or not (target:match("value%s*:%s*%[") or target:match("short%s*:%s*%[") or
        target:match("^%s*%$[%w_]+%s*:%s*%[")) then
      error("Scheme file changed on disk since it was loaded. Please reload the scheme and try again.")
    end

    local new_line, serr = M.SerializeListLine(target, items)
    if not new_line then error(serr) end

    lines[line_number] = new_line
    local out = assert(io.open(source_path, "wb"))
    out:write(table.concat(lines, newline))
    out:close()
  end)

  if not ok then
    config.msg("Failed to save changes to scheme file:\n\n" .. tostring(result), "The Last Renamer")
    return false
  end
  return true
end

-- Builds the list of {path, new_value} reselection requests for a
-- just-committed edit to `field`: `field` itself reselects `primary_value`
-- (the operation's own policy - e.g. always the newly typed value, for
-- add-item), while every OTHER field sharing the same __value_line (only
-- possible via a shared $wildcard) reselects whatever it already had
-- selected, re-resolved by value, since the shared list's shape changed out
-- from under it too.
local function BuildReselectRequests(field, primary_value)
  local requests = { { path = field.__path, new_value = primary_value } }
  for _, other in ipairs(field.__shared_fields or {}) do
    local prev = other.selected and other.value[other.selected] or nil
    requests[#requests + 1] = { path = other.__path, new_value = prev }
  end
  return requests
end

-- Orchestrates an add-item request from the GUI: writes the new value (and
-- short code, if applicable) back to the scheme file. On success, returns
-- an array of {path, new_value} reselection requests describing which
-- field(s)/value(s) the caller should re-select once it reloads the scheme
-- fresh from disk (usually just `field` itself, but see BuildReselectRequests
-- for the shared-wildcard case).
function M.CommitAddItem(field, source_path, new_value, new_short)
  if not source_path or not field.__value_line then
    return false, "This option list can't be edited from the GUI (unsupported format)."
  end
  if field.short and not field.__short_line then
    return false, "Could not locate this list's short-code line in the scheme file."
  end

  local new_values = { table.unpack(field.value) }
  new_values[#new_values + 1] = new_value
  if not M.WriteSchemeList(source_path, field.__value_line, new_values) then
    return false, "Failed to save new option to the scheme file. See error above."
  end

  if field.short then
    local new_shorts = { table.unpack(field.short) }
    new_shorts[#new_shorts + 1] = new_short
    if not M.WriteSchemeList(source_path, field.__short_line, new_shorts) then
      return false, "Value was saved, but the short code failed to save. Please check the YAML file."
    end
  end

  return true, nil, BuildReselectRequests(field, new_value)
end

-- Orchestrates a move-up/move-down request: swaps item_index with
-- item_index + direction in both value and short (if present). Reselects
-- whatever was already selected before the swap (by value, not index/not
-- necessarily the moved item) - RecallSettings restores field.selected by
-- raw index from ExtState, so a shifted-but-not-moved selected item would
-- otherwise silently point at the wrong entry after reload. Returns an
-- array of {path, new_value} reselection requests - see BuildReselectRequests.
function M.CommitMoveItem(field, source_path, item_index, direction)
  if not source_path or not field.__value_line then
    return false, "This option list can't be edited from the GUI (unsupported format)."
  end
  if field.short and not field.__short_line then
    return false, "Could not locate this list's short-code line in the scheme file."
  end

  local target_index = item_index + direction
  if target_index < 1 or target_index > #field.value then
    return false, "Cannot move item further in that direction."
  end

  local reselect_value = field.selected and field.value[field.selected] or nil

  local new_values = { table.unpack(field.value) }
  new_values[item_index], new_values[target_index] = new_values[target_index], new_values[item_index]
  if not M.WriteSchemeList(source_path, field.__value_line, new_values) then
    return false, "Failed to save new order to the scheme file. See error above."
  end

  if field.short then
    local new_shorts = { table.unpack(field.short) }
    new_shorts[item_index], new_shorts[target_index] = new_shorts[target_index], new_shorts[item_index]
    if not M.WriteSchemeList(source_path, field.__short_line, new_shorts) then
      return false, "Value order was saved, but the short-code order failed to save. Please check the YAML file."
    end
  end

  return true, nil, BuildReselectRequests(field, reselect_value)
end

return M
