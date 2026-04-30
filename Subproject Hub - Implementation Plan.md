# Plan: Subproject Hub — Phased Implementation

## Context
Combine `Subproject Manager.lua` and `schapps_The Last Renamer.lua` into a new unified script `schapps_Subproject Hub.lua`. Three independently collapsible sections (Create → Naming → Items) in one ReaImGUI window. Both standalone scripts remain untouched.

Design spec (from Claude Design handoff):
- Dark theme: bg `#282828`, teal accent `#2C6B64` / `#7AD9C4`
- Three collapsible sections with badge numbers (01, 02, 03)
- Section 03 has a search bar above the items table
- Footer: "Schapps Reaper Scripts · Subproject Manager + The Last Renamer (schapps fork)"

**Target file:** `Subprojects/schapps_Subproject Hub.lua`  
**Leave alone:** `Subprojects/Subproject Manager.lua` and `Renamer/schapps_The Last Renamer.lua`

---

## API Style Decision
Use **old-style `reaper.ImGui_*` API** (`require 'imgui' '0.10.0.1'`) throughout:
- Keeps all Renamer `acendan` utilities unchanged (they store color constants as functions like `reaper.ImGui_Col_FrameBg`, called as `value[1]()`)
- Renamer functions are pure copy-paste — zero adaptation
- Subproject Manager ImGui calls are mechanically converted: `ImGui.Foo(ctx,...)` → `reaper.ImGui_Foo(ctx,...)` and `ImGui.FlagName` → `reaper.ImGui_FlagName()`

---

## Key Technical Notes (apply across all phases)

**Path to Renamer schemes** (hub lives in `Subprojects/`, schemes in `Renamer/Schemes/`):
```lua
local hub_dir    = ({reaper.get_action_context()})[2]:match("(.+[/\\])")
local parent_dir = hub_dir:match("^(.*[/\\])[^/\\]+[/\\]$") or hub_dir
local RENAMER_DIR = parent_dir .. "Renamer" .. SEP
local SCHEMES_DIR = RENAMER_DIR .. "Schemes" .. SEP
local script_path = RENAMER_DIR  -- acendan.loadYaml finds Lib/yaml.lua here
```

**Shared Renamer settings:** `SCRIPT_NAME = "schapps_The Last Renamer"` — presets/history/scheme selection persist across both the Hub and the standalone Renamer via shared ExtState.

**API conversion cheat sheet:**
- `ImGui.Foo(ctx, ...)` → `reaper.ImGui_Foo(ctx, ...)`
- `ImGui.FlagName` → `reaper.ImGui_FlagName()`
- `rawget(ImGui, "X") or 0` → `(rawget(reaper, "ImGui_X") and reaper.ImGui_X()) or 0`

**No theme.lua:** The SubManager's `ReaImGuiTheme.lua` uses new-style API and can't be used here. The acendan styles (45 colors + 22 style vars from the Renamer) replace it.

---

## Phase 1 — Skeleton Window (~100 lines)

**Goal:** Create the file with working infrastructure and three visible collapsible section headers. No real content yet — sections are stubs. Verifiable in Reaper immediately.

**What to write:**
1. Script header (`@description`, `@author`, `@version 1.0`)
2. ReaImGUI dependency check (`reaper.ImGui_GetBuiltinPath` guard)
3. `require 'imgui' '0.10.0.1'` + OS/path setup + `RENAMER_DIR` etc.
4. Constants: `SCRIPT_NAME`, `TITLE = "SUBPROJECT HUB"`, `WINDOW_FLAGS`, `CONFIG_FLAGS`
5. Minimal `ctx` + `wgt = {}` as module-level locals
6. Three stub render functions:
   ```lua
   local function renderCreateSection() reaper.ImGui_Text(ctx, "Create — coming soon") end
   local function renderNamingSection()  reaper.ImGui_Text(ctx, "Naming — coming soon")  end
   local function renderItemsSection()   reaper.ImGui_Text(ctx, "Items — coming soon")   end
   ```
7. `CollapsibleSection(label, open_flag, render_fn)` helper using `reaper.ImGui_CollapsingHeader`
8. `loop()` function with:
   - `reaper.ImGui_SetNextWindowSize(ctx, 900, 750, reaper.ImGui_Cond_FirstUseEver())`
   - teal header line: `● SUBPROJECT HUB  v1.0`
   - three `CollapsibleSection(...)` calls
   - footer text
   - `reaper.defer(loop)` if still open
9. Entry point:
   ```lua
   ctx = reaper.ImGui_CreateContext(TITLE)
   reaper.defer(loop)
   ```

**Verify:** Run from Reaper action list → window opens titled "SUBPROJECT HUB", shows three collapsible headers (01 CREATE SUBPROJECT, 02 NAMING, 03 SUBPROJECT ITEMS) each with stub text. Headers click to collapse/expand.

---

## Phase 2 — Renamer / Naming Section (~820 lines added)

**Goal:** Replace the Naming stub with a fully functional Naming section by integrating all `acendan` utilities and Renamer functions. Sections 01 and 03 remain stubs.

**What to add (all verbatim from `Renamer/schapps_The Last Renamer.lua`):**

1. **`acendan` table + all utilities** (Renamer lines 32–613):
   - Debug, OS/path, string, table, file helpers
   - Region/marker helpers
   - `acendan.ImGui_Styles.colors` (45 entries), `.vars` (22 entries), `.scalable`, `.font`
   - `acendan.ImGui_AutoFillComboFlags`
   - ExtState helpers (`ImGui_GetSetting`, `ImGui_GetSettingBool`, etc.)
   - `acendan.ImGui_HSV`, `acendan.ImGui_SetFont`, `acendan.ImGui_GetScale`, `acendan.ImGui_SetScale`, `acendan.ImGui_ScaleSlider`
   - `acendan.ImGui_PushStyles`, `acendan.ImGui_PopStyles`
   - `acendan.ImGui_HelpMarker`, `acendan.ImGui_Tooltip`, `acendan.ImGui_Button`, `acendan.ImGui_ComboBox`, `acendan.ImGui_AutoFillComboBox`
   - `acendan.loadYaml`

2. **All Renamer functions** (Renamer lines 641–2461, **excluding** `Main()` at line 1461):
   - `Init` — **modified**: change context line to `ctx = reaper.ImGui_CreateContext(TITLE, CONFIG_FLAGS)` and window size to `reaper.ImGui_SetNextWindowSize(ctx, 900, 750)`; keep all `wgt` setup unchanged
   - `LoadField`, `LoadFields`, `PassesIDCheck`
   - `LoadTargets`, `ValidateFields`, `FindField`
   - `ClickLoadPreset`, `LoadPresets`, `ClickLoadHistory`, `LoadHistory`
   - `TabNaming`, `ClearFields`
   - `FetchSchemes`, `SetScheme`, `LoadScheme`, `ValidateScheme`, `ValidateMeta`
   - `GetPreviousValue`, `SetCurrentValue`, `DeleteCurrentValue`, `HasValue`
   - `StoreSettings`, `RecallSettings`, `GetFieldValue`, `SetFieldValue`
   - `StoreHistory`, `StorePreset`, `RecallPresets`, `RecallHistories`, `RecallPreset`, `DeletePreset`
   - `Capitalize`, `GetSharedSchemes`, `AppendSerializedField`
   - Autofill: `SplitBySep`, `NormalizeValue`, `MatchDropdownOptions`, `TryMatchField`, `ApplyFieldMatch`, `CountTrailingParts`, `FillFields`, `AutoFillFromItem`
   - `Button`, `TabItem`
   - `ApplyName`, `Rename`, `SanitizeName`, `PadZeroes`
   - `ProcessRegions`, `ProcessItems`, `ProcessTracks`
   - `ApplyMetadata`, `GenerateMetadataMarker`, `SetMetadataMarker`

3. **Replace `renderNamingSection` stub** with:
   ```lua
   local function renderNamingSection()
     -- Scheme selector (no Settings tab in hub)
     local scheme_lbl = wgt.scheme and wgt.scheme:gsub("%.yaml$","") or "(none)"
     reaper.ImGui_SetNextItemWidth(ctx, 280)
     if reaper.ImGui_BeginCombo(ctx, "##hub_scheme", scheme_lbl) then
       for _, s in ipairs(wgt.schemes or {}) do
         if reaper.ImGui_Selectable(ctx, s:gsub("%.yaml$",""), wgt.scheme == s) then
           SetScheme(s)
         end
       end
       reaper.ImGui_EndCombo(ctx)
     end
     reaper.ImGui_SameLine(ctx)
     reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x666666FF)
     reaper.ImGui_Text(ctx, "  Scheme")
     reaper.ImGui_PopStyleColor(ctx)
     reaper.ImGui_Separator(ctx)
     reaper.ImGui_Spacing(ctx)
     TabNaming()
   end
   ```

4. **Update `loop()`** to add auto-populate and font-rebuild logic before `PushStyles`:
   ```lua
   if wgt.data and GetPreviousValue("opt_auto_populate", false) == "true" then
     local sel = reaper.GetSelectedMediaItem(0, 0)
     if sel ~= wgt.last_selected_item then
       wgt.last_selected_item = sel
       if sel then AutoFillFromItem(sel) end
     end
   end
   if wgt.set_font then acendan.ImGui_SetFont(); wgt.set_font = false end
   acendan.ImGui_PushStyles()
   -- ... window ...
   reaper.ImGui_End(ctx)
   acendan.ImGui_PopStyles()
   ```

5. **Replace entry point** with:
   ```lua
   Init()
   reaper.defer(loop)
   ```

**Verify:** Run script → Naming section shows scheme selector dropdown, UCS fields (Category, Subcategory, File Name, Enum, Creator ID), Presets/History buttons, Rename button, Name Preview. Changing scheme selector updates fields. Rename fires correctly.

---

## Phase 3 — Create Section (~420 lines added)

**Goal:** Replace the Create stub with the full Create Subproject form from the Subproject Manager.

**What to add:**

1. **State variables** (from Subproject Manager, adapted): load from ExtState at module level:
   - `name_buf`, `channels_auto`, `channels_buf`, `tail_buf`
   - `copy_video`, `close_after`, `run_dynamic_split`
   - `last_clicked_idx = nil`, `preview_stop_pos = nil`
   - Color picker state: `color_r/g/b`, `color_orig_r/g/b`, `r/g/b_buf`, `h/s/v_buf`, `hex_buf`

2. **Color helper functions** (SubManager lines 68–116, verbatim — pure Lua, no API changes):
   - `rgbToImGui(r,g,b)`, `imGuiToRgb(col)`, `rgbToHsv(r,g,b)`, `hsvToRgb(h,s,v)`

3. **Utility functions** (SubManager lines 121–214, verbatim — all use `reaper.*` only, no ImGui):
   - `containsString`, `file_exists`, `getItemChannelCount`, `setTrackChannelCount`, `adjustTrackChannelCountToMatchItem`, `getLastRenderedItem`, `runCommand`, `clearAllMarkers`, `addMarkersToTimeSelection`, `getCurrentProjectName`, `activateProjectByName`, `isTimeSelectionPresent`, `areItemsSelected`, `isSubprojectItem`

4. **Feature functions** (SubManager lines 218–539, verbatim — all use `reaper.*` only):
   - `getAllSubprojectItems`, `openSelectedSubprojects`, `updateSubproject`, `colorAllSubprojectItems`, `duplicateToNewVersion`, `collectVideoTrackChunks`, `pasteVideoTracksAtTop`, `createSubproject`

5. **Replace `renderCreateSection` stub** with adapted SubManager create UI (lines 577–701). All `ImGui.*` calls converted to `reaper.ImGui_*()`. Full form: Name/Channels/Tail fields in left column, checkboxes in right column, Create button + status text, Enter key shortcut.

6. **Add preview-stop logic** to top of `loop()` (before PushStyles):
   ```lua
   if preview_stop_pos then
     if reaper.GetPlayState() & 1 == 0 then preview_stop_pos = nil
     elseif reaper.GetPlayPosition() >= preview_stop_pos then
       reaper.Main_OnCommand(1016, 0); preview_stop_pos = nil
     end
   end
   ```

**Verify:** Run script → Create section shows Name input, Channels (with Auto checkbox), Tail input, three checkboxes, Create button (grayed when no tracks selected, active when tracks selected). Create button fires without errors when tracks are selected.

---

## Phase 4 — Items Section (~370 lines added)

**Goal:** Replace the Items stub with the full subproject items table, search bar, and action buttons (including color picker).

**What to add:**

1. **`search_buf = ""`** module-level variable (new, for items search bar)

2. **Replace `renderItemsSection` stub** with adapted SubManager items UI (lines 707–983), converted to old-style API, plus search bar at top:

   ```
   renderItemsSection(rows, reaper_sel, valid_selected, has_selection)
     ├── Search bar (InputTextWithHint + x clear button)
     ├── Filter rows by search query (take name / track / file)
     ├── Child window with scrollable table
     │    ├── Columns: ▶ | Take Name | Take Version | Track | RPP File
     │    ├── Rows: Selectable (Ctrl/Shift multi-select), play button, take arrows
     │    └── Empty state text if no items
     ├── Spacing
     └── Action buttons row:
          Open Selected | Update Subproject | Duplicate to New Version | Color All... [■ swatch]
          └── Color picker popup (RGB, HSV, Hex inputs + orig/current swatches)
   ```

3. **Update `loop()`** to compute frame state and pass to `renderItemsSection`:
   ```lua
   local rows = getAllSubprojectItems()
   local reaper_sel = {}
   for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
     reaper_sel[reaper.GetSelectedMediaItem(0, i)] = true
   end
   local valid_selected = {}
   for _, r in ipairs(rows) do
     if reaper_sel[r.item] then valid_selected[#valid_selected+1] = r.item end
   end
   local has_selection = #valid_selected > 0
   ```
   And pass these to the collapsible call:
   ```lua
   CollapsibleSection("03  SUBPROJECT ITEMS", reaper.ImGui_TreeNodeFlags_DefaultOpen(),
     function() renderItemsSection(rows, reaper_sel, valid_selected, has_selection) end)
   ```

**Key API conversions for items section:**
- `rawget(ImGui,"ChildFlags_Border") or 1` → `(rawget(reaper,"ImGui_ChildFlags_Border") and reaper.ImGui_ChildFlags_Border()) or 1`
- `rawget(ImGui,"SelectableFlags_SpanAllColumns") or 0` → same pattern
- `rawget(ImGui,"SelectableFlags_AllowOverlap") or rawget(ImGui,"SelectableFlags_AllowItemOverlap") or 0` → same pattern
- `rawget(ImGui,"TableBgTarget_RowBg0") or 1` → same pattern
- Key constants pre-computed: `KEY_LCTRL = reaper.ImGui_Key_LeftCtrl()` etc.

**Verify:**
1. Items section shows live table of all .rpp items in project
2. Search bar filters rows by take name / track / file as you type, x button clears
3. Play button (▶) previews item and auto-stops at item end
4. Take version arrows switch active take
5. Ctrl/Shift multi-select syncs with Reaper selection
6. Open Selected, Update Subproject, Duplicate to New Version buttons fire
7. Color All button + color swatch opens color picker popup with RGB/HSV/Hex inputs
8. Both standalone scripts still run independently without errors
