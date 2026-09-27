# Reaper Bridge (dev only)

Lets Claude Code (or you) drive the test REAPER install at `/Applications/Reaper_Testing_Mac`
from the shell: run Lua, launch scripts, inspect project state, read errors, take screenshots.

- `Claude Bridge.lua` runs inside REAPER. It's started by `Scripts/__startup.lua` in the test
  install and polls `<resource>/ClaudeBridge/inbox` for Lua snippets.
- `rt` is the shell side. Run `DevTools/ReaperBridge/rt help` for the commands.

Setup on a new machine: put a portable REAPER at `/Applications/Reaper_Testing_Mac` (or set
`RT_RESOURCE`), with js_ReaScriptAPI installed, then run `rt install` once.

Typical loop: `rt start`, `rt reset`, set up a project with `rt eval`, `rt run <script>`,
then check with `rt state`, `rt shot <window title>`, and `rt errors`.

Scripts launched with `rt run` go through a wrapper that logs errors (including errors in
defer/ReaImGui loops) and auto-answers modal prompts, so nothing blocks the bridge. A modal
dialog opened any other way will block it until someone clicks it away.

Not a ReaPack package: `Claude Bridge.lua` has `@noindex` and the CI workflows pass `--ignore DevTools`
(reapack-index ignores are path prefixes, not globs).
