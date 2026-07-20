-- @noindex
-- P4Integration: detects whether a scheme .yaml file lives in a Perforce
-- depot and, if so, prompts to `p4 edit` it before any write. Owns all
-- io.popen/parsing/prompting/session-caching for that - SchemeEditor.lua
-- only ever sees a boolean back from EnsureWritable(), via the
-- config.ensure_writable injection point (see its M.init).
--
-- Designed to fail open and silent for the vast majority of users who have
-- no p4 client at all, or have the "Enable Perforce Integration" setting
-- left off (the default) - only a clean, unambiguous "tracked in the depot
-- and not currently opened for edit" signal ever surfaces a popup; anything
-- else (feature disabled, p4 missing, not configured, not in depot, a
-- network hiccup, garbled output) is treated as "nothing to do, allow the
-- write."

local M = {}

-- get_enabled: () -> bool, injected so this module can read the live
-- Settings checkbox value each call rather than a value snapshotted once at
-- init time (main script's opt_enable_p4 toggle takes effect immediately).
local config = { msg = nil, get_enabled = nil }

-- source_path -> "skip" | "already_open" | "checked_out". Only ever records
-- outcomes where the write may proceed without asking again - a decline or
-- a failed `p4 edit` is deliberately NOT cached, so the next edit attempt
-- re-checks (e.g. in case the user fixes a p4 login issue in the meantime)
-- rather than being silently skipped or silently blocked for the rest of
-- the session.
local session_cache = {}

function M.init(opts)
  config.msg         = opts.msg
  config.get_enabled = opts.get_enabled or function() return false end
end

local function IsWindows()
  return reaper.GetOS():find("Win") ~= nil
end

-- Splits an absolute path into (dir_with_trailing_sep, filename). Falls back
-- to (nil, path) if no separator is found.
local function SplitDirFile(path)
  local dir, file = path:match("^(.*[/\\])([^/\\]+)$")
  return dir, file or path
end

-- Runs `p4 <args> "<file>"`, cd'd into the file's own directory first so
-- P4CONFIG/.p4config discovery resolves against the scheme's own workspace
-- rather than Reaper's own process cwd. Captures stdout+stderr together
-- (p4 doesn't consistently separate its own error text onto stderr).
-- Returns the combined output, or nil if io.popen itself was unavailable/
-- errored (e.g. p4 not on PATH) - callers treat nil the same as "nothing to
-- do", never as a reason to block the write.
local function RunP4(source_path, args)
  local dir, file = SplitDirFile(source_path)
  local cmd
  if dir then
    local cd = IsWindows() and ('cd /d "' .. dir .. '"') or ('cd "' .. dir .. '"')
    cmd = cd .. ' && p4 ' .. args .. ' "' .. file .. '" 2>&1'
  else
    cmd = 'p4 ' .. args .. ' "' .. source_path .. '" 2>&1'
  end
  local ok, handle = pcall(io.popen, cmd, "r")
  if not ok or not handle then return nil end
  local output = handle:read("*all") or ""
  handle:close()
  return output
end

-- Parsed off p4's own tagged fstat field names (stable/language-independent
-- regardless of client locale, unlike the human-readable confirmation text
-- EditSucceeded below has to match).
local function ParseFstat(output)
  local has_depot_file = output:match("%.%.%.%s*depotFile%s") ~= nil
  local has_action     = output:match("%.%.%.%s*action%s+%S+") ~= nil
  return has_depot_file, has_action
end

local function EditSucceeded(output)
  if not output then return false end
  local lower = output:lower()
  return lower:find("opened for edit", 1, true) ~= nil
      or lower:find("opened for add", 1, true) ~= nil
      or lower:find("also opened by", 1, true) ~= nil
end

-- Ensures source_path is safe to write to. Returns true if the write may
-- proceed (feature disabled, file not P4-tracked, already checked out this
-- session, or the user approved+succeeded a fresh `p4 edit`). Returns false
-- if the write must be aborted - the user declined the prompt (silently),
-- or `p4 edit` itself failed (a real error is surfaced via config.msg in
-- that case only).
function M.EnsureWritable(source_path)
  if not config.get_enabled() then return true end
  if not source_path then return true end

  if session_cache[source_path] then return true end

  local fstat_out = RunP4(source_path, "fstat")
  if not fstat_out then
    session_cache[source_path] = "skip"
    return true
  end

  local has_depot_file, has_action = ParseFstat(fstat_out)
  if not has_depot_file then
    session_cache[source_path] = "skip"
    return true
  end
  if has_action then
    session_cache[source_path] = "already_open"
    return true
  end

  local base = source_path:match("[^/\\]+$") or source_path
  local resp = reaper.MB(
    "\"" .. base .. "\" is tracked in Perforce and is not currently checked out.\n\n" ..
    "Check it out for edit now (p4 edit)?",
    "The Last Renamer - Perforce", 4)
  if resp ~= 6 then return false end -- anything but "Yes" -> silent abort

  local edit_out = RunP4(source_path, "edit")
  if EditSucceeded(edit_out) then
    session_cache[source_path] = "checked_out"
    return true
  end

  config.msg("Could not check out \"" .. base .. "\" via Perforce:\n\n" ..
    (edit_out or "(no response from p4)") ..
    "\n\nNo changes were made.", "The Last Renamer - Perforce")
  return false
end

return M
