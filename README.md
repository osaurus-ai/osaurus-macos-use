# osaurus-macos-use

An Osaurus plugin for macOS automation via accessibility APIs. Designed for agent ergonomics AND for the human watching: snapshot-scoped element ids, server-side element search, combined act+observe, a visible "Automation in progress" HUD, and system-wide Esc-to-cancel.

See [SKILL.md](SKILL.md) for the agent contract and [REFERENCE.md](REFERENCE.md) for keyboard shortcuts, per-app recipes, and full schemas. See [CHANGELOG.md](CHANGELOG.md) for release notes (latest: v0.3.1 added the HUD and Esc cancel).

## Prerequisites

Accessibility permissions are required. In System Settings > Privacy & Security > Accessibility, add the application running this plugin (Osaurus, or your terminal if running from CLI).

## Workflow

```
open_application  →  find_elements / get_ui_elements  →  click_element / set_value / type_text  →  re-observe only on stale/removed
```

Every snapshot has an id (`s7`); every element id includes its snapshot (`s7-12`); failed actions tell you whether to re-observe (`stale: true`), give up on this element (`removed: true`), or that you passed the wrong shape entirely (malformed). The last two snapshots are always retained, so an action immediately after a re-observe still resolves correctly.

## Tools

### Observation

| Tool | Purpose |
|---|---|
| `open_application` | Opens/activates an app and returns an initial snapshot in the same response. |
| `get_ui_elements` | Full snapshot for a pid. Supports `roles`, `maxElements`, `focusedWindowOnly`. |
| `find_elements` | Server-side search by `text` and/or `role`. Cheap, returns ready-to-use ids. |
| `get_active_window` | Discover the frontmost app's pid. |

### Element actions (snapshot id required)

| Tool | Purpose |
|---|---|
| `click_element` | Left/right/double click by id. Uses AXPress when available. |
| `set_value` | Replace a field's value instantly. |
| `type_text` | Keystroke typing; with `id`, focuses + clears + types (`replace: true` default). |
| `clear_field` | Empty a field (set_value("") then Cmd+A + delete fallback). |

### Coordinate / keyboard actions

| Tool | Purpose |
|---|---|
| `press_key` | Keyboard shortcuts and special keys; pass `pid` for a focus delta. |
| `click` | Coordinate fallback for canvas / non-accessible apps. |
| `scroll` | Direction + amount; `x`/`y` to position the mouse first. |
| `drag` | Coordinate-based drag. |

### Combined / utility

| Tool | Purpose |
|---|---|
| `act_and_observe` | Run an element action AND get a fresh snapshot in one call. |
| `take_screenshot` | JPEG/PNG capture; `annotate: true` overlays element ids. |
| `list_displays` | Multi-monitor info. |

### Automation session (HUD + Esc cancel)

| Tool | Purpose |
|---|---|
| `start_automation_session` | Show the HUD with a title and (optional) `Step N of M` progress. Strongly recommended for any flow >2 actions. |
| `update_automation_session` | Update the HUD's title, narration, or step counter outside an action call. |
| `end_automation_session` | Hide the HUD and reset state when the flow finishes. Idle sessions auto-end after ~3s. |

Every action tool also accepts an optional `narration` string that updates the HUD subtitle ("Clicking Continue", "Entering your email"). The user can press **Esc** any time to stop; the next tool call returns `cancelled: true`.

## Example

```
1. open_application({ identifier: "Safari" })
   → { pid: 1234, snapshot: { snapshotId: 1, elements: [...], focusedWindow: "Start Page" } }

2. press_key({ key: "l", modifiers: ["command"], pid: 1234 })
3. type_text({ text: "https://example.com" })
4. press_key({ key: "return", pid: 1234 })

5. find_elements({ pid: 1234, text: "More information", role: "link" })
   → { snapshotId: 2, elements: [{ id: "s2-3", label: "More information..." }] }

6. click_element({ id: "s2-3" })
   → { success: true, delta: { focusedWindow: "IANA-managed Reserved Domains" } }
```

## Best Use Cases

- Native macOS apps (Finder, Mail, Notes, System Settings) — full AX action support
- Safari web browsing — web content is in the AX tree
- Well-built Electron apps — varies by implementation
- **Supervised multi-step flows** (configuring macOS, helping an elderly user, walking through a setup wizard) — start a session, narrate every step, let the user press Esc to bail

## Limitations

- Canvas apps (Figma, games) — use `take_screenshot` + `click` with coordinates
- Poorly accessible apps — coordinate fallback
- Highly dynamic SPAs — re-observe more often, prefer `find_elements`

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
osaurus tools package osaurus.macos-use 0.3.1
osaurus tools install ./osaurus.macos-use-0.3.1.zip
```

## Publishing

A GitHub Actions workflow (`.github/workflows/release.yml`) builds and releases the plugin when you push a version tag.

```bash
git tag v0.3.1
git push origin v0.3.1
```

## License

MIT
