# Changelog

## 0.3.1 — Automation HUD with Esc-to-cancel

A user-visible "Automation in progress" HUD with system-wide Esc-to-cancel and per-step narration. Built so non-technical users (and agents helping elderly users walk through macOS configuration) can watch what's happening, follow along, and stop safely if something goes wrong.

### New

- **Floating HUD** anchored to the bottom-center of the main display, showing the session title, current narration, optional `Step N of M` progress, and "Press esc to stop". Auto-shows on the first tool call; auto-hides ~3s after the last call.
- **System-wide Esc cancellation** via a `CGEventTap` on a dedicated runloop thread. Pressing Esc:
  - Flips a `cancelled` flag the next tool call respects.
  - Flashes "Cancelled" in the HUD.
  - Consumes the Esc so it doesn't reach the focused app (only after a 500ms grace period, so users can still dismiss legitimate modals that pop up at session start).
  - Re-enables itself if macOS disables the tap (`tapDisabledByTimeout` / `tapDisabledByUserInput`).
- **Three new session tools:**
  - `start_automation_session({ title, totalSteps?, narration? })`
  - `update_automation_session({ title?, narration?, stepIndex?, totalSteps? })`
  - `end_automation_session({ reason? })`
- **Per-action `narration` arg** on every action tool (`click_element`, `set_value`, `type_text`, `clear_field`, `press_key`, `scroll`, `drag`, `click`, `act_and_observe`, `open_application`). Updates the HUD subtitle right before the action runs.
- **`cancelled: true` field** on `ElementActionResult`. When agents see this, they should stop and surface the cancellation to the user, not retry.

### Hardened

- **Drag is now safe to interrupt.** `MouseController.drag` posts the matching mouseUp via `defer`, so a stuck-down mouse button can never happen even on error / early-return paths.
- **AX calls have a 3-second timeout** (`AXUIElementSetMessagingTimeout`). Wedged target apps no longer hang the agent indefinitely.
- **Light input suppression** on a shared `CGEventSource` (50ms by default) so an involuntary trackpad bump or stray keystroke is dropped during synthesized events. Long pastes (>100 chars) automatically disable suppression so the user isn't locked out of their keyboard for the duration.
- **`open_application` is cancellable** within 100ms instead of waiting up to 5 seconds.
- **`type_text(id:)` aborts mid-string** if the user presses Esc; per-character cancel check inside the loop.
- **Plugin destroy tears down the HUD and Esc tap** so nothing dangles after `osr_destroy`.

### Accessibility

- Respects `accessibilityDisplayShouldReduceMotion` (skips fade animations).
- Respects `accessibilityDisplayShouldReduceTransparency` (uses solid background instead of frosted glass).
- Posts `NSAccessibility.Notification.announcementRequested` on every HUD text change so VoiceOver users hear the narration.
- HUD repositions itself when displays change (`didChangeScreenParametersNotification`).

### Tool count

15 → 18 (added `start_automation_session`, `update_automation_session`, `end_automation_session`).

### Backward compatibility

Fully additive. The new `narration` arg on action tools is optional. The new `cancelled` field on `ElementActionResult` is optional and only present when set. Agents that don't know about any of this still get the auto-show HUD and Esc cancel for free.

## 0.3.0 — Agent ergonomics overhaul

This release is a substantial redesign focused on making the plugin actually usable by agents. The previous version had several silent failure modes that caused agents to give up: a broken `roles` filter, sparse element labels, no way to disambiguate elements, no server-side search, no signal distinguishing "stale id" from "element gone", and no enforcement of the workflow contract at the tool level.

### Breaking changes

- **Element ids are now strings**, not integers. Format: `"s{snapshot}-{n}"` (e.g. `"s7-12"`). Every observation tool starts a new snapshot; old ids return `"stale": true` instead of silently mismatching. Update any caller that passed integers — those now return a "not a valid snapshot id" error.
- **Element response shape expanded.** `ElementInfo` gained `roleDescription`, `placeholder`, `path`, `windowId`, `focused`, `enabled`. `TraversalResult` gained `snapshotId`, `focusedWindow`, `truncated`, `windows[]`. Existing fields are unchanged. `nil` values are omitted from JSON.

### Fixes

- **`roles` filter actually works.** Previously the filter compared `"button"` (what the docs taught) against `"AXButton"` (what the AX API returns) and silently matched nothing. Both forms now work; comparison is case-insensitive and AX-prefix-agnostic.
- **Element labels are no longer sparse.** Label extraction now cascades through `AXTitle`, `AXDescription`, `AXLabelValue`, `AXTitleUIElement`, and `AXHelp`. `AXPlaceholderValue` is exposed as a separate `placeholder` field. `AXRoleDescription` is exposed as `roleDescription`. The previous `label != nil || !actions.isEmpty` gate that silently dropped many text fields is gone.
- **Broader interactive role set.** Added `row`, `cell`, `outline`, `image`, `heading`, `webarea`, `menubaritem` to the default interactive set so web pages and rich apps surface more useful elements.
- **Truncation is visible.** Snapshots now include `"truncated": true` when `maxElements` was hit, and traversal visits the focused window first so the most relevant elements survive truncation.
- **Default limits raised** (`maxElements: 100 → 150`, `maxDepth: 15 → 20`).

### New tools

- **`find_elements`** — server-side search by `text`, `role`, `windowId`, `enabledOnly`. Default `limit: 10`. Cheaper and more reliable than scanning a `get_ui_elements` result by hand. Caches results into the same snapshot, so returned ids are immediately usable with `click_element`, `set_value`, etc.
- **`clear_field`** — empties a text field (`set_value("")` first; falls back to focus + Cmd+A + delete). Use before `type_text` when you want to replace, not append.
- **`act_and_observe`** — runs an element action AND returns a fresh snapshot in a single call. Eliminates the most common failure mode (forgetting to re-observe after navigation). Supports `observe: "full" | "focused_window" | "none"`.

### Behavior changes

- **`open_application` auto-observes.** Returns `{ pid, name, bundleId, snapshot }` by default. Pass `observe: false` to opt out.
- **`type_text(id:)` now clears first** by default (`replace: true`). Pass `replace: false` to append.
- **Snapshot-aware error reporting.** `click_element`/`set_value`/`clear_field`/`type_text` (with id) return:
  - `{ "stale": true, ... }` when the id refers to a snapshot that was rotated out — agent should re-observe and retry.
  - `{ "removed": true, ... }` when the id is well-formed but the element no longer exists — agent should re-observe and find a new element.
  - A clear "not a valid snapshot id" error for malformed input.
- **Last 2 snapshots are retained** so an action immediately after a re-observe still resolves correctly.
- **Action results carry a `delta`** with `focusedWindow` and `focusedElement` so the agent can decide whether to re-observe without taking a full snapshot.
- **`take_screenshot` can annotate.** Pass `annotate: true` (with `pid`) to overlay element-id labels from the most recent snapshot.

### Manifest / docs

- Tool descriptions now bake in the workflow contract ("requires a recent snapshot", "if `stale: true`, observe again") so the rules survive even if `SKILL.md` isn't loaded.
- `SKILL.md` rewritten down from 416 lines to ~120, contract-first. Keyboard-shortcut tables and per-app recipes moved to `REFERENCE.md`.

### Migration

If you previously called `click_element({ id: 5 })`, replace the integer with the string id from the new snapshot result, e.g. `click_element({ id: "s1-5" })`. The plugin will return a clear "not a valid snapshot id" error for any leftover integer ids.

If you relied on observing repeatedly without checking results, switch to `act_and_observe` or check the `stale`/`removed`/`delta` fields on the new responses.

## 0.2.0

Initial release with separated action/observation tools.
