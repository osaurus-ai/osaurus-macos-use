# Reference

Deep reference material for `osaurus-macos-use`. Read this only if [SKILL.md](SKILL.md) doesn't cover what you need. Most tasks don't.

## Per-App Recipes

### Safari: navigate to a URL

```
1. open_application({ identifier: "Safari" })
   → { pid, snapshot }
2. press_key({ key: "l", modifiers: ["command"], pid })
3. type_text({ text: "https://example.com" })
4. press_key({ key: "return", pid })
5. find_elements({ pid, text: "Sign in", role: "link" })  // or whatever you need next
```

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
3. find_elements({ pid, role: "secur etextfield" })
4. set_value({ id: <result>, value: "hunter2" })
5. find_elements({ pid, role: "button", text: "Sign in" })
6. click_element({ id: <result> })
```

If `set_value` returns an error, the field probably wants real keystrokes — fall back to `type_text({ id, text, replace: true })`.

### Safari: tab management (keyboard shortcuts only)

| Action | `press_key` |
|---|---|
| New tab | `("t", ["command"])` |
| Close tab | `("w", ["command"])` |
| Next tab | `("}", ["command", "shift"])` |
| Previous tab | `("{", ["command", "shift"])` |
| Reopen closed tab | `("z", ["command", "shift"])` |
| Focus address bar | `("l", ["command"])` |
| Reload | `("r", ["command"])` |
| Back | `("[", ["command"])` |
| Forward | `("]", ["command"])` |
| Reader mode | `("r", ["command", "shift"])` |

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
1. click_element({ id: <element>, button: "right" })
2. find_elements({ pid, role: "menuitem", text: "Copy" })
3. click_element({ id: <result> })
```

### Switch between apps

```
open_application({ identifier: "Notes" })
// returns a fresh snapshot for Notes; the previous app's ids become stale
```

You can also `press_key("tab", modifiers: ["command"])` and then `get_active_window` to find the new pid.

## Keyboard Shortcuts (use with `press_key`)

### System

| Action | Key | Modifiers |
|---|---|---|
| Switch app | `tab` | `["command"]` |
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

## Snapshot Result Schema

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

## Automation Session Tools

The plugin shows a floating "Automation in progress" HUD whenever any tool is active. The HUD lets the user press Esc at any time to cancel; the next tool call returns `cancelled: true`. Three tools let agents drive the HUD intentionally:

### `start_automation_session`

```json
{
  "title": "Setting up iCloud Backup",
  "totalSteps": 5,
  "narration": "Opening System Settings"
}
```

- `title` (required): plain-language session title, shown large in the HUD.
- `totalSteps` (optional): enables `Step N of M` progress text.
- `narration` (optional): initial subtitle.

If a session is already active, calling `start_automation_session` supersedes it (no leak, new title/state takes over).

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

### `update_automation_session`

Update one or more HUD fields without performing an action. Useful for advancing `stepIndex` or rewriting the title mid-flow. All fields are optional.

```json
{
  "narration": "Verifying your Apple ID",
  "stepIndex": 3
}
```

### `end_automation_session`

```json
{ "reason": "complete" }
```

- `reason` (optional): `"complete" | "aborted" | "error"`. Reserved for future logging; currently informational.

Hides the HUD, stops the Esc tap, resets the cancellation flag. Idle sessions auto-end after ~3 seconds of no tool calls, so this is optional but cleaner.

### Per-action `narration` arg

Every action tool (`click_element`, `set_value`, `type_text`, `clear_field`, `press_key`, `scroll`, `drag`, `click`, `act_and_observe`, `open_application`) accepts an optional `narration` string. It updates the HUD subtitle right before the action runs:

```json
{
  "id": "s2-3",
  "narration": "Clicking the Sign In button"
}
```

Strongly recommended for supervised flows. Cheap to add and dramatically improves the user's understanding of what's happening.

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

User pressed Esc to cancel:

```json
{
  "success": false,
  "cancelled": true,
  "error": "Cancelled by user (Esc was pressed during the automation)."
}
```

When you see `cancelled: true`, stop the flow and surface the cancellation to the user. Do not retry.

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

## `act_and_observe` Schema

Combined action + snapshot in one call. Eliminates the most common failure mode (forgetting to re-observe after navigation).

```json
{
  "action": "click_element",
  "id": "s7-12",
  "observe": "full",         // or "focused_window" (cheaper) or "none"
  "maxElements": 150
}
```

Response:

```json
{
  "action": { "success": true, "delta": { ... } },
  "snapshot": { "snapshotId": 8, ... }
}
```

Supported `action` values: `click_element`, `set_value`, `type_text`, `press_key`, `clear_field`.

## Annotated Screenshots

`take_screenshot({ pid, annotate: true })` overlays element-id labels on the image using the most recent snapshot for that pid. Useful when you want a vision model to reference specific ids visually.

Requires that you've already called `get_ui_elements` or `find_elements` for that pid recently (otherwise there are no ids to overlay).

## Coordinates

All coordinates (`x`, `y`, element bounds, `click` arguments) are **global screen pixels**, top-left origin. On multi-display setups, use `list_displays` to map indices to screen-space rectangles.

## Permissions

The host app needs Accessibility permission:

- System Settings > Privacy & Security > Accessibility
- Add the application running this plugin (e.g., Osaurus, or your terminal if running from CLI).

Without this permission, the AX queries return empty / fail silently in macOS-defined ways. The Esc-cancel `CGEventTap` also requires Accessibility — if denied, Esc-to-cancel silently no-ops (the HUD still shows up, agent still works, but Esc won't stop the automation).

Sandboxed host apps may have `CGEventTapCreate` blocked even with Accessibility granted; same fallback (no Esc, everything else works).

## Known limitations

- **Single global session.** The HUD and cancel flag are a process singleton. Two agents using the plugin in parallel will share one session.
- **Drag is uninterruptible.** `drag()` always releases the mouse button via `defer`, even on errors, so the OS can never be left thinking the user is holding the button down. The trade-off is that `drag` cannot be cancelled mid-flight.
- **AX timeout is 3 seconds.** Blocking AX calls into a wedged target app fail in 3s instead of hanging forever, but you'll wait up to that long before the next cancel check.
- **Display sleep does not auto-end the session.** Some flows are intentionally long; we leave it to the user to press Esc.
