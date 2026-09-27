# ReaperScripts

REAPER Lua scripts published through ReaPack. CI (`.github/workflows/`) builds `index.xml`
from `@version`/`@changelog` headers; don't edit `index.xml` by hand.

## Testing in REAPER

Test in the portable REAPER install at `/Applications/Reaper_Testing_Mac`. Drive it with
`DevTools/ReaperBridge/rt` (see `rt help` and `DevTools/ReaperBridge/README.md`):

- First time on a machine: `rt install` (hooks the bridge into the test install's `__startup.lua`).
- After changing a script: `rt start`, `rt reset`, build a fixture project with `rt eval`,
  `rt run <script> [prompt answers]`, then verify with `rt state`, `rt errors`, and
  `rt shot <window title>` (read the PNG) for ReaImGui GUIs. `rt run` syncs the repo first;
  use `rt sync` to sync without running.
- The bridge can't click ImGui widgets. Check the resulting project state, or ask the user to
  test the interaction.
- A modal dialog not launched through `rt run` blocks the bridge. To recover, run
  `pkill -f /Applications/Reaper_Testing_Mac/REAPER.app/Contents/MacOS/REAPER`, then `rt start`.
- `DevTools/` is dev-only and ignored by reapack-index in CI.
