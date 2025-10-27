-- @description Search for selected item in Media Explorer
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Copies the file name of the selected item to the clipboard. 
--   Santizes the name if there is a long number string at the end. You can comment out that feature below if you want.
-- @link https://www.stephenschappler.com
-- @changelog 
--   10/27/2025 - v 1.0 - adding the script

local item = reaper.GetSelectedMediaItem(0, 0)

local function split_int(val)
    val = val or 0
    if val < 0 then
        val = 0x100000000 + val
    end
    local low = val % 0x10000
    local high = math.floor(val / 0x10000)
    return low, high
end

local function send_message(hwnd, msg, wParam, lParam)
    if not hwnd then
        return
    end
    local wLow, wHigh = split_int(wParam)
    local lLow, lHigh = split_int(lParam)
    reaper.JS_WindowMessage_Send(hwnd, msg, wLow, wHigh, lLow, lHigh)
end

local function FocusMediaExplorerSearch(query)
    if not reaper.APIExists("JS_Window_SetFocus") or not reaper.APIExists("JS_WindowMessage_Send") then
        reaper.ShowMessageBox(
            "Focusing and editing the Media Explorer requires the JS_ReaScriptAPI extension.",
            "Missing extension",
            0
        )
        return
    end

    local explorer_hwnd = reaper.OpenMediaExplorer("", false)
    if not explorer_hwnd then
        explorer_hwnd = reaper.JS_Window_Find("Media Explorer", true)
    end

    if not explorer_hwnd then
        reaper.ShowMessageBox("Could not locate the Media Explorer window.", "Error", 0)
        return
    end

    reaper.JS_Window_SetFocus(explorer_hwnd)

    -- Highlight the search field so manual input can begin immediately
    reaper.JS_Window_OnCommand(explorer_hwnd, 42191)

    local attempts = 0
    local function finish()
        attempts = attempts + 1
        local search_hwnd = reaper.JS_Window_GetFocus()
        if not (search_hwnd and reaper.JS_Window_GetClassName(search_hwnd) == "Edit") then
            if attempts < 25 then
                return reaper.defer(finish)
            end
            reaper.ShowMessageBox("Could not access the Media Explorer search box.", "Error", 0)
            return
        end

        if query and query ~= "" then
            send_message(search_hwnd, "EM_SETSEL", 0, -1)
            send_message(search_hwnd, "WM_CLEAR", 0, 0)
            for _, codepoint in utf8.codes(query) do
                send_message(search_hwnd, "WM_CHAR", codepoint, 0)
            end
        end

        reaper.JS_Window_OnCommand(explorer_hwnd, 1013) -- Browser: Browse for file (trigger search)
    end

    finish()
end

if item then
    -- Get the active take from the selected item
    local take = reaper.GetActiveTake(item)

    if take and not reaper.TakeIsMIDI(take) then
        -- Get the source of the take
        local source = reaper.GetMediaItemTake_Source(take)

        -- Get the file name of the source
        local file_path = reaper.GetMediaSourceFileName(source, "")

        if file_path and file_path ~= "" then
            -- Extract the file name without the extension
            local file_name = file_path:match("([^\\/]+)$"):gsub("%.%w+$", "")

            if file_name then
                -- Remove "_<long_number>" patterns
                local sanitized_name = file_name:gsub("_[%d]+$", function(match)
                    return #match > 3 and "" or match -- Only remove if more than two digits
                end)

                -- Copy the sanitized file name to the clipboard
                reaper.CF_SetClipboard(sanitized_name)
                --reaper.ShowMessageBox("File name copied to clipboard:\n" .. sanitized_name, "Success", 0)

                FocusMediaExplorerSearch(sanitized_name)

            else
                reaper.ShowMessageBox("Could not extract file name.", "Error", 0)
            end
        else
            reaper.ShowMessageBox("Could not retrieve file name.", "Error", 0)
        end
    else
        reaper.ShowMessageBox("Selected item has no valid audio take.", "Error", 0)
    end
else
    reaper.ShowMessageBox("No item selected.", "Error", 0)
end
