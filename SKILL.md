---
name: osaurus-macos-use
description: Control macOS via accessibility APIs. Use when the user asks to interact with native Mac apps, automate UI tasks, browse the web in Safari, fill forms, navigate menus, or perform any on-screen action.
metadata:
  author: osaurus
  version: "0.3.1"
---

# Osaurus macOS Use

Automate macOS through the accessibility tree: open apps, observe the UI, click buttons, type into fields, navigate menus, browse the web.

## The Contract

Four rules. Follow them in order, every time.

1. **Open** with `open_application`. It returns the app `pid` AND a starting `snapshot`. **Read the snapshot before doing anything else** — never send input to a freshly opened app without it.
2. **Locate** with `find_elements({ pid, text, role? })` whenever you know what you're looking for. It is faster, cheaper, and more reliable than scanning a `get_ui_elements` result by hand.
3. **Act** with `click_element`, `set_value`, `type_text`, `clear_field`, `press_key`. Always pass element ids in the `s{snapshot}-{n}` format (e.g. `"s7-12"`) returned by step 1 or 2.
4. **Re-observe** only when the result tells you to:
   - `"stale": true` → call `get_ui_elements` (or `find_elements`) again, then retry.
   - `"removed": true` → element is gone; observe and find a new one.
   - `delta.focusedWindow` changed in a way you didn't expect → observe again.
   - Otherwise (typing into a focused field, toggling a checkbox, pressing a shortcut) → keep going.

If you'd rather not think about re-observing at all, use `act_and_observe` — it runs an action and returns a fresh snapshot in one call.

## Multi-step flows for non-technical users

When the user is watching (configuring macOS, helping an elderly user, walking through anything more than 1-2 actions), do this:

1. Call `start_automation_session({ title, totalSteps? })` first. The user sees a floating HUD that says "Automation in progress" with your title. They can press **Esc** at any time to stop you.
2. On every action call, pass a short **`narration`** string in plain language: `click_element({ id: "s2-3", narration: "Clicking 'Continue'" })`. The HUD updates so the user can follow along.
3. Optionally call `update_automation_session({ stepIndex: 3 })` to advance the "Step 3 of 7" progress.
4. Call `end_automation_session({ reason: "complete" })` when you're done. (Idle sessions auto-end after ~3s, so this is optional but cleaner.)

Every action result includes `cancelled: true` if the user pressed Esc. **When you see that, stop immediately and tell the user the automation was cancelled.** Don't retry, don't keep going.

The HUD also appears automatically the first time any tool is called, even if you forget `start_automation_session` — but a real title and per-step narration is much better than the generic default.

## Canonical Recipe

```
1. start_automation_session({ title: "Visiting example.com", totalSteps: 6 })

2. open_application({ identifier: "Safari", narration: "Opening Safari" })
   → { pid: 1234, name: "Safari", snapshot: { snapshotId: 1, windows: [...], elements: [...] } }

3. press_key({ key: "l", modifiers: ["command"], pid: 1234, narration: "Focusing the address bar" })
   → { success: true, delta: { focusedElement: { role: "textfield", label: "Address" } } }

4. type_text({ text: "https://example.com", narration: "Entering the URL" })
   → { success: true }

5. press_key({ key: "return", pid: 1234, narration: "Loading the page" })
   → { success: true, delta: { focusedWindow: "Example Domain" } }

6. find_elements({ pid: 1234, text: "More information", role: "link" })
   → { snapshotId: 2, elements: [{ id: "s2-3", role: "link", label: "More information..." }] }

7. click_element({ id: "s2-3", narration: "Following the 'More information' link" })
   → { success: true, delta: { focusedWindow: "IANA-managed Reserved Domains" } }

8. end_automation_session({ reason: "complete" })
```

Token cost for this whole flow: ~3-5K. Compare to ~150K if you observed the entire tree after every step.

## Snapshot Ids and the Cache

- Element ids look like `s7-12`. The `s7` is the snapshot they came from.
- The plugin keeps the **last 2 snapshots** in cache. Ids from older snapshots return `"stale": true`.
- Each call to `get_ui_elements`, `find_elements`, or `open_application` (with default `observe: true`) **starts a new snapshot** and bumps the counter.
- This means: if you call `find_elements` twice in a row, the ids from the first call become stale on the third call, not the second.

If you ever see a result with `"stale": true`, the fix is always the same: re-observe and retry with the new id.

## Tool Reference

| Tool | When to use |
|---|---|
| `open_application` | First step. Opens/activates an app and returns an initial snapshot. |
| `get_ui_elements` | Full snapshot of an app's UI. Use after navigation if `find_elements` isn't specific enough. Defaults: 150 elements, depth 20, interactive only. Set `focusedWindowOnly: true` for a cheap re-observation. |
| `find_elements` | Server-side search by `text` and/or `role`. Default `limit: 10`. **Prefer this over `get_ui_elements` whenever you know what you're looking for.** |
| `get_active_window` | Discover the frontmost app's pid when you don't have one. |
| `click_element` | Click by snapshot id. `button: "right"` and `doubleClick: true` supported. |
| `set_value` | Replace a field's value instantly. Best for forms. |
| `clear_field` | Empty a text field. Use before `type_text` if you want to replace, not append. |
| `type_text` | Keystroke-by-keystroke typing. Pass `id` to focus first; `replace: true` (default) clears the field first. |
| `press_key` | Keyboard shortcuts and special keys. Pass `pid` to get a focus delta back. |
| `scroll` | Pass `x`/`y` to position the mouse first if scrolling a specific area. |
| `drag` | Coordinate-based drag for sliders, window resize, drag-and-drop. |
| `click` | Last-resort coordinate click. Use only when an element isn't accessible (canvas apps). |
| `act_and_observe` | Run any element action AND get a fresh snapshot in one call. Use when you'd otherwise have to re-observe immediately. |
| `take_screenshot` | When the AX tree isn't enough (visual layout, images, canvas). Set `annotate: true` with `pid` to overlay element ids on the image. |
| `list_displays` | Multi-monitor setups only. |
| `start_automation_session` | Show the HUD with a title and (optional) step count. Strongly recommended for any flow >2 actions. |
| `update_automation_session` | Change the HUD's title, narration, or step counter outside of an action call. |
| `end_automation_session` | Hide the HUD and reset state when the flow is done. |

## Tips That Actually Matter

1. **Always pass `pid` to `press_key`** when you care whether it changed the focused window/element. The returned `delta` saves you a snapshot.
2. **`set_value` first, `type_text` if it fails.** `set_value` is instant and correct for most fields. Fall back to `type_text` (which focuses + clears + types) for search fields, password fields, or anything that needs per-keystroke events.
3. **Check `truncated: true` in any snapshot.** If true, raise `maxElements` or use `find_elements` instead of `get_ui_elements`.
4. **`focusedWindowOnly: true` is your friend.** Cheap re-observation when you know the action only affected the focused window.
5. **Keyboard shortcuts beat menu navigation.** `press_key("s", modifiers: ["command"])` is one tool call; clicking File > Save is three.
6. **Roles can be passed in any case.** `"button"`, `"Button"`, and `"AXButton"` all work in `find_elements({ role })` and `get_ui_elements({ roles })`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `"stale": true` | Re-observe (any of `get_ui_elements`, `find_elements`, `open_application`) and retry with the fresh id. |
| `"removed": true` | The element is gone from the UI. Re-observe and find a new one. |
| `"cancelled": true` | User pressed Esc. **Stop**, tell the user the automation was cancelled. Do not retry. |
| `error` mentions "not a valid snapshot id" | You passed a v0.2 integer id. Use the `s{n}-{n}` strings returned by the new tools. |
| Empty `elements: []` from `get_ui_elements` | Check `truncated`; lower `maxDepth`; broaden `interactiveOnly: false`; or use `find_elements`. |
| `set_value` returns "not editable" | Fall back to `type_text` with the element id (auto-focuses and replaces). |
| App won't open / wrong app focused | Try the bundle id (`com.apple.Safari`) instead of name. Use `get_active_window` to confirm. |
| No elements at all | The host app needs Accessibility permission in System Settings > Privacy & Security > Accessibility. |

## Reference

For per-app recipes (Safari URL bar, web forms, tab management) and the full keyboard shortcut catalog, see [REFERENCE.md](REFERENCE.md). Don't load it unless you need it — most automation only needs the contract above.

## Limitations

- **Canvas apps** (Figma, games): no element tree. Use `take_screenshot` + `click` with coordinates.
- **Poorly accessible apps** (some Electron / older apps): fall back to coordinate clicks.
- **Highly dynamic web apps**: re-observe more often; prefer `find_elements` over caching ids across navigation.
- **Iframes / web in non-Safari browsers**: AX coverage varies; Safari is most reliable.
