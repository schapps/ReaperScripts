-- @description Transport Play/Stop Ignoring Small Time Selections
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Acts like Transport: Play/Stop, but if a short time selection exists,
--   it removes it before starting playback.
-- @link https://www.stephenschappler.com
-- @changelog
--   01/25/26 v1.0 - Creating the script.

local MIN_TIME_SELECTION_SECONDS = 0.1 -- Adjust this threshold as desired

local function is_transport_active()
    return reaper.GetPlayState() ~= 0
end

local function get_time_selection_length()
    local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if start_time == end_time then
        return 0, start_time, end_time
    end
    return math.max(0, end_time - start_time), start_time, end_time
end

local function clear_time_selection()
    local cursor_pos = reaper.GetCursorPosition()
    reaper.GetSet_LoopTimeRange(true, false, cursor_pos, cursor_pos, false)
end

local function play_stop()
    reaper.Main_OnCommand(40044, 0)
end

reaper.Undo_BeginBlock()

if is_transport_active() then
    play_stop()
    reaper.Undo_EndBlock("Transport: Play/Stop (ignore small time selections)", -1)
    return
end

local time_sel_len = get_time_selection_length()
if time_sel_len > 0 and time_sel_len < MIN_TIME_SELECTION_SECONDS then
    clear_time_selection()
end

play_stop()

reaper.Undo_EndBlock("Transport: Play/Stop (ignore small time selections)", -1)
