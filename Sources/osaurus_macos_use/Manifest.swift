import Foundation

// MARK: - Plugin Manifest
//
// Static JSON manifest returned via the C ABI's `get_manifest` callback.
// Kept as a single string literal so the binary has zero external file
// dependencies. See [Plugin.swift](Plugin.swift) for the routing layer.

enum PluginManifest {
  static let json: String = """
    {
      "plugin_id": "osaurus.macos-use",
      "name": "macOS Use",
      "description": "Backgrounded computer-use driver for macOS. Cursor never moves, focus never changes, Spaces never follow. Routes input via SkyLight + per-pid CGEvent channels (cua-driver recipe) so the agent can drive any Mac app while the user keeps working in the foreground. Workflow: list_apps OR open_application -> list_windows -> get_ui_elements (default mode='som' returns AX tree + screenshot + element_index) -> click_element/set_value/type_text by snapshot id -> if 'stale: true' is returned, observe again. Pass `pid` to action tools (or rely on the most-recent snapshot's pid) so input lands in the right app without warping the cursor.",
      "license": "MIT",
      "authors": ["Dinoki Labs"],
      "min_macos": "13.0",
      "min_osaurus": "0.5.0",
      "capabilities": {
        "tools": [
          {
            "id": "open_application",
            "description": "Launch (if needed) and prepare an app for backgrounded driving. By default `background: true` — the app's window is NOT raised and the user's foreground app is untouched. Returns pid, name, bundleId, and an initial snapshot (`mode`-shaped) so the next step can act immediately.",
            "parameters": {
              "type": "object",
              "properties": {
                "identifier": { "type": "string", "description": "Application name (e.g. 'Safari'), bundle id (e.g. 'com.apple.Safari'), or path." },
                "observe": { "type": "boolean", "description": "Include initial capture in result (default: true)." },
                "maxElements": { "type": "integer", "description": "Max elements in initial snapshot (default: 150)." },
                "mode": { "type": "string", "description": "Capture mode: 'som' (default; AX tree + annotated screenshot + element_index), 'ax' (tree only, fastest), 'vision' (screenshot only)." },
                "background": { "type": "boolean", "description": "Default: true. Set to false only when the user genuinely needs to look at the target window — this is the one path that pulls the app forward and may drag Spaces." },
                "narration": { "type": "string", "description": "Optional human-readable label kept in the session log." }
              },
              "required": ["identifier"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "list_apps",
            "description": "List all running GUI apps (regular activation policy) with pid, name, bundleId, active, hidden. Use this before open_application when you want to attach to something already running without bringing it forward.",
            "parameters": { "type": "object", "properties": {} },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "list_windows",
            "description": "List all windows for a pid with their CGWindowID, title, focused/minimized flags, and bounds. Use the returned `windowId` with `take_screenshot` (windowId arg) and `get_ui_elements` (windowId arg via find_elements) to address one specific window without raising it.",
            "parameters": {
              "type": "object",
              "properties": {
                "pid": { "type": "integer", "description": "Process id from list_apps or open_application." }
              },
              "required": ["pid"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "get_ui_elements",
            "description": "Capture the accessibility tree for a pid. Returns either a TraversalResult (mode='ax') or an SOMResult (mode='som'/'vision') with AX tree + screenshot + an `elements[]` array carrying both the snapshot id ('s7-12') and an `elementIndex` (1, 2, 3, …) for vision-first agents that prefer numeric indexing.",
            "parameters": {
              "type": "object",
              "properties": {
                "pid": { "type": "integer", "description": "Process ID (from open_application or list_apps)." },
                "mode": { "type": "string", "description": "'som' (default), 'ax' (tree only, no Screen Recording permission needed), or 'vision' (screenshot + element_index only)." },
                "windowId": { "type": "integer", "description": "Optional CGWindowID from list_windows; SOM/vision modes will capture exactly that window." },
                "maxElements": { "type": "integer", "description": "Maximum number of elements to return (default: 150). If 'truncated: true' in the response, increase or use find_elements." },
                "maxDepth": { "type": "integer", "description": "Maximum tree depth (default: 20)." },
                "interactiveOnly": { "type": "boolean", "description": "Only return interactive elements (default: true)." },
                "roles": {
                  "type": "array",
                  "items": { "type": "string" },
                  "description": "Filter to specific roles. Common: button, link, textfield, textarea, checkbox, radiobutton, popupbutton, combobox, searchfield, slider, menuitem, tab, row, cell, image, heading, webarea."
                },
                "focusedWindowOnly": { "type": "boolean", "description": "Restrict traversal to the focused window." }
              },
              "required": ["pid"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "find_elements",
            "description": "Server-side search for elements by label/value/placeholder text and/or role. Cheaper than scanning a get_ui_elements result by hand. Returns a TraversalResult; matched elements are cached and immediately usable with click_element, set_value, etc.",
            "parameters": {
              "type": "object",
              "properties": {
                "pid": { "type": "integer", "description": "Process ID." },
                "text": { "type": "string", "description": "Case-insensitive substring matched against label, value, placeholder, and role description." },
                "role": { "type": "string", "description": "Restrict to a single role (canonical or AX form)." },
                "roles": { "type": "array", "items": { "type": "string" }, "description": "Restrict to multiple roles." },
                "windowId": { "type": "integer", "description": "Restrict to a specific window from a previous snapshot's windows[]." },
                "enabledOnly": { "type": "boolean", "description": "Only return enabled elements (default: false)." },
                "limit": { "type": "integer", "description": "Maximum number of results (default: 10)." }
              },
              "required": ["pid"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "get_active_window",
            "description": "Returns the currently active window's pid, app name, title, and bounds. Useful when you don't yet have a pid and want to discover the foreground app.",
            "parameters": { "type": "object", "properties": {} },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "click_element",
            "description": "Click an element by its snapshot id ('s7-12'). Always tries AXPress first (fully backgrounded, no cursor warp). Falls back to a per-pid SkyLight click at the element's center. Final fallback is the HID tap which moves the user's cursor — hits a small set of canvas/Blender/Unity-style apps. NOTE on Chromium right-click: the renderer-IPC layer coerces synthetic right-clicks on web content to left-clicks. AXShowMenu (which click_element prefers) is the only reliable right-click path for those targets.",
            "parameters": {
              "type": "object",
              "properties": {
                "id": { "type": "string", "description": "Snapshot-scoped element id (e.g. 's7-12') from get_ui_elements or find_elements." },
                "button": { "type": "string", "description": "'left' (default) or 'right'." },
                "doubleClick": { "type": "boolean", "description": "Perform a double-click (default: false)." },
                "narration": { "type": "string", "description": "Optional log line." }
              },
              "required": ["id"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "click",
            "description": "Click at raw screen coordinates. With `pid`, routes per-pid (SkyLight when available — no cursor warp). Without `pid`, falls back to the global HID tap which warps the cursor. Prefer click_element whenever you have a snapshot id.",
            "parameters": {
              "type": "object",
              "properties": {
                "x": { "type": "number", "description": "X coordinate (global screen pixels)." },
                "y": { "type": "number", "description": "Y coordinate (global screen pixels)." },
                "pid": { "type": "integer", "description": "Target app pid; routes per-pid for backgrounded delivery." },
                "button": { "type": "string", "description": "'left' (default), 'right', or 'center'." },
                "doubleClick": { "type": "boolean", "description": "Perform a double-click (default: false)." },
                "narration": { "type": "string", "description": "Optional log line." }
              },
              "required": ["x", "y"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "type_text",
            "description": "Type text into the focused element. With `id` (a snapshot id), focuses that element first AND clears it (replace=true by default). With `pid` (or implicitly, the pid derived from `id` or the most-recent snapshot), keystrokes are routed per-pid via CGEvent.postToPid — the user can keep typing in their own app. Without any pid hint, falls back to the HID tap (visible to the user). If the snapshot id is stale, returns 'stale: true' and the agent should re-observe.",
            "parameters": {
              "type": "object",
              "properties": {
                "text": { "type": "string", "description": "Text to type." },
                "id": { "type": "string", "description": "Optional snapshot-scoped element id to focus before typing." },
                "pid": { "type": "integer", "description": "Optional explicit target pid; overrides the pid derived from `id`." },
                "replace": { "type": "boolean", "description": "When 'id' is provided, clear the field first (default: true). Set false to append." },
                "narration": { "type": "string", "description": "Optional log line." }
              },
              "required": ["text"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "set_value",
            "description": "Directly set a text field's value via accessibility (kAXValueAttribute). Instant and replaces existing content. Preferred over type_text for forms when the field is AX-editable. REQUIRES a recent snapshot id; if 'stale: true' is returned, observe again.",
            "parameters": {
              "type": "object",
              "properties": {
                "id": { "type": "string", "description": "Snapshot-scoped element id." },
                "value": { "type": "string", "description": "Value to set." },
                "narration": { "type": "string", "description": "Optional log line." }
              },
              "required": ["id", "value"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "clear_field",
            "description": "Clear a text field by snapshot id. Tries set_value(\\\"\\\") first, falls back to focus + Cmd+A + delete (routed per-pid).",
            "parameters": {
              "type": "object",
              "properties": {
                "id": { "type": "string", "description": "Snapshot-scoped element id." },
                "narration": { "type": "string", "description": "Optional log line." }
              },
              "required": ["id"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "press_key",
            "description": "Press a keyboard key with optional modifiers. With `pid` (or the most-recent snapshot's pid), routes per-pid so the keystroke lands in that app without affecting the user's frontmost window.",
            "parameters": {
              "type": "object",
              "properties": {
                "key": { "type": "string", "description": "Key name: 'return', 'escape', 'tab', 'delete', 'space', 'up', 'down', 'left', 'right', 'f1'-'f12', 'home', 'end', 'pageup', 'pagedown', or a single character." },
                "modifiers": { "type": "array", "items": { "type": "string" }, "description": "'command', 'shift', 'option', 'control'." },
                "pid": { "type": "integer", "description": "Optional. App pid to route to AND to compute the post-action focus delta against." },
                "narration": { "type": "string", "description": "Optional log line." }
              },
              "required": ["key"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "scroll",
            "description": "Scroll in a direction. With `pid`, routes per-pid (no cursor warp). Without `pid`, optionally moves the global cursor first (legacy behavior).",
            "parameters": {
              "type": "object",
              "properties": {
                "direction": { "type": "string", "description": "'up', 'down', 'left', or 'right'." },
                "amount": { "type": "integer", "description": "Pixels to scroll (default: 3). Use 5-10 for faster scrolling." },
                "pid": { "type": "integer", "description": "Target app pid for backgrounded scroll routing." },
                "x": { "type": "number", "description": "[no-pid path only] Optional X to move mouse to before scrolling." },
                "y": { "type": "number", "description": "[no-pid path only] Optional Y to move mouse to before scrolling." },
                "narration": { "type": "string", "description": "Optional log line." }
              },
              "required": ["direction"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "drag",
            "description": "Drag from one screen coordinate to another. NOTE: drag is one operation that genuinely needs the cursor to move (most drag-receivers key on the global mouse position) so it ALWAYS warps the cursor. The mouse button is always released even on errors so a stuck-down mouse cannot happen.",
            "parameters": {
              "type": "object",
              "properties": {
                "startX": { "type": "number" },
                "startY": { "type": "number" },
                "endX": { "type": "number" },
                "endY": { "type": "number" },
                "pid": { "type": "integer", "description": "Optional target pid; events still hit the HID tap but the per-pid route is used when available." },
                "narration": { "type": "string", "description": "Optional log line." }
              },
              "required": ["startX", "startY", "endX", "endY"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "act_and_observe",
            "description": "Run a single action and immediately re-observe in one call. Eliminates the 'forgot to re-observe after navigation' failure mode. Returns { action, snapshot? | som? }.",
            "parameters": {
              "type": "object",
              "properties": {
                "action": { "type": "string", "description": "One of: click_element, set_value, type_text, press_key, clear_field." },
                "id": { "type": "string", "description": "Snapshot id for element-targeted actions." },
                "value": { "type": "string", "description": "Value (for set_value)." },
                "text": { "type": "string", "description": "Text (for type_text)." },
                "key": { "type": "string", "description": "Key name (for press_key)." },
                "modifiers": { "type": "array", "items": { "type": "string" }, "description": "Modifiers (for press_key)." },
                "button": { "type": "string", "description": "Mouse button (for click_element)." },
                "doubleClick": { "type": "boolean", "description": "Double-click (for click_element)." },
                "replace": { "type": "boolean", "description": "Replace flag (for type_text)." },
                "narration": { "type": "string", "description": "Optional log line." },
                "pid": { "type": "integer", "description": "App pid for the post-action capture. Defaults to pid derived from 'id' or the most recently observed pid." },
                "windowId": { "type": "integer", "description": "Optional CGWindowID for the post-action capture." },
                "mode": { "type": "string", "description": "'som' (default), 'ax', or 'vision'." },
                "observe": { "type": "string", "description": "'full' (default), 'focused_window', or 'none'." },
                "maxElements": { "type": "integer", "description": "Max elements in the snapshot (default: 150)." }
              },
              "required": ["action"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "take_screenshot",
            "description": "Capture a screenshot. Defaults: jpeg, quality 0.7, scale 0.5. Pass `windowId` to capture exactly one window (works for occluded / off-Space windows). Set 'annotate: true' (with `pid` or `windowId`) to overlay element ids from the most recent snapshot.",
            "parameters": {
              "type": "object",
              "properties": {
                "pid": { "type": "integer", "description": "Capture this app's largest window." },
                "windowId": { "type": "integer", "description": "Capture exactly this CGWindowID. Get one from list_windows." },
                "displayIndex": { "type": "integer", "description": "Display index (0 = main). Use list_displays for available indices." },
                "allDisplays": { "type": "boolean", "description": "Capture all displays as one image." },
                "format": { "type": "string", "description": "'jpeg' (default) or 'png'." },
                "quality": { "type": "number", "description": "JPEG quality 0.0-1.0 (default: 0.7)." },
                "scale": { "type": "number", "description": "Scale factor 0.0-1.0 (default: 0.5)." },
                "savePath": { "type": "string", "description": "Save to file instead of returning base64." },
                "annotate": { "type": "boolean", "description": "Overlay element-id labels from the most recent snapshot (default: false)." }
              }
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "list_displays",
            "description": "List all connected displays with positions and dimensions.",
            "parameters": { "type": "object", "properties": {} },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "start_automation_session",
            "description": "Record a session title and optional step count. v0.4 removed the on-screen HUD and the global Esc-cancel monitor — backgrounded automations are invisible to the user and there's nothing to interrupt. The session tools remain as a side-effect-free telemetry channel: callers can read back state via the same response shape.",
            "parameters": {
              "type": "object",
              "properties": {
                "title": { "type": "string", "description": "Plain-language title (e.g. 'Setting up iCloud Backup')." },
                "totalSteps": { "type": "integer", "description": "Optional. Stored on the session for tooling." },
                "narration": { "type": "string", "description": "Optional initial narration line." }
              },
              "required": ["title"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "update_automation_session",
            "description": "Update title/narration/step counter on the current session. Side-effect-free; no UI change.",
            "parameters": {
              "type": "object",
              "properties": {
                "title": { "type": "string" },
                "narration": { "type": "string" },
                "stepIndex": { "type": "integer" },
                "totalSteps": { "type": "integer" }
              }
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "end_automation_session",
            "description": "Reset the session record. Optional, since session state is purely informational now.",
            "parameters": {
              "type": "object",
              "properties": {
                "reason": { "type": "string", "description": "Optional: 'complete' | 'aborted' | 'error'." }
              }
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          }
        ]
      }
    }
    """
}
