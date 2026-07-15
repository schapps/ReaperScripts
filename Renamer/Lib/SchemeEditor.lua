-- @noindex
-- SchemeEditor: pure logic + file I/O for locating and rewriting dropdown
-- option lists inside a scheme .yaml file, without touching any other byte
-- of the file (no reaper.ImGui_* calls here, and no reference to the main
-- script's `wgt` state - see SchemeEditorGui.lua for the GUI-facing half).

local M = {}

local backed_up_paths = {}
local config = { backups_dir = nil, sep = nil, dir_exists = nil, msg = nil }

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

local function EscapePattern(s)
  return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
end

local function ReadRawLines(path)
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
    elseif quote_char then
      if val:find(quote_char, 1, true) then
        return nil, "New item cannot contain the " .. quote_char .. " character used to quote this list."
      end
      out[#out + 1] = quote_char .. val .. quote_char
    elseif val:match("[,%[%]#]") or val:match("^%s") or val:match("%s$") then
      out[#out + 1] = "'" .. val .. "'"
    else
      out[#out + 1] = val
    end
  end

  return indent .. key .. gap .. "[" .. table.concat(out, ", ") .. "]" .. tail
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
