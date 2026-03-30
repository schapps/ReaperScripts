# Reaper Track Template Repository — Software Specification

**Project Name:** ReaTemplates (working title)
**Target Environment:** REAPER DAW (Windows & macOS)
**Language:** Lua
**UI Framework:** ReaImGUI
**Distribution:** ReaPack
**Backend:** GitHub (private organization repository)

---

## 1. Project Overview

ReaTemplates is a Lua script for REAPER that provides a unified interface for saving, tagging, browsing, and sharing track templates across a private group of ~50 users. It replaces REAPER's native template workflow with a richer metadata layer and a GitHub-backed sync system for community sharing.

---

## 2. Core Feature Summary

| Feature | Description |
|---|---|
| Save Template | Save selected tracks as a `.RTrackTemplate` with rich metadata |
| Browse Templates | Side-panel + main content browser with filtering and sorting |
| Insert Template | Insert a template's tracks at the current cursor/selection |
| Upload Template | Push a template + metadata to the shared GitHub repo |
| Download Template | Pull community templates into REAPER's local template folder |
| Sync / Notifications | Background check on launch; notify user of new templates |
| Admin Panel | Admin-only controls tied to a designated GitHub username |
| Offline Support | Full local functionality when no internet is available |

---

## 3. Architecture Overview

### 3.1 File Layout (Local)

```
<REAPER Track Templates folder>/
  reatemplate_meta/
    <template_name>.json       ← Local metadata sidecar files
  <template_name>.RTrackTemplate
```

All downloaded community templates land directly in REAPER's default Track Templates folder so they are visible in REAPER's native template browser as well.

### 3.2 GitHub Repository Layout

```
/templates/
  <creator_username>/
    <template_name>/
      <template_name>.RTrackTemplate
      meta.json
/config/
  tags.json                    ← Admin-managed predefined tag list
  users.json                   ← Optional: approved usernames list
README.md
```

### 3.3 Metadata Schema (`meta.json`)

```json
{
  "name": "Punchy Kick Bus",
  "description": "A tight kick drum bus with parallel compression and saturation.",
  "creator": "github_username",
  "date_created": "2025-03-15T10:42:00Z",
  "date_modified": "2025-03-15T10:42:00Z",
  "version": 1,
  "predefined_tags": ["Drums", "Bus", "Mix"],
  "custom_tags": ["punchy", "parallel"],
  "plugins": ["ReaComp", "Decapitator", "ReaEQ"],
  "preview_image": "preview.png"
}
```

### 3.4 Config File (`tags.json` — Admin Managed)

```json
{
  "categories": [
    "Drums", "Bass", "Guitar", "Synth Lead", "Synth Pad",
    "Vocal Chain", "Mix Bus", "FX Return", "Orchestral",
    "Sound Design", "Utility"
  ]
}
```

---

## 4. UI Layout & Navigation

The script opens a single ReaImGUI window with a **side panel + main content area** layout.

### 4.1 Overall Window Structure

```
┌─────────────────────────────────────────────────────────┐
│  ReaTemplates                              [⚙ Settings] │
├──────────────┬──────────────────────────────────────────┤
│              │  [Search bar]          [↑ Upload] [↓ Sync]│
│  SIDE PANEL  │─────────────────────────────────────────  │
│              │                                           │
│  ▾ My Templates     MAIN CONTENT AREA                   │
│  ▾ Community        (Template list / detail view)       │
│                                                          │
│  FILTER BY TAG                                           │
│  [ ] Drums                                               │
│  [ ] Bass                                                │
│  [ ] Vocal Chain                                         │
│  [ ] ...                                                 │
│                                                          │
│  SORT BY                                                 │
│  ○ Name (A–Z)                                           │
│  ○ Date Added                                            │
│  ○ Category                                              │
└──────────────┴──────────────────────────────────────────┘
```

### 4.2 Side Panel

- **My Templates** — collapsible section showing locally saved templates
- **Community** — collapsible section showing downloaded/available community templates
- **Filter by Tag** — checkboxes for each predefined tag; filters both sections simultaneously
- **Sort By** — radio buttons: Name A–Z, Date Added (newest first), Category

### 4.3 Main Content Area — List View

Each template row displays:
- Template name (bold)
- Creator username + date
- Tag pills (colored by category)
- Plugin count badge (e.g. "4 plugins")
- Action buttons: **[Insert]** **[Details]** and conditionally **[Upload]** / **[Delete]**

### 4.4 Main Content Area — Detail View

Clicking **[Details]** on a template expands or navigates to:
- Full name, description
- Creator, date created/modified
- All tags (predefined + custom)
- Plugin list (with a warning icon ⚠ next to plugins not found on the current system)
- Preview image (if available)
- **[Insert into Project]** button
- **[Edit Metadata]** button (own templates only)
- **[Delete]** button (own templates or admin)

---

## 5. Functional Specifications

### 5.1 Saving a Template

**Trigger:** User selects tracks in REAPER, then clicks **[+ Save Selected Tracks]** (always visible button in the main area or toolbar).

**Flow:**
1. Script checks that at least one track is selected; shows an error toast if not.
2. Opens a **Save Template modal** with fields:
   - **Name** (required) — text input; validated for uniqueness against both local and community templates. Shows inline error if duplicate detected.
   - **Description** — multiline text input
   - **Predefined Tags** — multi-select checklist from `tags.json`
   - **Custom Tags** — free-form comma-separated text input
   - **Preview Image** — optional file picker (PNG/JPG); future version may auto-capture
3. On confirm:
   - Calls `reaper.Main_openProject` / track template save API to write the `.RTrackTemplate` file into REAPER's templates folder
   - Writes a `meta.json` sidecar into `reatemplate_meta/`
   - Runs plugin detection (see §5.6) and stores results in metadata
   - Template appears immediately in **My Templates** list

### 5.2 Browsing & Filtering Templates

- Both **My Templates** and **Community** sections are searchable via the shared search bar (searches name, description, tags, creator)
- Tag checkboxes in the side panel filter results in real time
- Sort selection applies globally to both sections
- Sections can be collapsed independently

### 5.3 Inserting a Template

**Trigger:** User clicks **[Insert]** on a template row or **[Insert into Project]** in the detail view.

**Flow:**
1. Script verifies that a REAPER project is open; shows error toast if not.
2. Checks for missing plugins (see §5.6) and shows a warning dialog listing them. User can proceed or cancel.
3. Calls REAPER's `Main_openProject` with the template file path to insert tracks at the current edit cursor position.
4. Shows a success toast: "Inserted: [Template Name]"

### 5.4 Uploading a Template

**Trigger:** User clicks **[Upload]** on one of their local templates.

**Prerequisites:** GitHub PAT must be configured (see §5.8 Setup).

**Flow:**
1. Checks that the template name is unique in the community repo via GitHub API (`GET /repos/.../contents/templates/<username>/<name>`). If a conflict is found with another user's template, shows an error: "A template named '[name]' already exists by [other_creator]. Please rename yours."
2. If the same user previously uploaded this template, confirms overwrite (since only original creator can overwrite).
3. Uploads via GitHub API (`PUT /repos/.../contents/...`):
   - `.RTrackTemplate` file (base64-encoded)
   - `meta.json`
   - `preview.png` (if present)
4. Shows progress indicator during upload.
5. On success: template is marked as "uploaded" in local metadata; **[Upload]** button changes to **[Uploaded ✓]**.
6. On failure: shows error with GitHub API message.

### 5.5 Downloading / Syncing Templates

**Background sync on launch:**
1. Script fires a background coroutine checking the GitHub API for templates newer than the last sync timestamp (stored in a local config file).
2. If new templates are found, shows a non-blocking notification banner: "**3 new community templates available** — [Sync Now] [Dismiss]"
3. Last-checked timestamp is always updated regardless of whether the user syncs.

**Manual sync:**
- **[↓ Sync]** button in the toolbar triggers a full sync
- Downloads all `meta.json` files to build the community list (lightweight)
- Actual `.RTrackTemplate` files are only downloaded when the user clicks **[Insert]** or explicitly **[Download]** on a template
- Downloaded templates land in REAPER's default Track Templates folder

### 5.6 Plugin Detection & Warnings

On template save:
1. Script reads the raw `.RTrackTemplate` XML and parses all `<VST>`, `<AU>`, `<JS>` plugin references.
2. Cross-references against REAPER's installed plugin list via the REAPER API.
3. Stores the full plugin list in `meta.json` with a boolean `installed` field per plugin.

On template insert:
1. Re-runs the cross-reference check against the current system.
2. If any plugins are missing, shows a modal warning:
   > "This template uses plugins not found on your system:
   > ⚠ Decapitator (VST)
   > ⚠ Soundtoys EchoBoy (VST)
   > Tracks will load but these plugins will be offline. Continue?"
3. User can proceed or cancel.

### 5.7 Admin Panel

Accessible via **[⚙ Settings]** → **[Admin]** tab, only visible when the logged-in GitHub username matches the configured admin username.

**Capabilities:**
- **Manage Predefined Tags** — add, rename, reorder, or remove tags from `tags.json` (pushes a commit to the repo)
- **Delete Any Template** — can delete any community template from the repo
- **View All Users** — list of uploaders and their template counts

Admin username is hardcoded in a script config constant at the top of the Lua file (e.g. `ADMIN_USERNAME = "your_github_username"`).

### 5.8 First-Time Setup Flow

On first launch (no config file found):

1. Shows a **Welcome / Setup modal**:
   - **GitHub Username** — text input
   - **Personal Access Token (PAT)** — password input, with a helper link to GitHub PAT creation docs
     - Required scopes: `repo` (full repo access on a private repo)
   - **REAPER Templates Folder** — auto-detected but overridable
2. Config is saved locally to `reatemplate_config.json` in the REAPER scripts folder. PAT is stored with basic obfuscation (not plaintext, though users should be reminded it is sensitive).
3. On save, the script validates the PAT with a test API call (`GET /user`) and shows success or an auth error.

### 5.9 Offline Behavior

- On launch, if no internet is reachable (or GitHub API returns a network error), the script silently skips the background sync.
- A small status indicator in the toolbar shows: 🔴 **Offline** (red dot) vs 🟢 **Connected**.
- All local template saving, browsing, and inserting works fully offline.
- Upload and Sync buttons are disabled with a tooltip: "Not available offline."

---

## 6. Data & State Management

### 6.1 Local Config File

Stored at `<REAPER Scripts>/reatemplate_config.json`:

```json
{
  "github_username": "jane_doe",
  "github_pat": "<obfuscated>",
  "github_repo": "my-org/reaper-templates",
  "templates_folder": "/Users/jane/Library/Application Support/REAPER/TrackTemplates",
  "admin_username": "admin_github_username",
  "last_sync": "2025-03-15T10:42:00Z"
}
```

### 6.2 Community Template Cache

After sync, the script caches community `meta.json` files locally in:
```
<REAPER Scripts>/reatemplate_cache/
  <creator>__<template_name>.json
```
This allows browsing community templates without repeated API calls.

---

## 7. Error Handling & Edge Cases

| Scenario | Behavior |
|---|---|
| No tracks selected on save | Toast error: "Please select at least one track." |
| Duplicate template name (same user re-upload) | Confirm overwrite dialog |
| Duplicate template name (different user) | Block with error message |
| GitHub API rate limit hit | Show error toast with retry suggestion |
| PAT expired or invalid | Show re-auth prompt in settings |
| Template file missing locally | Show inline warning in list; offer to re-download |
| Plugin not found on insert | Warning modal with plugin list; user can proceed |
| Network timeout during upload | Show failure toast; template remains local only |
| REAPER not open / no project on insert | Error toast |

---

## 8. ReaPack Distribution

- The script is packaged as a standard ReaPack-compatible repository
- Users install via **Extensions → ReaPack → Import Repositories** with the package URL
- Script updates are pushed as new ReaPack versions; users are notified by ReaPack natively
- The ReaPack `index.xml` should reference the main script file and list all Lua dependencies

---

## 9. Technical Constraints & Notes

- **ReaImGUI version:** Target the latest stable ReaImGUI release; specify minimum version in ReaPack metadata
- **GitHub API:** Use the REST API v3 (`https://api.github.com`). All requests include `Authorization: token <PAT>` and `User-Agent: ReaTemplates`
- **File encoding:** `.RTrackTemplate` files must be base64-encoded for GitHub API `PUT /contents` uploads
- **Lua HTTP:** Use `reaper.APIExists("Http_Get")` to check for SWS extension HTTP support, or fall back to `io.popen("curl ...")` as a cross-platform fallback. Prefer the SWS HTTP API if available
- **JSON:** Use a bundled lightweight Lua JSON library (e.g. `dkjson` or `lunajson`) — do not assume any external dependency
- **Coroutines:** Background sync must use Lua coroutines via `reaper.defer()` to avoid blocking the REAPER UI thread
- **Path handling:** Use `reaper.GetResourcePath()` for cross-platform template folder detection; handle both Windows (`\`) and macOS (`/`) path separators
- **Template XML parsing:** Use Lua pattern matching or a lightweight XML parser to extract plugin references from `.RTrackTemplate` files

---

## 10. Out of Scope (v1)

The following are explicitly deferred to future versions:

- Auto-capture of preview screenshots (v1 uses manual image attachment only)
- Star ratings or likes on templates
- In-script diff/changelog when a template is updated
- Template commenting or discussion
- Full plugin dependency resolution or auto-install
- Multi-track template grouping or "template packs"
- Public (non-private) repository mode

---

## 11. Open Questions for Implementation

1. **PAT obfuscation method** — Decide on a simple XOR or base64 scheme for local PAT storage, with a clear disclaimer to users that this is not encryption.
2. **Unique name enforcement scope** — Confirm whether uniqueness is enforced globally (across all creators) or per-creator. Current spec: global uniqueness enforced at upload time only; local names are free-form.
3. **ReaImGUI minimum version** — Confirm the minimum ReaImGUI version needed for all widgets used (particularly image rendering for preview thumbnails).
4. **SWS HTTP vs curl fallback** — Decide whether to require SWS as a hard dependency (simpler code) or support the curl fallback (broader compatibility).
