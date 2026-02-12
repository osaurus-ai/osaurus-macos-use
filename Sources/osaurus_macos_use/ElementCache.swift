import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Element Action Result

struct ElementActionResult: Encodable {
  let success: Bool
  let error: String?

  static func ok() -> ElementActionResult {
    return ElementActionResult(success: true, error: nil)
  }

  static func fail(_ message: String) -> ElementActionResult {
    return ElementActionResult(success: false, error: message)
  }
}

// MARK: - Element Interaction

/// High-level API for interacting with cached elements
/// Uses AX actions when available, falls back to coordinates
final class ElementInteraction: @unchecked Sendable {
  static let shared = ElementInteraction()

  private let accessibilityManager = AccessibilityManager.shared
  private let mouseController = MouseController.shared

  private init() {}

  /// Click an element by ID
  /// Tries AXPress first, falls back to coordinate click
  func clickElement(id: Int) -> ElementActionResult {
    guard let element = accessibilityManager.getElement(id: id) else {
      return .fail("Element not found. Call get_ui_elements first to refresh the element cache.")
    }

    // Try AXPress action first (most reliable, immune to mouse position)
    if element.supportsAction("AXPress") {
      if element.performAction("AXPress") {
        return .ok()
      }
    }

    // Fallback: re-query current position and simulate click
    guard let frame = element.getCurrentFrame() else {
      return .fail("Element is no longer accessible. It may have been removed from the UI.")
    }

    // Click at the center of the element
    let centerX = frame.origin.x + frame.width / 2
    let centerY = frame.origin.y + frame.height / 2

    let result = mouseController.click(at: CGPoint(x: centerX, y: centerY))
    return ElementActionResult(success: result.success, error: result.error)
  }

  /// Double-click an element by ID
  func doubleClickElement(id: Int) -> ElementActionResult {
    guard let element = accessibilityManager.getElement(id: id) else {
      return .fail("Element not found. Call get_ui_elements first to refresh the element cache.")
    }

    // For double-click, we need coordinates
    guard let frame = element.getCurrentFrame() else {
      return .fail("Element is no longer accessible.")
    }

    let centerX = frame.origin.x + frame.width / 2
    let centerY = frame.origin.y + frame.height / 2

    let result = mouseController.doubleClick(at: CGPoint(x: centerX, y: centerY))
    return ElementActionResult(success: result.success, error: result.error)
  }

  /// Focus an element by ID (for text fields)
  func focusElement(id: Int) -> ElementActionResult {
    guard let element = accessibilityManager.getElement(id: id) else {
      return .fail("Element not found. Call get_ui_elements first to refresh the element cache.")
    }

    // Try AXFocus action
    let result = AXUIElementSetAttributeValue(
      element.axElement,
      kAXFocusedAttribute as CFString,
      true as CFTypeRef
    )

    if result == .success {
      return .ok()
    }

    // Fallback: click to focus
    return clickElement(id: id)
  }

  /// Right-click an element by ID
  func rightClickElement(id: Int) -> ElementActionResult {
    guard let element = accessibilityManager.getElement(id: id) else {
      return .fail("Element not found. Call get_ui_elements first to refresh the element cache.")
    }

    // Try AXShowMenu action first
    if element.supportsAction("AXShowMenu") {
      if element.performAction("AXShowMenu") {
        return .ok()
      }
    }

    // Fallback: coordinate right-click
    guard let frame = element.getCurrentFrame() else {
      return .fail("Element is no longer accessible.")
    }

    let centerX = frame.origin.x + frame.width / 2
    let centerY = frame.origin.y + frame.height / 2

    let result = mouseController.click(at: CGPoint(x: centerX, y: centerY), button: .right)
    return ElementActionResult(success: result.success, error: result.error)
  }

  /// Get the current text value of an element
  func getElementValue(id: Int) -> String? {
    guard let element = accessibilityManager.getElement(id: id) else {
      return nil
    }

    var valueRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      element.axElement,
      kAXValueAttribute as CFString,
      &valueRef
    )

    if result == .success, let value = valueRef as? String {
      return value
    }

    return nil
  }

  /// Set the text value of an element (for text fields)
  func setElementValue(id: Int, value: String) -> ElementActionResult {
    guard let element = accessibilityManager.getElement(id: id) else {
      return .fail("Element not found. Call get_ui_elements first to refresh the element cache.")
    }

    let result = AXUIElementSetAttributeValue(
      element.axElement,
      kAXValueAttribute as CFString,
      value as CFTypeRef
    )

    if result == .success {
      return .ok()
    }

    return .fail("Failed to set element value. Element may not be editable.")
  }

  /// Check if an element still exists and is accessible
  func elementExists(id: Int) -> Bool {
    guard let element = accessibilityManager.getElement(id: id) else {
      return false
    }

    // Try to get any attribute to verify the element is still valid
    var roleRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      element.axElement,
      kAXRoleAttribute as CFString,
      &roleRef
    )

    return result == .success
  }

  /// Get element info by ID (returns current state)
  func getElementInfo(id: Int) -> ElementInfo? {
    guard let element = accessibilityManager.getElement(id: id) else {
      return nil
    }

    guard let frame = element.getCurrentFrame() else {
      return nil
    }

    // Get current label/value
    var titleRef: CFTypeRef?
    var valueRef: CFTypeRef?

    AXUIElementCopyAttributeValue(element.axElement, kAXTitleAttribute as CFString, &titleRef)
    AXUIElementCopyAttributeValue(element.axElement, kAXValueAttribute as CFString, &valueRef)

    let label = titleRef as? String
    let value = valueRef as? String

    return ElementInfo(
      id: id,
      role: element.role.hasPrefix("AX")
        ? String(element.role.dropFirst(2)).lowercased()
        : element.role
          .lowercased(),
      label: label,
      value: value,
      x: Int(frame.origin.x),
      y: Int(frame.origin.y),
      w: Int(frame.width),
      h: Int(frame.height),
      actions: element.supportedActions.map {
        $0.hasPrefix("AX") ? String($0.dropFirst(2)).lowercased() : $0.lowercased()
      }
    )
  }
}
