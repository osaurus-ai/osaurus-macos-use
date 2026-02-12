---
name: osaurus-macos-use
description: Control macOS via accessibility APIs. Use when the user asks to interact with native Mac apps, automate UI tasks, browse the web in Safari, fill forms, navigate menus, or perform any on-screen action.
metadata:
  author: osaurus
  version: "0.2.0"
---

# Osaurus macOS Use

Automate macOS through accessibility APIs. This plugin gives you direct control over any application's UI — click buttons, type text, fill forms, navigate menus, browse the web in Safari, and more.

## Core Workflow

Every interaction follows the **Observe-Act** pattern:

1. **Identify the app** — `open_application` to launch/activate, returns a `pid`.
2. **Observe the UI** — `get_ui_elements` with the `pid` to get interactive elements and their IDs.
3. **Act** — use element IDs to `click_element`, `type_text`, `set_value`, `press_key`, etc.
4. **Re-observe only when the UI changes** — after navigation, opening dialogs, switching tabs, or submitting forms. Do NOT re-observe after every action.

This decoupled approach keeps token usage low. A typical 5-step interaction costs ~3K tokens vs ~150K if you re-observed after every action.

## When to Re-Observe

Call `get_ui_elements` again when:
- You clicked a button that opens a new view, dialog, or menu
- You navigated to a new page (e.g., clicked a link in Safari)
- You switched tabs or windows
- You submitted a form and the UI refreshed
- An element ID returns "Element not found"

Do NOT re-observe when:
- You just typed text into a field
- You just pressed a keyboard shortcut
- You clicked a button that doesn't change the visible UI (e.g., a toggle)

## Tool Selection Guide

### Clicking

- **`click_element`** — Default choice. Uses accessibility actions (most reliable). Supports `button: "right"` for context menus and `doubleClick: true` for double-clicks.
- **`click`** — Fallback for coordinate-based clicks. Only use when elements aren't accessible (canvas apps, image regions, screenshot-guided interaction).

### Entering Text

- **`set_value`** — Best for form fields. Directly sets the element's value. Instant, reliable, replaces existing content.
- **`type_text`** — Simulates keystroke-by-keystroke typing. Use when `set_value` doesn't work (e.g., search fields that need live filtering, password fields, or fields that trigger on-type events). Pass `id` to auto-focus the element first.

Prefer `set_value` over `type_text` when filling forms. Fall back to `type_text` if `set_value` returns an error.

### Screenshots

- **`take_screenshot`** — Use when the accessibility tree is insufficient to understand the visual layout (e.g., verifying styling, reading images, canvas apps, or when elements don't have labels).
- **`get_ui_elements`** — Preferred for most interactions. Lighter, faster, and returns structured data.

Use `take_screenshot` with `pid` to capture a specific app window. Default settings (JPEG, 0.7 quality, 0.5 scale) are optimized for token efficiency.

### Keyboard

- **`press_key`** — For keyboard shortcuts, navigation keys, and special keys. Always prefer keyboard shortcuts over UI clicking when available (faster, more reliable).

### Scrolling

- **`scroll`** — Pass `x`/`y` to scroll a specific area. Without coordinates, scrolls at the current mouse position. Use `amount` to control scroll distance (default: 3 pixels).

## Token Efficiency Tips

1. **Use `interactiveOnly: true`** (default) when calling `get_ui_elements`. Only set to `false` when you need to read static text labels.
2. **Keep `maxElements` low.** Default is 100. For simple UIs (dialogs, settings panes), use 30-50. For complex UIs (web pages), use 100-150.
3. **Use `roles` filter** to narrow results. For example, `roles: ["button"]` when looking for a specific button, or `roles: ["textField", "textArea"]` when looking for input fields.
4. **Avoid unnecessary screenshots.** Screenshots consume vision tokens. Use `get_ui_elements` first — only screenshot if you need visual context.
5. **Batch actions without re-observing.** After observing once, perform multiple actions (click, type, press key) before re-observing.
6. **Use keyboard shortcuts** instead of navigating menus. `press_key("s", modifiers: ["command"])` is cheaper than finding and clicking File > Save.

## Common Recipes

### Open an App and Inspect It

```
1. open_application(identifier: "Notes")
   → { pid: 1234, name: "Notes" }

2. get_ui_elements(pid: 1234)
   → Returns elements with IDs
```

### Click a Button

```
1. get_ui_elements(pid: 1234)
   → Find button with label "New Note", ID = 5

2. click_element(id: 5)
   → { success: true }
```

### Fill a Text Field

```
1. get_ui_elements(pid: 1234, roles: ["textField", "searchField"])
   → Find text field with ID = 8

2. set_value(id: 8, value: "Hello, world!")
   → { success: true }
```

If `set_value` fails, fall back to:

```
2. type_text(text: "Hello, world!", id: 8)
   → { success: true }
```

### Navigate a Menu

Use keyboard shortcuts when possible. Otherwise:

```
1. click_element(id: <menu_bar_item_id>)
   → Opens menu

2. get_ui_elements(pid: 1234, roles: ["menuItem"])
   → Find the menu item

3. click_element(id: <menu_item_id>)
```

### Right-Click for Context Menu

```
1. click_element(id: 5, button: "right")
   → Opens context menu

2. get_ui_elements(pid: 1234, roles: ["menuItem"])
   → Find context menu items

3. click_element(id: <menu_item_id>)
```

### Handle a Dialog

After an action triggers a dialog:

```
1. get_ui_elements(pid: 1234)
   → Dialog elements appear (buttons like "OK", "Cancel", "Save")

2. click_element(id: <ok_button_id>)
```

### Switch Between Apps

```
1. open_application(identifier: "Safari")
   → Activates Safari, returns its PID

2. get_ui_elements(pid: <safari_pid>)
   → Safari's UI elements
```

Or use keyboard: `press_key("tab", modifiers: ["command"])`

## Safari Web Browsing

Safari's web content is fully accessible through the accessibility tree. Links, buttons, headings, text fields, and other interactive elements all appear in `get_ui_elements`.

### Navigate to a URL

```
1. open_application(identifier: "Safari")
   → { pid: 5678 }

2. press_key("l", modifiers: ["command"])
   → Focuses the address bar

3. type_text(text: "https://example.com")

4. press_key("return")
   → Page loads

5. get_ui_elements(pid: 5678)
   → Web page elements (links, buttons, inputs)
```

### Click a Link on a Web Page

```
1. get_ui_elements(pid: 5678)
   → Find link with label "Sign In", ID = 12

2. click_element(id: 12)
   → Navigates to sign-in page

3. get_ui_elements(pid: 5678)
   → New page elements
```

### Fill a Web Form

```
1. get_ui_elements(pid: 5678, roles: ["textField"])
   → Find email field ID = 15, password field ID = 16

2. set_value(id: 15, value: "user@example.com")
3. set_value(id: 16, value: "password123")
4. click_element(id: <submit_button_id>)
```

### Search the Web

```
1. press_key("l", modifiers: ["command"])
2. type_text(text: "weather in San Francisco")
3. press_key("return")
4. get_ui_elements(pid: 5678)
   → Search results page elements
```

### Tab Management

- **New tab:** `press_key("t", modifiers: ["command"])`
- **Close tab:** `press_key("w", modifiers: ["command"])`
- **Next tab:** `press_key("}", modifiers: ["command", "shift"])`
- **Previous tab:** `press_key("{", modifiers: ["command", "shift"])`
- **Reopen closed tab:** `press_key("z", modifiers: ["command", "shift"])`

### Reading Page Content

Use `get_ui_elements` with `interactiveOnly: false` to read static text on a page. If the page layout matters, use `take_screenshot` to visually inspect it.

### Scrolling a Web Page

```
scroll(direction: "down", amount: 5, x: 700, y: 400)
```

Pass the center of the Safari content area as `x`/`y` to ensure scrolling happens in the right place.

## macOS Keyboard Shortcuts

Use these with `press_key` to avoid navigating menus:

### System

| Action | Key | Modifiers |
|---|---|---|
| Switch app | `tab` | `["command"]` |
| Spotlight search | `space` | `["command"]` |
| Force quit | `escape` | `["command", "option"]` |
| Lock screen | `q` | `["command", "control"]` |
| Screenshot (clipboard) | `3` | `["command", "shift"]` |
| Screenshot (selection) | `4` | `["command", "shift"]` |

### File Operations

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

### Safari

| Action | Key | Modifiers |
|---|---|---|
| Focus address bar | `l` | `["command"]` |
| New tab | `t` | `["command"]` |
| Close tab | `w` | `["command"]` |
| Reload | `r` | `["command"]` |
| Back | `[` | `["command"]` |
| Forward | `]` | `["command"]` |
| Downloads | `l` | `["command", "option"]` |
| Bookmarks | `b` | `["command", "option"]` |
| Reader mode | `r` | `["command", "shift"]` |

### Navigation

| Action | Key | Modifiers |
|---|---|---|
| Next field | `tab` | |
| Previous field | `tab` | `["shift"]` |
| Confirm/submit | `return` | |
| Cancel/dismiss | `escape` | |
| Page up | `pageup` | |
| Page down | `pagedown` | |
| Top of page | `home` | |
| Bottom of page | `end` | |

## Tool Reference

### `open_application`

- Accepts app name (`"Safari"`), bundle ID (`"com.apple.Safari"`), or file path.
- If already running, activates the app. Otherwise launches it.
- Returns `pid`, `bundleId`, and `name`.

### `get_ui_elements`

- Returns interactive elements with assigned IDs. Each element has: `id`, `role`, `label`, `value`, `x`, `y`, `w`, `h`, `actions`.
- IDs are valid until the next `get_ui_elements` call (which resets the cache).
- Use `roles` filter for targeted queries: `["button"]`, `["textField", "textArea"]`, `["link"]`, `["menuItem"]`, etc.
- Common roles: `button`, `link`, `textField`, `textArea`, `checkBox`, `radioButton`, `popUpButton`, `comboBox`, `slider`, `menuItem`, `tab`, `searchField`.

### `click_element`

- Left-click by default. Pass `button: "right"` for right-click. Pass `doubleClick: true` for double-click.
- Uses AXPress action first (most reliable), falls back to coordinate click.
- Returns `{ success: true }` or `{ success: false, error: "..." }`.

### `click`

- Clicks at raw screen coordinates. Only use when elements aren't accessible.
- Supports `button` (left/right/center) and `doubleClick`.

### `type_text`

- Types keystroke-by-keystroke into the focused element.
- Pass `id` to auto-focus an element before typing.
- Use for search fields, password fields, or fields that need on-type events.

### `set_value`

- Directly sets an element's value via accessibility API.
- Preferred over `type_text` for form fields — instant and replaces existing content.
- Returns error if the element isn't editable.

### `press_key`

- Key names: `return`, `escape`, `tab`, `delete`, `space`, `up`, `down`, `left`, `right`, `f1`-`f12`, `home`, `end`, `pageup`, `pagedown`, or single characters (`a`, `1`, `,`, etc.).
- Modifier names: `command`, `shift`, `option`, `control`.

### `scroll`

- Directions: `up`, `down`, `left`, `right`.
- `amount` controls scroll distance in pixels (default: 3). Use higher values (5-10) for faster scrolling.
- Pass `x`/`y` to position the mouse before scrolling (important for scrolling specific areas).

### `drag`

- Drags from (`startX`, `startY`) to (`endX`, `endY`).
- Useful for sliders, window resizing, drag-and-drop, and drawing.

### `take_screenshot`

- Defaults: JPEG format, 0.7 quality, 0.5 scale.
- Pass `pid` to capture a specific app's window.
- Pass `savePath` to save to disk (avoids base64 token costs).
- Returns MCP ImageContent format for vision model consumption.

### `get_active_window`

- Returns: `pid`, `app` name, `title`, `x`, `y`, `w`, `h`.
- Useful when you don't know which app is in front.

### `list_displays`

- Returns all connected displays with index, position, and dimensions.
- Only needed for multi-monitor setups.

## Troubleshooting

### "Element not found"

The element cache was reset or the element is no longer on screen. Call `get_ui_elements` again to refresh.

### "Failed to set element value"

The element may not be editable via accessibility. Fall back to `type_text` with the element `id`.

### No elements returned

- Verify the `pid` is correct (use `get_active_window` to check).
- Some apps have poor accessibility support. Try `take_screenshot` and use coordinate-based `click` instead.
- For web content in Safari, ensure the page has fully loaded before querying elements.

### Stale element positions

Elements may move after window resize or scroll. Call `get_ui_elements` again if coordinate-based fallback clicks miss.

### Accessibility permission denied

The host application needs Accessibility permission in System Settings > Privacy & Security > Accessibility.

## Limitations

- **Canvas-based apps** (Figma, games) — No element tree. Use `take_screenshot` + `click` with coordinates.
- **Poorly accessible apps** — Some apps don't expose their UI through accessibility APIs. Use screenshot-guided coordinate clicks as fallback.
- **Complex web apps** — Very dynamic SPAs may have elements that appear/disappear rapidly. Re-observe frequently and use shorter `maxElements`.
- **Element modification** — Cannot reorder, resize, or restyle UI elements. This plugin observes and interacts with the existing UI.
