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
      "description": "Automate macOS through accessibility APIs. While running, a floating HUD shows the user what's happening and lets them press Esc to stop. For multi-step flows (especially when the user is watching), call start_automation_session first and pass a 'narration' string on each action so the HUD reads naturally. Workflow: open_application -> find_elements OR get_ui_elements -> act on element ids (with narration) -> if 'stale: true' is returned, observe again. If 'cancelled: true' is returned, the user pressed Esc; stop and surface that to the user.",
      "license": "MIT",
      "authors": ["Dinoki Labs"],
      "min_macos": "13.0",
      "min_osaurus": "0.5.0",
      "capabilities": {
        "tools": [
          {
            "id": "open_application",
            "description": "Opens or activates an app and (by default) returns an initial UI snapshot in the same response. Always use this first; do NOT send any input to a newly opened app before reading its snapshot. Returns pid, name, bundleId, and snapshot{ elements[], windows[], focusedWindow, truncated }.",
            "parameters": {
              "type": "object",
              "properties": {
                "identifier": { "type": "string", "description": "Application name (e.g. 'Safari'), bundle id (e.g. 'com.apple.Safari'), or path." },
                "observe": { "type": "boolean", "description": "Include initial snapshot in result (default: true). Set to false only if you intend to call get_ui_elements yourself immediately." },
                "maxElements": { "type": "integer", "description": "Max elements in initial snapshot (default: 150)." },
                "narration": { "type": "string", "description": "Short human-readable description shown in the HUD (e.g. 'Opening System Settings'). Optional but strongly recommended for supervised flows." }
              },
              "required": ["identifier"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "get_ui_elements",
            "description": "Traverse the accessibility tree for a pid and return a snapshot of interactive elements with snapshot-scoped string ids (e.g. 's7-12'). Each element includes role, label, value, placeholder, path, windowId, focused, enabled, x/y/w/h, and supported actions. Element ids are valid until the cache rotates them out (typically after 2 more snapshots). Prefer find_elements when you already know what you are looking for.",
            "parameters": {
              "type": "object",
              "properties": {
                "pid": { "type": "integer", "description": "Process ID (from open_application or get_active_window)." },
                "maxElements": { "type": "integer", "description": "Maximum number of elements to return (default: 150). If 'truncated: true' is returned in the response, increase this or use find_elements." },
                "maxDepth": { "type": "integer", "description": "Maximum tree depth (default: 20)." },
                "interactiveOnly": { "type": "boolean", "description": "Only return interactive elements (default: true)." },
                "roles": {
                  "type": "array",
                  "items": { "type": "string" },
                  "description": "Filter to specific roles. Accepts canonical short names ('button', 'textfield') or AX names ('AXButton'); both work. Common roles: button, link, textfield, textarea, checkbox, radiobutton, popupbutton, combobox, searchfield, slider, menuitem, tab, row, cell, image, heading, webarea."
                },
                "focusedWindowOnly": { "type": "boolean", "description": "Restrict traversal to the focused window (skips menu bar / other windows). Useful for cheap re-observation." }
              },
              "required": ["pid"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "find_elements",
            "description": "Server-side search for elements by label/value/placeholder text and/or role. Cheaper and more reliable than scanning a get_ui_elements result by hand. Returns the same snapshot shape; matched elements are cached and immediately usable with click_element, set_value, etc.",
            "parameters": {
              "type": "object",
              "properties": {
                "pid": { "type": "integer", "description": "Process ID." },
                "text": { "type": "string", "description": "Case-insensitive substring matched against label, value, placeholder, and role description." },
                "role": { "type": "string", "description": "Restrict to a single role (canonical or AX form)." },
                "roles": { "type": "array", "items": { "type": "string" }, "description": "Restrict to multiple roles." },
                "windowId": { "type": "integer", "description": "Restrict to a specific window from a previous snapshot's windows[]." },
                "enabledOnly": { "type": "boolean", "description": "Only return enabled elements (default: false)." },
                "limit": { "type": "integer", "description": "Maximum number of results (default: 10). Bias low; you usually want one." }
              },
              "required": ["pid"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "get_active_window",
            "description": "Returns the currently active window's pid, app name, title, and bounds. Useful when you do not yet have a pid and want to discover the frontmost app.",
            "parameters": { "type": "object", "properties": {} },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "click_element",
            "description": "Clicks an element by its snapshot id (e.g. 's7-12'). Uses AXPress when available, falls back to coordinate click. REQUIRES a recent get_ui_elements/find_elements snapshot for this pid. If response includes 'stale: true', call get_ui_elements again before retrying. If 'removed: true', the element is gone; re-observe and find a new one. If 'cancelled: true', the user pressed Esc; stop. Successful results include a 'delta' with the post-action focused window/element so you can decide whether to re-observe.",
            "parameters": {
              "type": "object",
              "properties": {
                "id": { "type": "string", "description": "Snapshot-scoped element id (e.g. 's7-12') from get_ui_elements or find_elements." },
                "button": { "type": "string", "description": "'left' (default) or 'right'." },
                "doubleClick": { "type": "boolean", "description": "Perform a double-click (default: false)." },
                "narration": { "type": "string", "description": "Short HUD message for this step (e.g. 'Clicking Continue'). Recommended for supervised flows." }
              },
              "required": ["id"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "click",
            "description": "Click at raw screen coordinates. Last-resort fallback for canvas/non-accessible apps. Prefer click_element whenever you have a snapshot id.",
            "parameters": {
              "type": "object",
              "properties": {
                "x": { "type": "number", "description": "X coordinate (global screen pixels)." },
                "y": { "type": "number", "description": "Y coordinate (global screen pixels)." },
                "button": { "type": "string", "description": "'left' (default), 'right', or 'center'." },
                "doubleClick": { "type": "boolean", "description": "Perform a double-click (default: false)." },
                "narration": { "type": "string", "description": "Short HUD message for this step." }
              },
              "required": ["x", "y"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "type_text",
            "description": "Types text into the focused element. If 'id' is passed, focuses that element first AND clears it (replace=true by default) so typing replaces rather than appends. REQUIRES a recent snapshot when using 'id'. Without 'id', types into whatever currently has focus. Cancellation: if the user presses Esc mid-type, the call returns with 'cancelled: true' typically within one character.",
            "parameters": {
              "type": "object",
              "properties": {
                "text": { "type": "string", "description": "Text to type." },
                "id": { "type": "string", "description": "Optional snapshot-scoped element id to focus before typing." },
                "replace": { "type": "boolean", "description": "When 'id' is provided, clear the field first (default: true). Set false to append." },
                "narration": { "type": "string", "description": "Short HUD message for this step (e.g. 'Entering your email')." }
              },
              "required": ["text"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "set_value",
            "description": "Directly sets a text field's value via accessibility. Instant and replaces existing content. Preferred over type_text for forms when the field is AX-editable. REQUIRES a recent snapshot id; if 'stale: true' is returned, call get_ui_elements again. Falls back to type_text if it returns an error.",
            "parameters": {
              "type": "object",
              "properties": {
                "id": { "type": "string", "description": "Snapshot-scoped element id." },
                "value": { "type": "string", "description": "Value to set." },
                "narration": { "type": "string", "description": "Short HUD message for this step." }
              },
              "required": ["id", "value"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "clear_field",
            "description": "Clears a text field by snapshot id. Tries set_value(\\\"\\\") first, falls back to focus + Cmd+A + delete. Useful before type_text when you want to replace existing content but the field is not AX-editable. REQUIRES a recent snapshot id; if 'stale: true' is returned, observe again.",
            "parameters": {
              "type": "object",
              "properties": {
                "id": { "type": "string", "description": "Snapshot-scoped element id." },
                "narration": { "type": "string", "description": "Short HUD message for this step." }
              },
              "required": ["id"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "press_key",
            "description": "Presses a keyboard key with optional modifiers. Useful for shortcuts (Cmd+S, Cmd+L), navigation (return, escape, tab), and arrow keys. Pass 'pid' to get a focus delta back so you can decide whether to re-observe.",
            "parameters": {
              "type": "object",
              "properties": {
                "key": { "type": "string", "description": "Key name: 'return', 'escape', 'tab', 'delete', 'space', 'up', 'down', 'left', 'right', 'f1'-'f12', 'home', 'end', 'pageup', 'pagedown', or a single character." },
                "modifiers": { "type": "array", "items": { "type": "string" }, "description": "'command', 'shift', 'option', 'control'." },
                "pid": { "type": "integer", "description": "Optional. App pid to compute the post-action focus delta against. Defaults to the most recently observed pid." },
                "narration": { "type": "string", "description": "Short HUD message for this step (e.g. 'Pressing Cmd+S to save')." }
              },
              "required": ["key"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "scroll",
            "description": "Scrolls in a direction. Pass 'x'/'y' to position the mouse first (important for scrolling a specific area like a Safari content area).",
            "parameters": {
              "type": "object",
              "properties": {
                "direction": { "type": "string", "description": "'up', 'down', 'left', or 'right'." },
                "amount": { "type": "integer", "description": "Pixels to scroll (default: 3). Use 5-10 for faster scrolling." },
                "x": { "type": "number", "description": "Optional X to move mouse to before scrolling." },
                "y": { "type": "number", "description": "Optional Y to move mouse to before scrolling." },
                "narration": { "type": "string", "description": "Short HUD message for this step." }
              },
              "required": ["direction"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "drag",
            "description": "Drags from one screen coordinate to another. Use for sliders, window resize/move, drag-and-drop. NOTE: drag is uninterruptible mid-flight (the mouse button is always released even on errors) so a stuck-down mouse cannot happen.",
            "parameters": {
              "type": "object",
              "properties": {
                "startX": { "type": "number" },
                "startY": { "type": "number" },
                "endX": { "type": "number" },
                "endY": { "type": "number" },
                "narration": { "type": "string", "description": "Short HUD message for this step." }
              },
              "required": ["startX", "startY", "endX", "endY"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "act_and_observe",
            "description": "Run a single action and immediately re-observe in one call. Eliminates the 'forgot to re-observe after navigation' failure mode. Returns { action: <action result>, snapshot: <traversal result> }.",
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
                "narration": { "type": "string", "description": "Short HUD message for this step." },
                "pid": { "type": "integer", "description": "App pid for the snapshot. Defaults to pid derived from 'id' or the most recently observed pid." },
                "observe": { "type": "string", "description": "'full' (default), 'focused_window' (cheaper), or 'none'." },
                "maxElements": { "type": "integer", "description": "Max elements in the snapshot (default: 150)." }
              },
              "required": ["action"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "take_screenshot",
            "description": "Capture a screenshot. Defaults: jpeg, quality 0.7, scale 0.5. Set 'annotate: true' (with 'pid') to overlay element ids from the most recent snapshot so you can reference them visually.",
            "parameters": {
              "type": "object",
              "properties": {
                "pid": { "type": "integer", "description": "Capture only this app's frontmost window." },
                "displayIndex": { "type": "integer", "description": "Display index (0 = main). Use list_displays for available indices." },
                "allDisplays": { "type": "boolean", "description": "Capture all displays as one image." },
                "format": { "type": "string", "description": "'jpeg' (default) or 'png'." },
                "quality": { "type": "number", "description": "JPEG quality 0.0-1.0 (default: 0.7)." },
                "scale": { "type": "number", "description": "Scale factor 0.0-1.0 (default: 0.5)." },
                "savePath": { "type": "string", "description": "Save to file instead of returning base64." },
                "annotate": { "type": "boolean", "description": "Overlay element-id labels from the most recent snapshot for this pid (default: false)." }
              }
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "list_displays",
            "description": "Lists all connected displays with positions and dimensions.",
            "parameters": { "type": "object", "properties": {} },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "start_automation_session",
            "description": "Starts a user-visible automation session: shows the floating HUD with a clear title and enables Esc-to-cancel. Strongly recommended at the beginning of any multi-step flow, especially when the user is watching (e.g. configuring macOS, helping an elderly user). Calling this while a session is already active supersedes the previous one.",
            "parameters": {
              "type": "object",
              "properties": {
                "title": { "type": "string", "description": "Plain-language title shown in the HUD (e.g. 'Setting up iCloud Backup')." },
                "totalSteps": { "type": "integer", "description": "Optional. Enables 'Step N of M' progress text in the HUD." },
                "narration": { "type": "string", "description": "Optional initial narration line (e.g. 'Opening System Settings')." }
              },
              "required": ["title"]
            },
            "requirements": ["accessibility"],
            "permission_policy": "ask"
          },
          {
            "id": "update_automation_session",
            "description": "Updates the HUD's title, narration, or step counter without performing an action. Use sparingly; prefer the per-action 'narration' arg when you're already calling another tool.",
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
            "description": "Hides the HUD, stops the Esc listener, and resets the cancellation flag. Call when your flow is finished. Idle sessions auto-end after ~3 seconds of no tool calls, so this is optional but cleaner.",
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
