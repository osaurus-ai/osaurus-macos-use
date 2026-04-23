import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Element Action Result

/// Result of an action on a cached element. Carries enough info for the agent
/// to decide whether to re-observe or give up.
struct ElementActionResult: Codable {
  let success: Bool
  let error: String?
  /// True when the failure is because the id refers to a snapshot we no longer
  /// remember. Agent should call `get_ui_elements` again and retry with the
  /// fresh id, not abandon the goal.
  let stale: Bool?
  /// True when the id was well-formed but the element no longer exists (UI
  /// changed). Agent should re-observe and find a new element.
  let removed: Bool?
  /// True when the user pressed Esc to cancel the in-flight automation. Agent
  /// MUST stop and surface the cancellation to the user; do not retry.
  let cancelled: Bool?
  /// A small "what changed" record for successful actions on a known pid.
  let delta: FocusDelta?

  static func ok(delta: FocusDelta? = nil) -> ElementActionResult {
    return ElementActionResult(
      success: true, error: nil, stale: nil, removed: nil, cancelled: nil, delta: delta)
  }

  static func fail(_ message: String) -> ElementActionResult {
    return ElementActionResult(
      success: false, error: message, stale: nil, removed: nil, cancelled: nil, delta: nil)
  }

  static func stale(requested: Int, current: Int) -> ElementActionResult {
    let msg =
      "Element id is from snapshot s\(requested) but the current snapshot is s\(current). "
      + "Call get_ui_elements (or find_elements) again, then retry with the fresh id."
    return ElementActionResult(
      success: false, error: msg, stale: true, removed: nil, cancelled: nil, delta: nil)
  }

  static func removed(_ id: String) -> ElementActionResult {
    let msg =
      "Element \(id) no longer exists in the UI (it may have been removed, or the view changed). "
      + "Re-observe to find the current element."
    return ElementActionResult(
      success: false, error: msg, stale: nil, removed: true, cancelled: nil, delta: nil)
  }

  static func malformed(_ id: String) -> ElementActionResult {
    return .fail(
      "Element id '\(id)' is not a valid snapshot id. Expected format 's<snapshot>-<n>' "
        + "as returned by get_ui_elements or find_elements.")
  }

  /// User pressed Esc to abort the automation session. Agent should stop.
  static func cancelled() -> ElementActionResult {
    return ElementActionResult(
      success: false,
      error: "Cancelled by user (Esc was pressed during the automation).",
      stale: nil, removed: nil, cancelled: true, delta: nil
    )
  }
}

// MARK: - Lookup Helper

/// Either a usable element or a pre-built failure result for the agent.
private enum ResolveOutcome {
  case ok(CachedElement)
  case failure(ElementActionResult)
}

private func resolve(id: String) -> ResolveOutcome {
  // User-cancellation gate. Checked before lookup so we don't waste an AX
  // round-trip on an action the user has already aborted.
  if AutomationSession.shared.isCancelled() {
    return .failure(.cancelled())
  }
  switch AccessibilityManager.shared.lookup(id: id) {
  case .found(let element):
    return .ok(element)
  case .stale(let requested, let current):
    return .failure(.stale(requested: requested, current: current))
  case .removed(let id):
    return .failure(.removed(id))
  case .malformed(let id):
    return .failure(.malformed(id))
  }
}

// MARK: - Element Interaction

/// High-level API for interacting with cached elements.
/// Uses AX actions when available, falls back to coordinate input.
final class ElementInteraction: @unchecked Sendable {
  static let shared = ElementInteraction()

  private let mouseController = MouseController.shared
  private let keyboardController = KeyboardController.shared

  private init() {}

  /// Click an element by ID. Tries AXPress first, falls back to coordinate click.
  func clickElement(id: String) -> ElementActionResult {
    switch resolve(id: id) {
    case .failure(let err): return err
    case .ok(let element):
      if element.supportsAction("AXPress") && element.performAction("AXPress") {
        return .ok(delta: computeFocusDelta(pid: element.pid))
      }
      guard let frame = element.getCurrentFrame() else {
        return .removed(id)
      }
      let center = CGPoint(x: frame.midX, y: frame.midY)
      let result = mouseController.click(at: center)
      if result.success {
        return .ok(delta: computeFocusDelta(pid: element.pid))
      }
      return .fail(result.error ?? "Click failed")
    }
  }

  func doubleClickElement(id: String) -> ElementActionResult {
    switch resolve(id: id) {
    case .failure(let err): return err
    case .ok(let element):
      guard let frame = element.getCurrentFrame() else { return .removed(id) }
      let center = CGPoint(x: frame.midX, y: frame.midY)
      let result = mouseController.doubleClick(at: center)
      if result.success {
        return .ok(delta: computeFocusDelta(pid: element.pid))
      }
      return .fail(result.error ?? "Double click failed")
    }
  }

  /// Focus an element by ID (for text fields).
  func focusElement(id: String) -> ElementActionResult {
    switch resolve(id: id) {
    case .failure(let err): return err
    case .ok(let element):
      let result = AXUIElementSetAttributeValue(
        element.axElement, kAXFocusedAttribute as CFString, true as CFTypeRef)
      if result == .success { return .ok() }
      return clickElement(id: id)
    }
  }

  func rightClickElement(id: String) -> ElementActionResult {
    switch resolve(id: id) {
    case .failure(let err): return err
    case .ok(let element):
      if element.supportsAction("AXShowMenu") && element.performAction("AXShowMenu") {
        return .ok(delta: computeFocusDelta(pid: element.pid))
      }
      guard let frame = element.getCurrentFrame() else { return .removed(id) }
      let center = CGPoint(x: frame.midX, y: frame.midY)
      let result = mouseController.click(at: center, button: .right)
      if result.success {
        return .ok(delta: computeFocusDelta(pid: element.pid))
      }
      return .fail(result.error ?? "Right click failed")
    }
  }

  /// Get the current text value of an element (raw, without affecting cache).
  func getElementValue(id: String) -> String? {
    guard case .found(let element) = AccessibilityManager.shared.lookup(id: id) else {
      return nil
    }
    var valueRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      element.axElement, kAXValueAttribute as CFString, &valueRef)
    if result == .success, let value = valueRef as? String { return value }
    return nil
  }

  /// Set the text value of an element. Preferred for forms.
  func setElementValue(id: String, value: String) -> ElementActionResult {
    switch resolve(id: id) {
    case .failure(let err): return err
    case .ok(let element):
      let result = AXUIElementSetAttributeValue(
        element.axElement, kAXValueAttribute as CFString, value as CFTypeRef)
      if result == .success {
        return .ok(delta: computeFocusDelta(pid: element.pid))
      }
      return .fail(
        "Failed to set element value. Element may not be editable. "
          + "Try type_text with the element id (which focuses first) as a fallback.")
    }
  }

  /// Clear an element's value.
  /// Tries set_value("") first; falls back to focus + Cmd+A + delete.
  func clearElement(id: String) -> ElementActionResult {
    switch resolve(id: id) {
    case .failure(let err): return err
    case .ok(let element):
      let result = AXUIElementSetAttributeValue(
        element.axElement, kAXValueAttribute as CFString, "" as CFTypeRef)
      if result == .success {
        return .ok(delta: computeFocusDelta(pid: element.pid))
      }
      // Fallback: focus, select all, delete
      let focusResult = focusElement(id: id)
      if !focusResult.success { return focusResult }
      _ = keyboardController.pressKey(keyName: "a", modifiers: .maskCommand)
      let del = keyboardController.pressKey(keyName: "delete", modifiers: [])
      if del.success {
        return .ok(delta: computeFocusDelta(pid: element.pid))
      }
      return .fail(del.error ?? "Failed to clear field")
    }
  }
}
