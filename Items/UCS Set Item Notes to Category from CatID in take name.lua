-- @description UCS: Set Item Notes to Category from CatID in take name
-- @author Stephen Schappler
-- @version 1.3
-- @about
--   Reads the CatID from each selected item's name or source filename,
--   looks up the UCS Category from a CSV (CatID,Category),
--   and writes it to the item's Notes field for $itemnotes.
-- @link https://www.stephenschappler.com
-- @changelog
--   1.1 - Fixing ucs csv path
--   1.0 - Initial release
-- @provides
--   ../Packages/UCS.csv > ../../../Data/Schapps/UCS.csv

-- ===========================
-- ========== SETUP ==========
-- ===========================

-- Put UCS.csv next to this script, OR in Data/Schapps/UCS.csv
local CSV_FILENAME = "UCS.csv"

local function fileExists(p)
  local f = p and io.open(p, "rb")
  if f then f:close(); return true end
  return false
end

local info = debug.getinfo(1, 'S')
local script_dir = info.source:match("@(.+[\\/])")
local candidate_paths = {
  script_dir and (script_dir .. CSV_FILENAME) or nil,
  (reaper.GetResourcePath():gsub("\\","/")) .. "/Data/Schapps/" .. CSV_FILENAME
}

local CSV_PATH
for _, p in ipairs(candidate_paths) do
  if fileExists(p) then CSV_PATH = p; break end
end

-- ===========================
-- ======== UTILITIES ========
-- ===========================

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function cleanField(s)
  if not s then return nil end
  s = s:gsub("^%s+", "")        -- trim leading spaces
  s = s:gsub("%s+$", "")        -- trim trailing spaces
  s = s:gsub(",$", "")          -- strip a trailing comma, if any
  return s
end

local function fileExists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

-- CSV line parser (supports quotes, commas inside quotes, and escaped quotes "")
local function parseCSVLine(line)
  local fields, field, in_quotes = {}, "", false
  local i, len = 1, #line
  while i <= len do
    local c = line:sub(i, i)
    if c == '"' then
      if in_quotes and line:sub(i+1, i+1) == '"' then
        field = field .. '"'  -- escaped quote
        i = i + 1
      else
        in_quotes = not in_quotes
      end
    elseif c == ',' and not in_quotes then
      table.insert(fields, field)
      field = ""
    else
      field = field .. c
    end
    i = i + 1
  end
  table.insert(fields, field)
  return fields
end

local function readCSVtoMap(path)
  local map = {}
  local f = io.open(path, "r")
  if not f then return nil, "Could not open CSV: " .. tostring(path) end

  for line in f:lines() do
    -- strip UTF-8 BOM if present
    line = line:gsub("^\239\187\191", "")

    -- skip empty lines and comment lines
    if line:match("^%s*$") or line:match("^%s*#") then
      goto continue
    end

    local fields = parseCSVLine(line)
    local a = fields[1] and cleanField(fields[1]) or nil
    local b = fields[2] and cleanField(fields[2]) or nil

    -- skip header row like "CatID,Category"
    if a and b and not a:lower():match("^catid$") then
      if a ~= "" and b ~= "" then
        map[string.upper(a)] = b
      end
    end

    ::continue::
  end

  f:close()
  if next(map) == nil then
    return nil, "CSV appears empty or improperly formatted (expect two columns: CatID,Category)."
  end
  return map
end

local function basename(path)
  if not path or path == "" then return "" end
  path = path:gsub("\\", "/")
  path = path:match("([^/]+)$") or path
  local noext = path:match("^(.*)%.") or path
  return noext
end

local function getItemDisplayName(item)
  -- Prefer the take name; fallback to the source filename basename
  local take = reaper.GetActiveTake(item)
  if take ~= nil then
    local _, takename = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    if takename and takename ~= "" then
      return takename
    end
    local src = reaper.GetMediaItemTake_Source(take)
    if src ~= nil then
      local _, srcfn = reaper.GetMediaSourceFileName(src, "")
      if srcfn and srcfn ~= "" then
        return basename(srcfn)
      end
    end
  end
  return nil
end

local function extractCatID(name)
  -- UCS: first token before underscore
  if not name or name == "" then return nil end
  name = trim(name):gsub("^_+", "")  -- trim and drop leading underscores
  local catID = name:match("^([^_]+)")
  if catID and catID ~= "" then
    return string.upper(catID)
  end
  return nil
end

local function setItemNotes(item, text)
  reaper.GetSetMediaItemInfo_String(item, "P_NOTES", text or "", true)
end

-- ===========================
-- ========== MAIN ===========
-- ===========================

local function main()
  local sel_count = reaper.CountSelectedMediaItems(0)
  if sel_count == 0 then
    reaper.MB("No items selected.\nSelect items and run again.", "UCS: Set Item Notes", 0)
    return
  end

  -- Ensure we have a CSV path; if the default doesn’t exist, prompt the user
  local csv_path = CSV_PATH
  if not fileExists(csv_path) then
    local retval, fn = reaper.GetUserFileNameForRead("", "Select CatID→Category CSV (CatID,Category)", ".csv")
    if retval and fn and fn ~= "" then
      csv_path = fn
    else
      reaper.MB("CSV not found:\n" .. tostring(CSV_PATH) .. "\n\nAnd no file was selected.", "UCS: Set Item Notes", 0)
      return
    end
  end

  local map, err = readCSVtoMap(csv_path)
  if not map then
    reaper.MB("Failed to load CatID→Category map:\n" .. tostring(err), "UCS: Set Item Notes", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local updated, missing, malformed = 0, 0, 0
  local report = {}

  for i = 0, sel_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local displayName = getItemDisplayName(item)

    if not displayName then
      malformed = malformed + 1
      report[#report+1] = ("Item %d: no take name or source filename found."):format(i+1)
    else
      local catID = extractCatID(displayName)
      if not catID then
        malformed = malformed + 1
        report[#report+1] = ("Item %d: could not extract CatID from '%s'"):format(i+1, displayName)
      else
        local category = map[catID]
        if category then
          setItemNotes(item, category)
          updated = updated + 1
        else
          missing = missing + 1
          report[#report+1] = ("Item %d: CatID '%s' not found in map (name: '%s')"):format(i+1, catID, displayName)
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("UCS: Set Item Notes to Category from CatID (CSV)", -1)

  -- Console summary
  reaper.ShowConsoleMsg("")
  reaper.ClearConsole()
  reaper.ShowConsoleMsg(("UCS Set Item Notes — Done.\nUpdated: %d  | Missing CatIDs: %d  | Malformed: %d\n")
    :format(updated, missing, malformed))
  if #report > 0 then
    reaper.ShowConsoleMsg("\nDetails:\n" .. table.concat(report, "\n") .. "\n")
  end
end

-- Run
main()
