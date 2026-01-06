# osaurus-macos-use

An Osaurus plugin for efficient macOS automation via accessibility APIs. Features decoupled actions/observations, element-based interactions, and smart filtering for minimal context usage.

## Prerequisites

**Accessibility permissions are required.** Grant permission in:

- System Preferences > Security & Privacy > Privacy > Accessibility

Add the application using this plugin (e.g., Osaurus, or your terminal if running from CLI).

## Architecture

This plugin separates **actions** (click, type, press key) from **observations** (get UI elements), allowing agents to:

1. Observe the UI once to understand the layout
2. Execute multiple actions without re-observing
3. Observe again only when needed (after navigation, dialogs, etc.)

This dramatically reduces context usage compared to returning the full UI tree after every action.

## Tools

### Core Action Tools (Lean responses ~100 tokens)

#### `open_application`

Opens or activates an application by name, bundle ID, or path.

```json
{ "identifier": "Safari" }
```

Returns: `{ "pid": 1234, "bundleId": "com.apple.Safari", "name": "Safari" }`

#### `click_element`

Clicks an element by its ID (from `get_ui_elements`). Uses AXPress action when available, falls back to coordinate click.

```json
{ "id": 5 }
```

#### `focus_element`

Focuses an element by its ID. Useful for text fields before typing.

```json
{ "id": 3 }
```

#### `click`

Clicks at raw screen coordinates. Use `click_element` instead when possible.

```json
{ "x": 100, "y": 200, "button": "left", "doubleClick": false }
```

#### `type_text`

Types text into the currently focused element.

```json
{ "text": "Hello, world!" }
```

#### `press_key`

Presses a keyboard key with optional modifiers.

```json
{ "key": "return", "modifiers": ["command"] }
```

#### `scroll`

Scrolls in the specified direction.

```json
{ "direction": "down", "amount": 5 }
```

### Observation Tools (On-demand ~2-5K tokens)

#### `get_ui_elements`

Traverses the accessibility tree and returns interactive UI elements with assigned IDs.

```json
{
  "pid": 1234,
  "maxElements": 100,
  "maxDepth": 15,
  "interactiveOnly": true
}
```

Returns compact element array:

```json
{
  "pid": 1234,
  "app": "Safari",
  "elementCount": 25,
  "elements": [
    {
      "id": 1,
      "role": "button",
      "label": "Back",
      "x": 50,
      "y": 100,
      "w": 30,
      "h": 30,
      "actions": ["press"]
    },
    {
      "id": 2,
      "role": "textfield",
      "label": "Address",
      "x": 100,
      "y": 100,
      "w": 400,
      "h": 30,
      "actions": ["focus"]
    }
  ]
}
```

#### `get_active_window`

Returns information about the currently active window.

```json
{}
```

Returns: `{ "pid": 1234, "app": "Safari", "title": "Apple", "x": 0, "y": 25, "w": 1440, "h": 875 }`

#### `list_displays`

Lists all connected displays with their positions and dimensions.

```json
{}
```

Returns:

```json
{
  "displays": [
    {
      "index": 0,
      "displayId": 1,
      "x": 0,
      "y": 0,
      "width": 2560,
      "height": 1440,
      "isMain": true
    },
    {
      "index": 1,
      "displayId": 2,
      "x": 2560,
      "y": 0,
      "width": 1920,
      "height": 1080,
      "isMain": false
    }
  ]
}
```

#### `take_screenshot`

Captures a screenshot with multi-monitor support. Returns images in **MCP ImageContent format** for vision model support.

**Defaults:** `format=jpeg`, `quality=0.7`, `scale=0.5` (suitable for most use cases)

```json
{ "displayIndex": 0 }           // Capture main display
{ "displayIndex": 1 }           // Capture second display
{ "allDisplays": true }         // Capture all displays as one image
{ "pid": 1234 }                 // Capture specific window (works on any display)
{ "savePath": "/tmp/screen.jpg" }  // Save to file instead of base64 (avoids token limits)
{ "scale": 1.0, "format": "png" }  // Full resolution PNG (larger output)
```

Returns MCP ImageContent format (enables vision models to "see" the image):

```json
{
  "type": "image",
  "data": "<base64-encoded-image>",
  "mimeType": "image/jpeg",
  "width": 1440,
  "height": 900
}
```

**Save to file** - Use `savePath` to save the screenshot to disk instead of returning base64. This completely avoids token limit issues:

```json
{ "savePath": "/tmp/screenshot.jpg" }
```

Returns: `{ "width": 1440, "height": 900, "path": "/tmp/screenshot.jpg" }`

### Convenience Tools (Action + Observation combined)

#### `click_element_and_observe`

Clicks an element and returns the updated UI state.

```json
{ "id": 5, "maxElements": 100, "interactiveOnly": true }
```

#### `type_and_observe`

Types text and returns the updated UI state.

```json
{ "text": "Hello", "pid": 1234 }
```

#### `press_key_and_observe`

Presses a key and returns the updated UI state.

```json
{ "key": "return", "pid": 1234 }
```

## Typical Workflow

```
1. open_application({ "identifier": "Notes" })
   → { "pid": 1234, "name": "Notes" }

2. get_ui_elements({ "pid": 1234 })
   → Returns 30 elements with IDs 1-30

3. click_element({ "id": 5 })      // Click "New Note" button
   → { "success": true }

4. type_text({ "text": "My note content" })
   → { "success": true }

5. press_key({ "key": "s", "modifiers": ["command"] })  // Save
   → { "success": true }
```

**Token usage: ~3K** vs **~150K** with the old approach (returning full tree after every action).

## Element-Based Interactions

Elements are identified by numeric IDs assigned during `get_ui_elements`. The plugin:

1. **Tries AXPress action first** - Works regardless of mouse position, immune to user interference
2. **Falls back to coordinate click** - Re-queries element position before clicking to minimize stale data

This makes interactions more reliable than raw coordinate clicks.

## Best Use Cases

- **Native macOS apps** (Finder, Mail, Notes, System Settings) - Full AX action support
- **Browser chrome** (tabs, bookmarks, toolbar) - Good AX support
- **Well-built Electron apps** - Varies by implementation

## Limitations

- **Web content inside browsers** - Use Playwright for better reliability
- **Canvas-based apps** (Figma, games) - Coordinate clicks only, no element tree
- **Poorly accessible apps** - Falls back to coordinate-based interaction

## Development

1. Build:

   ```bash
   swift build -c release
   cp .build/release/libosaurus-macos-use.dylib ./libosaurus-macos-use.dylib
   ```

2. Install locally:
   ```bash
   osaurus tools install .
   ```

## Publishing

### Code Signing (Required for Distribution)

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  .build/release/libosaurus-macos-use.dylib
```

### Package and Distribute

```bash
osaurus tools package osaurus.macos-use 0.2.0
```

## License

MIT
