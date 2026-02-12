# osaurus-macos-use

An Osaurus plugin for efficient macOS automation via accessibility APIs. Features decoupled actions/observations, element-based interactions, and smart filtering for minimal context usage.

## Prerequisites

**Accessibility permissions are required.** Grant permission in:

- System Settings > Privacy & Security > Accessibility

Add the application using this plugin (e.g., Osaurus, or your terminal if running from CLI).

## Architecture

This plugin separates **actions** (click, type, press key) from **observations** (get UI elements), allowing agents to:

1. Observe the UI once to understand the layout
2. Execute multiple actions without re-observing
3. Observe again only when needed (after navigation, dialogs, etc.)

This dramatically reduces context usage compared to returning the full UI tree after every action.

## Tools

### Action Tools (Lean responses ~100 tokens)

| Tool | Description |
|---|---|
| `open_application` | Opens or activates an app by name, bundle ID, or path. Returns PID. |
| `click_element` | Clicks an element by ID. Supports left/right/double-click. Uses AXPress when available. |
| `click` | Clicks at raw screen coordinates. Fallback for canvas apps and screenshot-guided clicks. |
| `type_text` | Types text into the focused element. Optional `id` to auto-focus first. |
| `set_value` | Directly sets a text field's value. More reliable than `type_text` for forms. |
| `press_key` | Presses a keyboard key with optional modifiers. |
| `scroll` | Scrolls in a direction. Optional `x`/`y` to position mouse first. |
| `drag` | Drags from one screen coordinate to another. |

### Observation Tools (On-demand ~2-5K tokens)

| Tool | Description |
|---|---|
| `get_ui_elements` | Traverses the accessibility tree and returns interactive elements with IDs. |
| `get_active_window` | Returns the active window's PID, app name, title, and bounds. |
| `take_screenshot` | Captures a screenshot in MCP ImageContent format. Defaults: JPEG, 0.7 quality, 0.5 scale. |
| `list_displays` | Lists all connected displays with positions and dimensions. |

## Typical Workflow

```
1. open_application({ "identifier": "Notes" })
   → { "pid": 1234, "name": "Notes" }

2. get_ui_elements({ "pid": 1234 })
   → Returns 30 elements with IDs 1-30

3. click_element({ "id": 5 })
   → { "success": true }

4. type_text({ "text": "My note content" })
   → { "success": true }

5. press_key({ "key": "s", "modifiers": ["command"] })
   → { "success": true }
```

**Token usage: ~3K** vs **~150K** with the old approach (returning full tree after every action).

## Best Use Cases

- **Native macOS apps** (Finder, Mail, Notes, System Settings) — Full AX action support
- **Safari web browsing** — Web content elements (links, buttons, inputs) are accessible via the AX tree
- **Browser chrome** (tabs, bookmarks, toolbar) — Good AX support
- **Well-built Electron apps** — Varies by implementation

## Limitations

- **Canvas-based apps** (Figma, games) — Coordinate clicks only, no element tree
- **Poorly accessible apps** — Falls back to coordinate-based interaction

## Development

Build:

```bash
swift build -c release
```

Install locally:

```bash
osaurus manifest extract .build/release/libosaurus-macos-use.dylib
osaurus tools package osaurus.macos-use 0.2.0
osaurus tools install ./osaurus.macos-use-0.2.0.zip
```

## Publishing

This project includes a GitHub Actions workflow (`.github/workflows/release.yml`) that automatically builds and releases the plugin when you push a version tag.

```bash
git tag v0.2.0
git push origin v0.2.0
```

## License

MIT
