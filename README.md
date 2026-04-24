# osaurus-macos-use

An Osaurus plugin for **backgrounded** macOS automation. The agent drives any Mac app while the user keeps working in the foreground — cursor never moves, focus never changes, Spaces never follow. Built on the [cua-driver](https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md) recipe (SkyLight `SLEventPostToPid`, yabai-style focus-without-raise, Chromium primer click) plus snapshot-scoped element ids and cua-style `ax`/`vision`/`som` capture modes.

See [SKILL.md](SKILL.md) for the agent contract and [REFERENCE.md](REFERENCE.md) for keyboard shortcuts, per-app recipes, and full schemas. See [CHANGELOG.md](CHANGELOG.md) for release notes (latest: v3.0.0 added background-by-default driving and the cua capture modes).

## Prerequisites

Accessibility permissions are required. In System Settings > Privacy & Security > Accessibility, add the application running this plugin (Osaurus, or your terminal if running from CLI). Screen Recording is required only for `mode: "som"` / `mode: "vision"` and `take_screenshot`.

## Workflow

```
list_apps OR open_application  →  list_windows  →  get_ui_elements (mode='som')  →  click_element / set_value / type_text  →  re-observe only on stale/removed
```

Every snapshot has an id (`s7`); every element id includes its snapshot (`s7-12`); failed actions tell you whether to re-observe (`stale: true`), give up on this element (`removed: true`), or that you passed the wrong shape entirely (malformed). The last two snapshots are always retained, so an action immediately after a re-observe still resolves correctly.

`open_application` defaults to `background: true` — the app is launched (or attached to) without ever being raised. Pass `background: false` only when the user genuinely needs to look at the target window.

## Routing chain

Every action picks the most-backgrounded transport that works:

1. **AXPress / AXShowMenu / AXValue** — first choice for `click_element`, `set_value`, `right_click`. Fully backgrounded.
2. **`SLEventPostToPid`** (SkyLight private framework, loaded via `dlopen`) — Chromium-trusted, no cursor warp.
3. **`CGEvent.postToPid`** — public CoreGraphics; works for almost everything except Chromium web content.
4. **HID tap** (`CGEvent.post(.cghidEventTap)`) — final fallback. Warps the cursor; only happens for canvas/Blender/Unity-style apps.

Drag is the one exception: most drop receivers key on the global mouse position, so `drag` always uses the HID tap.

## Tools

### Discovery

| Tool                | Purpose                                                                                                                                                           |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `list_apps`         | All running GUI apps with pid, bundleId, name, active, hidden. Use before `open_application` if the target is already running.                                    |
| `list_windows`      | Per-pid window list with `windowId`, title, focused/minimized, bounds. Pass the `windowId` to `take_screenshot` to capture exactly one window without raising it. |
| `get_active_window` | Frontmost window's pid + title (mostly for figuring out where the user is).                                                                                       |

### Observation (with capture modes)

| Tool               | Purpose                                                                                                                                                                                                                |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `open_application` | Launch (or attach to) an app in background mode and return an initial capture.                                                                                                                                         |
| `get_ui_elements`  | Capture by pid. `mode: "som"` (default) returns AX tree + annotated screenshot + numeric `elementIndex`. `mode: "ax"` is the tree only (fastest, no Screen Recording needed). `mode: "vision"` is the screenshot only. |
| `find_elements`    | Server-side search by text and/or role.                                                                                                                                                                                |

### Element actions (snapshot id required)

| Tool            | Purpose                                                                                |
| --------------- | -------------------------------------------------------------------------------------- |
| `click_element` | Left/right/double click by id. AXPress first → SkyLight per-pid → HID tap.             |
| `set_value`     | Replace a field's value instantly via `kAXValueAttribute`.                             |
| `type_text`     | Keystroke typing routed per-pid (no focus steal). With `id`, focuses + clears + types. |
| `clear_field`   | Empty a field (set_value("") then per-pid Cmd+A + delete fallback).                    |

### Coordinate / keyboard actions

| Tool        | Purpose                                                                                |
| ----------- | -------------------------------------------------------------------------------------- |
| `press_key` | Keyboard shortcuts and special keys. With `pid`, routed per-pid (no foreground steal). |
| `click`     | Coordinate fallback. With `pid`, routes per-pid.                                       |
| `scroll`    | Direction + amount. With `pid`, per-pid (no warp).                                     |
| `drag`      | Coordinate-based drag. Always warps the cursor (drag receivers need it).               |

### Combined / utility

| Tool              | Purpose                                                                                                                                  |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `act_and_observe` | Run an element action AND get a fresh capture (`mode`-shaped) in one call.                                                               |
| `take_screenshot` | JPEG/PNG capture. `windowId` captures exactly one window (works on occluded / off-Space windows). `annotate: true` overlays element ids. |
| `list_displays`   | Multi-monitor info.                                                                                                                      |

### Automation session (telemetry only)

v0.4 removed the on-screen HUD and the global Esc-cancel monitor — backgrounded automations are invisible to the user and there's nothing to interrupt. The session tools remain as a side-effect-free record of the agent's narration, useful for tooling that surfaces a transcript:

| Tool                        | Purpose                                  |
| --------------------------- | ---------------------------------------- |
| `start_automation_session`  | Record a title + total step count.       |
| `update_automation_session` | Update title / narration / step counter. |
| `end_automation_session`    | Reset the record.                        |

## Example

```
1. list_apps()
   → { apps: [..., { pid: 1234, name: "Safari", bundleId: "com.apple.Safari" }, ...] }

2. open_application({ identifier: "Safari", mode: "som" })
   → { pid: 1234, som: { snapshot: {...}, image: { mimeType: "image/jpeg", data: "..." }, elements: [{ elementIndex: 1, id: "s1-3", role: "textfield", label: "Address" }, ...] } }

3. press_key({ key: "l", modifiers: ["command"], pid: 1234 })
4. type_text({ text: "https://example.com", pid: 1234 })
5. press_key({ key: "return", pid: 1234 })

6. find_elements({ pid: 1234, text: "More information", role: "link" })
   → { snapshotId: 2, elements: [{ id: "s2-3", label: "More information..." }] }

7. click_element({ id: "s2-3" })
   → { success: true, delta: { focusedWindow: "IANA-managed Reserved Domains" } }
```

## Best Use Cases

- **Background dev-loop QA**: agent drives the app being tested while the user keeps coding in the foreground.
- **Personal-assistant work**: send a Message, check a calendar, pull a tracking number out of an email, all without taking the user's screen away.
- **Pulling visual context** from apps the user isn't looking at (Figma canvases, Preview windows, Notion docs) — `take_screenshot` with `windowId` reads them where they live, no raise needed.
- Native macOS apps (Finder, Mail, Notes, System Settings) — full AX action support, fully backgrounded.
- Safari web browsing — web content is in the AX tree.
- Well-built Electron apps — varies by implementation.

## Known Gaps

- **Chromium right-click on web content** is coerced to a left-click at the renderer-IPC boundary, even via SkyLight. `click_element` prefers `AXShowMenu` for AX-addressable targets — the only reliable right-click path.
- **Canvas apps (Blender GHOST, Unity, games)** filter per-pid event routes entirely. The driver auto-falls back to the HID tap for these, which warps the cursor.
- The SkyLight bridge is loaded at runtime via `dlopen`. If Apple removes a symbol on a future macOS, the driver gracefully degrades to `CGEvent.postToPid` (still backgrounded, just rejected by Chromium web content).

## Development

Build:

```bash
swift build -c release
```

Test:

```bash
swift test
```

Install locally:

```bash
osaurus manifest extract .build/release/libosaurus-macos-use.dylib
osaurus tools package osaurus.macos-use 3.0.0
osaurus tools install ./osaurus.macos-use-3.0.0.zip
```

## Publishing

A GitHub Actions workflow (`.github/workflows/release.yml`) builds and releases the plugin when you push a version tag.

```bash
git tag v3.0.0
git push origin v3.0.0
```

## License

MIT
