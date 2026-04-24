# Reference

Deep reference material for `osaurus-macos-use`. Read this only if [SKILL.md](SKILL.md) doesn't cover what you need. Most tasks don't.

## Per-App Recipes

### Safari: navigate to a URL (in the background)

```
1. open_application({ identifier: "Safari" })   // background: true is the default
   → { pid, som: { snapshot, image, elements } }
2. press_key({ key: "l", modifiers: ["command"], pid })
3. type_text({ text: "https://example.com", pid })
4. press_key({ key: "return", pid })
5. find_elements({ pid, text: "Sign in", role: "link" })
```

The user never sees Safari come forward.

### Safari: click a link on a loaded page

```
1. find_elements({ pid, text: "Pricing", role: "link" })
   → { elements: [{ id: "s2-7", ... }] }
2. click_element({ id: "s2-7" })
   // page navigated, snapshot is now stale
3. find_elements({ pid, text: "Buy now" })
```

### Safari: fill a web form

```
1. find_elements({ pid, role: "textfield", text: "email" })
2. set_value({ id: <result>, value: "user@example.com" })
3. find_elements({ pid, role: "securetextfield" })
4. set_value({ id: <result>, value: "hunter2" })
5. find_elements({ pid, role: "button", text: "Sign in" })
6. click_element({ id: <result> })
```

If `set_value` returns an error, the field probably wants real keystrokes — fall back to `type_text({ id, text, replace: true })`.

### Chromium browsers (Chrome, Edge, Brave, Arc)

The driver auto-detects Chromium-class apps (by bundle id, plus a generic Electron-Framework probe) and inserts the (-1, -1) primer click before each real click so the renderer's user-activation gate accepts the synthesized event.

**Right-click on web content does NOT work** as a synthesized event — Chromium coerces it to a left-click at the renderer-IPC boundary. For AX-addressable targets (links, buttons, toolbar items), `click_element({ button: "right" })` falls back to `AXShowMenu` which IS reliable.

### Safari: tab management (keyboard shortcuts only)

| Action | `press_key` |
|---|---|
| New tab | `("t", ["command"], pid)` |
| Close tab | `("w", ["command"], pid)` |
| Next tab | `("}", ["command", "shift"], pid)` |
| Previous tab | `("{", ["command", "shift"], pid)` |
| Reopen closed tab | `("z", ["command", "shift"], pid)` |
| Focus address bar | `("l", ["command"], pid)` |
| Reload | `("r", ["command"], pid)` |
| Back | `("[", ["command"], pid)` |
| Forward | `("]", ["command"], pid)` |
| Reader mode | `("r", ["command", "shift"], pid)` |

### Native app: handle a dialog

After an action triggers a dialog, the focus delta usually flips to the new window. Re-observe (or use `act_and_observe`):

```
1. press_key({ key: "s", modifiers: ["command"], pid })
   → delta.focusedWindow = "Save As"  (or similar)
2. find_elements({ pid, role: "button", text: "Save" })
3. click_element({ id: <result> })
```

### Native app: navigate a menu

Almost always faster as a keyboard shortcut. If you must click:

```
1. find_elements({ pid, role: "menubaritem", text: "File" })
2. click_element({ id: <result> })
3. find_elements({ pid, role: "menuitem", text: "Open Recent" })
4. click_element({ id: <result> })
```

### Right-click for a context menu

```
1. click_element({ id: <element>, button: "right" })   // uses AXShowMenu when available
2. find_elements({ pid, role: "menuitem", text: "Copy" })
3. click_element({ id: <result> })
```

### Switch between apps without bringing them forward

```
list_apps()
   → pick the pid you want
get_ui_elements({ pid: <picked>, mode: "som" })
   → fresh snapshot for the new app; its elements come back annotated
```

(Don't use `command+tab` — that physically switches the user's frontmost app.)

### Capture a specific window without raising it

```
1. list_windows({ pid })
   → { windows: [{ windowId: 12345, title: "Doc 1", focused: false, ... }, ...] }
2. take_screenshot({ windowId: 12345 })
```

`CGWindowListCreateImage` works on occluded windows, hidden windows, and windows on a different Space. The user sees nothing.

## Keyboard Shortcuts (use with `press_key`)

When backgrounded, always pass `pid`. Without it, keystrokes go through the global HID tap (visible to the user).

### System

| Action | Key | Modifiers |
|---|---|---|
| Spotlight search | `space` | `["command"]` |
| Force quit | `escape` | `["command", "option"]` |
| Lock screen | `q` | `["command", "control"]` |
| Screenshot (clipboard) | `3` | `["command", "shift"]` |
| Screenshot (selection) | `4` | `["command", "shift"]` |

### File operations

| Action | Key | Modifiers |
|---|---|---|
| Save | `s` | `["command"]` |
| Save As | `s` | `["command", "shift"]` |
| Open | `o` | `["command"]` |
| New | `n` | `["command"]` |
| Close window | `w` | `["command"]` |
| Quit app | `q` | `["command"]` |
| Print | `p` | `["command"]` |

### Editing

| Action | Key | Modifiers |
|---|---|---|
| Copy | `c` | `["command"]` |
| Cut | `x` | `["command"]` |
| Paste | `v` | `["command"]` |
| Undo | `z` | `["command"]` |
| Redo | `z` | `["command", "shift"]` |
| Select all | `a` | `["command"]` |
| Find | `f` | `["command"]` |
| Find next | `g` | `["command"]` |

### Navigation (no modifiers)

| Action | Key |
|---|---|
| Next field | `tab` |
| Previous field | `tab` (with `["shift"]`) |
| Confirm/submit | `return` |
| Cancel/dismiss | `escape` |
| Page up/down | `pageup` / `pagedown` |
| Top/bottom | `home` / `end` |

## Element Roles

Pass any of these to `get_ui_elements({ roles })` or `find_elements({ role })`. Both canonical (`"button"`) and AX (`"AXButton"`) forms work; case-insensitive.

**Buttons & links:** `button`, `link`, `popupbutton`, `menubutton`, `disclosuretriangle`, `colorwell`, `incrementor`

**Text input:** `textfield`, `textarea`, `searchfield`, `securetextfield`, `combobox`

**Selection:** `checkbox`, `radiobutton`, `slider`, `tab`, `tabgroup`

**Containers / structure:** `row`, `cell`, `outline`, `image`, `heading`, `webarea`

**Menus:** `menuitem`, `menubaritem`, `menubutton`

## Capture Modes

`open_application`, `get_ui_elements`, and `act_and_observe` accept a `mode` parameter.

### `mode: "ax"` — accessibility tree only

Returns a `TraversalResult`. Same shape as the v0.3 response. Fastest. **No Screen Recording permission needed.**

### `mode: "vision"` — screenshot only

Returns an `SOMResult` with `image` populated, `snapshot` still present (the AX tree is gathered as part of building the elementIndex, but you can ignore it), and `elements: [{ elementIndex, id, role, label, x, y, w, h }]`.

### `mode: "som"` (default) — set-of-mark

Returns an `SOMResult` with both `image` and `snapshot` populated, and the screenshot is annotated with the existing element-id labels. Best for vision-first agents.

### `SOMResult` shape

```json
{
  "mode": "som",
  "snapshot": {
    "snapshotId": 7,
    "pid": 1234,
    "elements": [...],
    "windows": [...]
  },
  "image": { "type": "image", "mimeType": "image/jpeg", "data": "<base64>" },
  "windowId": null,
  "elements": [
    { "elementIndex": 1, "id": "s7-3", "role": "textfield", "label": "Address", "x": 100, "y": 50, "w": 600, "h": 24 },
    { "elementIndex": 2, "id": "s7-7", "role": "button", "label": "Reload", "x": 720, "y": 50, "w": 24, "h": 24 }
  ],
  "routeUsed": null
}
```

`elementIndex` is assigned in the order elements appear in `snapshot.elements` (focused window first, then the rest). Both `elementIndex` and `id` resolve to the same underlying element when used with action tools.

## Snapshot Result Schema (`mode: "ax"`)

```json
{
  "snapshotId": 7,
  "pid": 1234,
  "app": "Safari",
  "focusedWindow": "Example Domain",
  "elementCount": 42,
  "truncated": false,
  "windows": [
    { "id": 1, "title": "Example", "focused": true, "x": 0, "y": 25, "w": 1440, "h": 900 }
  ],
  "elements": [
    {
      "id": "s7-12",
      "role": "link",
      "roleDescription": "link",
      "label": "More information...",
      "value": null,
      "placeholder": null,
      "path": "Window[Example] > WebArea > Group > Link[More information...]",
      "windowId": 1,
      "focused": false,
      "enabled": true,
      "x": 600, "y": 400, "w": 200, "h": 18,
      "actions": ["press"]
    }
  ]
}
```

`null` / missing fields are omitted from JSON. Use `path` and `windowId` to disambiguate when several elements share a label (e.g., two "OK" buttons).

## Action Result Schema

Successful action:

```json
{
  "success": true,
  "delta": {
    "focusedWindow": "Save As",
    "focusedElement": { "role": "textfield", "label": "Name", "value": "Untitled.txt" }
  }
}
```

Stale id (re-observe and retry):

```json
{
  "success": false,
  "stale": true,
  "error": "Element id is from snapshot s3 but the current snapshot is s7. Call get_ui_elements (or find_elements) again, then retry with the fresh id."
}
```

Removed (element gone):

```json
{
  "success": false,
  "removed": true,
  "error": "Element s7-12 no longer exists in the UI..."
}
```

Malformed (you passed an id that doesn't look like `s{n}-{n}`):

```json
{
  "error": "Element id 'foo' is not a valid snapshot id. Expected format 's<snapshot>-<n>' as returned by get_ui_elements or find_elements."
}
```

The `cancelled: true` envelope from v0.3 is preserved on `ElementActionResult` for backwards compat but is never set on the input path now (the global Esc cancel monitor was removed in v0.4 — backgrounded driving has nothing to interrupt).

## `act_and_observe` Schema

Combined action + capture in one call. Eliminates the most common failure mode (forgetting to re-observe after navigation).

```json
{
  "action": "click_element",
  "id": "s7-12",
  "mode": "som",            // capture mode for the post-action snapshot
  "windowId": 12345,         // optional; SOM/vision will capture this exact window
  "observe": "full",        // "full", "focused_window" (cheaper), or "none"
  "maxElements": 150
}
```

Response (with `mode: "som"`):

```json
{
  "action": { "success": true, "delta": { ... } },
  "som": { "snapshot": { ... }, "image": { ... }, "elements": [...] }
}
```

Response (with `mode: "ax"`):

```json
{
  "action": { "success": true, "delta": { ... } },
  "snapshot": { "snapshotId": 8, ... }
}
```

Supported `action` values: `click_element`, `set_value`, `type_text`, `press_key`, `clear_field`.

## Annotated Screenshots

`take_screenshot({ pid, annotate: true })` overlays element-id labels on the image using the most recent snapshot for that pid. `take_screenshot({ windowId, annotate: true })` does the same for a specific window.

Requires that you've already called `get_ui_elements` or `find_elements` for the relevant pid recently (otherwise there are no ids to overlay).

## Coordinates

All coordinates (`x`, `y`, element bounds, `click` arguments) are **global screen pixels**, top-left origin. On multi-display setups, use `list_displays` to map indices to screen-space rectangles.

## Background-mode contract

When you pass `pid` to `click`/`type_text`/`press_key`/`scroll`, the driver routes through:

1. **`SLEventPostToPid`** (SkyLight private framework, loaded via `dlopen`). No cursor warp; trusted by Chromium renderers.
2. **`CGEvent.postToPid`** (public CoreGraphics fallback when SkyLight is unavailable). No cursor warp but Chromium web content drops the event silently.
3. **`CGEvent.post(.cghidEventTap)`** as a final fallback. **Warps the cursor** — only happens when the pid isn't WindowServer-visible (e.g. CLI process) or when the user calls `click`/`scroll` without `pid`.

`drag` always uses the HID tap (drop receivers key on the global cursor position).

A best-effort `focusWithoutRaise(pid)` is invoked before each backgrounded click — yabai's two-`SLPSPostEventRecordTo` pattern flips AppKit-active routing to the target without `SLPSSetFrontProcess` raising the window or pulling its Space forward.

## Permissions

The host app needs Accessibility permission:

- System Settings > Privacy & Security > Accessibility
- Add the application running this plugin (e.g., Osaurus, or your terminal if running from CLI).

Without this permission, AX queries return empty / fail silently in macOS-defined ways.

`mode: "som"` and `mode: "vision"` (and `take_screenshot`) additionally need Screen Recording permission. `mode: "ax"` does not.

Sandboxed host apps may have the SkyLight `dlopen` blocked. In that case the driver gracefully degrades to `CGEvent.postToPid` for all per-pid routes — still backgrounded, but Chromium web content will reject events.

## Session Tools (telemetry only)

v0.4 removed the on-screen HUD and the global Esc-cancel monitor. The session tools remain as a side-effect-free telemetry channel:

### `start_automation_session`

```json
{
  "title": "Setting up iCloud Backup",
  "totalSteps": 5,
  "narration": "Opening System Settings"
}
```

Returns:

```json
{
  "success": true,
  "isActive": true,
  "isCancelled": false,
  "title": "Setting up iCloud Backup",
  "totalSteps": 5,
  "narration": "Opening System Settings",
  "stepIndex": null
}
```

`isCancelled` is always `false` in v0.4+ (the field stays in the schema for backwards compat).

### `update_automation_session`

```json
{ "narration": "Verifying your Apple ID", "stepIndex": 3 }
```

### `end_automation_session`

```json
{ "reason": "complete" }
```

Resets the session record. Optional, since session state is purely informational now.

## Known limitations

- **Chromium right-click on web content** is coerced to a left-click at the renderer-IPC boundary, even via SkyLight. Use `click_element` on AX-addressable targets so `AXShowMenu` fires.
- **Canvas apps (Blender GHOST, Unity, games)** filter per-pid event routes entirely. Driver auto-falls back to the HID tap, which warps the cursor.
- **Drag is uninterruptible AND warps the cursor** (drop receivers need the cursor to track). The mouse button is always released even on errors.
- **AX timeout is 3 seconds.** Blocking AX calls into a wedged target app fail in 3s instead of hanging forever.
- **Single global session.** The session record is a process singleton.
