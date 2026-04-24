---
name: osaurus-macos-use
description: Drive macOS apps in the background. Use when the user asks you to interact with native Mac apps, automate UI tasks, browse the web in Safari, fill forms, navigate menus, or perform any on-screen action — without taking the user's screen or cursor away from them.
metadata:
  author: osaurus
  version: "3.0.0"
---

# Osaurus macOS Use

A backgrounded computer-use driver. Open apps, observe the UI, click buttons, type into fields, navigate menus, browse the web — **all while the user keeps working in the foreground**. Cursor never moves, focus never changes, Spaces never follow.

Built on the cua-driver recipe: SkyLight `SLEventPostToPid` for cursor-warp-free routing, yabai-style `focusWithoutRaise` for AppKit-active flips, the (-1,-1) Chromium primer click for renderer-IPC user-activation gates, and a per-pid `CGEvent.postToPid` fallback for the rest.

## The Contract

Five rules. Follow them in order, every time.

1. **Discover** with `list_apps()` if the target is already running, or skip to step 2 to launch fresh.
2. **Open** with `open_application` (defaults to `background: true` — the app is NOT raised). It returns the app `pid` AND a starting capture (default `mode: "som"` — AX tree + screenshot + numeric `elementIndex` per element). **Read the capture before doing anything else.**
3. **Locate** with `find_elements({ pid, text, role? })` whenever you know what you're looking for. Faster, cheaper, more reliable than scanning a `get_ui_elements` result by hand.
4. **Act** with `click_element`, `set_value`, `type_text`, `clear_field`, `press_key`. Always pass element ids in the `s{snapshot}-{n}` format (e.g. `"s7-12"`). For raw-coordinate `click`/`scroll`/`type_text`/`press_key`, **always pass `pid`** — that's what keeps routing per-pid (no cursor warp).
5. **Re-observe** only when the result tells you to:
   - `"stale": true` → call `get_ui_elements` (or `find_elements`) again, then retry.
   - `"removed": true` → element is gone; observe and find a new one.
   - `delta.focusedWindow` changed in a way you didn't expect → observe again.
   - Otherwise → keep going.

If you'd rather not think about re-observing, use `act_and_observe` — runs an action and returns a fresh capture in one call.

## Capture modes (cua-style)

`open_application`, `get_ui_elements`, and `act_and_observe` accept `mode`:

- **`som`** (default) — AX tree + annotated screenshot + per-element `elementIndex`. Best for vision-first agents that ground on pixels.
- **`ax`** — tree only. Fastest. **No Screen Recording permission needed.** Best for AppKit/SwiftUI apps with rich AX trees.
- **`vision`** — screenshot only. Smallest payload for VLMs that don't need the tree.

In `som` mode, every element is addressable two ways: by snapshot id (`"s7-12"`) AND by `elementIndex` (1, 2, 3, …). Use whichever your model prefers — both resolve to the same element.

## Routing chain

You don't usually need to think about this, but it's useful when debugging:

1. **AXPress / AXShowMenu / AXValue** — `click_element` etc. try this first. Fully backgrounded.
2. **`SLEventPostToPid`** — SkyLight private framework, loaded at runtime. Trusted by Chromium renderers, no cursor warp.
3. **`CGEvent.postToPid`** — public CoreGraphics. Works for almost everything except Chromium web content.
4. **HID tap** — last resort. **This is the only path that warps the user's cursor.** Auto-falls-back here for canvas/Blender/Unity.

`drag` is the one operation that ALWAYS uses the HID tap (drop receivers key on the global cursor position).

## Canonical Recipe

```
1. list_apps()
   → { apps: [..., { pid: 1234, name: "Safari", bundleId: "com.apple.Safari", active: false }, ...] }

2. open_application({ identifier: "Safari", mode: "som" })
   → { pid: 1234, som: { snapshot: { snapshotId: 1, ... }, image: { mimeType: "image/jpeg", data: "..." }, elements: [{ elementIndex: 1, id: "s1-3", role: "textfield", label: "Address" }, ...] } }

3. press_key({ key: "l", modifiers: ["command"], pid: 1234 })
   → { success: true, delta: { focusedElement: { role: "textfield", label: "Address" } } }

4. type_text({ text: "https://example.com", pid: 1234 })
5. press_key({ key: "return", pid: 1234 })

6. find_elements({ pid: 1234, text: "More information", role: "link" })
   → { snapshotId: 2, elements: [{ id: "s2-3", role: "link", label: "More information..." }] }

7. click_element({ id: "s2-3" })
   → { success: true, delta: { focusedWindow: "IANA-managed Reserved Domains" } }
```

The user never sees Safari come forward. Their own app stays focused throughout.

## Snapshot Ids and the Cache

- Element ids look like `s7-12`. The `s7` is the snapshot they came from.
- The plugin keeps the **last 2 snapshots** in cache. Ids from older snapshots return `"stale": true`.
- Each call to `get_ui_elements`, `find_elements`, or `open_application` (with default `observe: true`) **starts a new snapshot** and bumps the counter.
- This means: if you call `find_elements` twice in a row, the ids from the first call become stale on the third call, not the second.

If you ever see a result with `"stale": true`, the fix is always the same: re-observe and retry with the new id.

## Tool Reference

### Discovery / observation

| Tool                    | When to use                                                                                                                              |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `list_apps`             | List all running GUI apps. Use before `open_application` if the target is already up.                                                    |
| `list_windows({ pid })` | Per-pid window list with `windowId`. Pass the windowId to `take_screenshot` (windowId arg) to read a specific window without raising it. |
| `open_application`      | First step for a fresh app. Defaults to `background: true` — never raises. Returns an initial capture in your chosen `mode`.             |
| `get_ui_elements`       | Capture by pid. `mode: "som"` (default) returns tree + screenshot + elementIndex; `"ax"` is tree only; `"vision"` is screenshot only.    |
| `find_elements`         | Server-side search by text and/or role. **Prefer this over `get_ui_elements` whenever you know what you're looking for.**                |
| `get_active_window`     | The user's frontmost window (mostly for figuring out where they are).                                                                    |

### Element actions (snapshot id required)

| Tool            | When to use                                                                                                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `click_element` | Click by snapshot id. `button: "right"` and `doubleClick: true` supported. Tries AXPress first → SkyLight per-pid → HID tap.               |
| `set_value`     | Replace a field's value instantly via AX. Best for forms.                                                                                  |
| `clear_field`   | Empty a text field. Use before `type_text` if you want to replace, not append.                                                             |
| `type_text`     | Keystroke-by-keystroke typing. Pass `id` to focus first; `replace: true` (default) clears the field. Routed per-pid via the element's pid. |

### Coordinate / keyboard actions

| Tool        | When to use                                                                                                                         |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `press_key` | Keyboard shortcuts. Pass `pid` to route per-pid (no foreground steal) AND get a focus delta back.                                   |
| `click`     | Coordinate click. **Always pass `pid`** to keep routing backgrounded. Without it, falls back to the HID tap which warps the cursor. |
| `scroll`    | Direction + amount. Pass `pid` to route per-pid.                                                                                    |
| `drag`      | Coordinate drag. Always uses the HID tap; drop receivers need the cursor to track.                                                  |

### Combined / utility

| Tool              | When to use                                                                                                                           |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `act_and_observe` | Run any element action AND get a fresh capture (`mode`-shaped) in one call.                                                           |
| `take_screenshot` | When you need pixels. `windowId` captures exactly one window (works for occluded / off-Space). `annotate: true` overlays element ids. |
| `list_displays`   | Multi-monitor setups only.                                                                                                            |

### Session telemetry

| Tool                                  | When to use                                                                                       |
| ------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `start_automation_session({ title })` | Optional. Records a title for the agent transcript. **No HUD, no Esc cancel, no UI side effect.** |
| `update_automation_session`           | Update title / narration / step counter.                                                          |
| `end_automation_session`              | Reset the record. Optional.                                                                       |

## Tips That Actually Matter

1. **Pass `pid` to every coordinate-based action** (`click`, `scroll`, `type_text`, `press_key`). Without it, the call falls back to the HID tap and warps the cursor.
2. **`set_value` first, `type_text` if it fails.** `set_value` is instant and correct for most fields. `type_text` (focus + clear + type) is the fallback for search fields, password fields, anything that needs per-keystroke events.
3. **Use `windowId` from `list_windows` when capturing a specific window.** It works for windows that are occluded, hidden, or on a different Space.
4. **Check `truncated: true` in any snapshot.** If true, raise `maxElements` or use `find_elements`.
5. **`focusedWindowOnly: true` is your friend.** Cheap re-observation when the action only changed the focused window.
6. **Keyboard shortcuts beat menu navigation.** `press_key("s", modifiers: ["command"], pid: ...)` is one tool call; clicking File > Save is three.
7. **Roles can be passed in any case.** `"button"`, `"Button"`, and `"AXButton"` all work.

## Troubleshooting

| Symptom                                                    | Fix                                                                                                                                                           |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `"stale": true`                                            | Re-observe (any of `get_ui_elements`, `find_elements`, `open_application`) and retry with the fresh id.                                                       |
| `"removed": true`                                          | The element is gone from the UI. Re-observe and find a new one.                                                                                               |
| Cursor moves during a click                                | You called `click` without `pid`, OR the target is a canvas/game app filtering per-pid routes. Pass `pid`; for canvas apps, accept the warp (it's by design). |
| Right-click on a Chrome web page does a left-click instead | Chromium coerces synthetic right-clicks at the renderer-IPC layer. Use `click_element` on an AX-addressable target so `AXShowMenu` fires instead.             |
| `error` mentions "not a valid snapshot id"                 | You passed a v0.2 integer id. Use the `s{n}-{n}` strings returned by the new tools.                                                                           |
| Empty `elements: []` from `get_ui_elements`                | Check `truncated`; lower `maxDepth`; broaden `interactiveOnly: false`; or use `find_elements`.                                                                |
| `set_value` returns "not editable"                         | Fall back to `type_text` with the element id (auto-focuses and replaces).                                                                                     |
| App won't open / wrong app focused                         | Try the bundle id (`com.apple.Safari`) instead of name. Use `get_active_window` to confirm.                                                                   |
| No elements at all                                         | The host app needs Accessibility permission in System Settings > Privacy & Security > Accessibility.                                                          |

## Reference

For per-app recipes (Safari URL bar, web forms, tab management) and the full keyboard shortcut catalog, see [REFERENCE.md](REFERENCE.md). Don't load it unless you need it — most automation only needs the contract above.

## Limitations

- **Canvas apps** (Figma, games, Blender, Unity): per-pid event routes are filtered. Driver auto-falls back to the HID tap, which warps the cursor.
- **Chromium right-click on web content**: coerced to left-click. Use AX paths instead.
- **Highly dynamic web apps**: re-observe more often; prefer `find_elements` over caching ids across navigation.
- **Iframes**: AX coverage varies. Safari is most reliable.
