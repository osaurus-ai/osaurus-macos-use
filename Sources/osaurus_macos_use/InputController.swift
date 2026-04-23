import CoreGraphics
import Foundation

// MARK: - Input Result

struct InputResult: Encodable {
  let success: Bool
  let error: String?

  static func ok() -> InputResult {
    return InputResult(success: true, error: nil)
  }

  static func fail(_ message: String) -> InputResult {
    return InputResult(success: false, error: message)
  }
}

// MARK: - Mouse Controller

enum MouseButton {
  case left
  case right
  case center
}

enum ScrollDirection {
  case up
  case down
  case left
  case right
}

/// Shared event source used for all synthesized input. Has a small
/// `localEventsSuppressionInterval` so an involuntary trackpad bump or stray
/// keystroke is dropped during synthesized events. The "real" defense against
/// user input is the visible HUD + Esc cancellation, this is just a safety net.
private enum SharedEventSource {
  static let defaultSuppressionInterval: TimeInterval = 0.05

  // CGEventSource is a CoreFoundation class without Sendable conformance.
  // Mutation is single-threaded in practice (only adjusted by KeyboardController.type
  // around long pastes); we mark it nonisolated(unsafe) and accept the trade.
  nonisolated(unsafe) static let source: CGEventSource = {
    let src = CGEventSource(stateID: .hidSystemState) ?? CGEventSource(stateID: .privateState)!
    src.localEventsSuppressionInterval = defaultSuppressionInterval
    return src
  }()

  static func setSuppression(_ interval: TimeInterval) {
    source.localEventsSuppressionInterval = interval
  }
}

/// Simulates mouse input using CGEvent
final class MouseController: @unchecked Sendable {
  static let shared = MouseController()

  private init() {}

  /// Click at the specified screen coordinates
  func click(at point: CGPoint, button: MouseButton = .left, clickCount: Int = 1) -> InputResult {
    let mouseDownType: CGEventType
    let mouseUpType: CGEventType
    let mouseButton: CGMouseButton

    switch button {
    case .left:
      mouseDownType = .leftMouseDown
      mouseUpType = .leftMouseUp
      mouseButton = .left
    case .right:
      mouseDownType = .rightMouseDown
      mouseUpType = .rightMouseUp
      mouseButton = .right
    case .center:
      mouseDownType = .otherMouseDown
      mouseUpType = .otherMouseUp
      mouseButton = .center
    }

    guard
      let mouseDown = CGEvent(
        mouseEventSource: SharedEventSource.source,
        mouseType: mouseDownType,
        mouseCursorPosition: point,
        mouseButton: mouseButton
      )
    else {
      return .fail("Failed to create mouse down event")
    }

    guard
      let mouseUp = CGEvent(
        mouseEventSource: SharedEventSource.source,
        mouseType: mouseUpType,
        mouseCursorPosition: point,
        mouseButton: mouseButton
      )
    else {
      return .fail("Failed to create mouse up event")
    }

    mouseDown.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
    mouseUp.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))

    mouseDown.post(tap: .cghidEventTap)
    mouseUp.post(tap: .cghidEventTap)

    return .ok()
  }

  func doubleClick(at point: CGPoint, button: MouseButton = .left) -> InputResult {
    let result1 = click(at: point, button: button, clickCount: 1)
    if !result1.success { return result1 }

    Thread.sleep(forTimeInterval: 0.05)

    return click(at: point, button: button, clickCount: 2)
  }

  func moveTo(_ point: CGPoint) -> InputResult {
    guard
      let event = CGEvent(
        mouseEventSource: SharedEventSource.source,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
      )
    else {
      return .fail("Failed to create mouse move event")
    }

    event.post(tap: .cghidEventTap)
    return .ok()
  }

  func scroll(direction: ScrollDirection, amount: Int32 = 3) -> InputResult {
    let deltaX: Int32
    let deltaY: Int32

    switch direction {
    case .up:
      deltaX = 0
      deltaY = amount
    case .down:
      deltaX = 0
      deltaY = -amount
    case .left:
      deltaX = amount
      deltaY = 0
    case .right:
      deltaX = -amount
      deltaY = 0
    }

    guard
      let event = CGEvent(
        scrollWheelEvent2Source: SharedEventSource.source,
        units: .pixel,
        wheelCount: 2,
        wheel1: deltaY,
        wheel2: deltaX,
        wheel3: 0
      )
    else {
      return .fail("Failed to create scroll event")
    }

    event.post(tap: .cgSessionEventTap)
    return .ok()
  }

  /// Drag from one point to another.
  ///
  /// CRITICAL: drag is treated as an uninterruptible critical section. If we
  /// posted a mouseDown but failed to post the matching mouseUp, the OS would
  /// believe the mouse button is still held down and every subsequent user
  /// click would drag things around. The `defer` ensures the final mouseUp
  /// fires on every exit path.
  func drag(from start: CGPoint, to end: CGPoint, button: MouseButton = .left) -> InputResult {
    let mouseDownType: CGEventType
    let mouseDragType: CGEventType
    let mouseUpType: CGEventType
    let mouseButton: CGMouseButton

    switch button {
    case .left:
      mouseDownType = .leftMouseDown
      mouseDragType = .leftMouseDragged
      mouseUpType = .leftMouseUp
      mouseButton = .left
    case .right:
      mouseDownType = .rightMouseDown
      mouseDragType = .rightMouseDragged
      mouseUpType = .rightMouseUp
      mouseButton = .right
    case .center:
      mouseDownType = .otherMouseDown
      mouseDragType = .otherMouseDragged
      mouseUpType = .otherMouseUp
      mouseButton = .center
    }

    guard
      let mouseDown = CGEvent(
        mouseEventSource: SharedEventSource.source,
        mouseType: mouseDownType,
        mouseCursorPosition: start,
        mouseButton: mouseButton
      )
    else {
      return .fail("Failed to create mouse down event")
    }
    mouseDown.post(tap: .cghidEventTap)

    // Always release the button, even on error. This is the critical safety:
    // without it a stray failure would leave the OS believing the user is
    // still holding the mouse button down.
    var releaseFired = false
    defer {
      if !releaseFired,
        let release = CGEvent(
          mouseEventSource: SharedEventSource.source,
          mouseType: mouseUpType,
          mouseCursorPosition: end,
          mouseButton: mouseButton
        )
      {
        release.post(tap: .cghidEventTap)
      }
    }

    Thread.sleep(forTimeInterval: 0.05)

    guard
      let mouseDrag = CGEvent(
        mouseEventSource: SharedEventSource.source,
        mouseType: mouseDragType,
        mouseCursorPosition: end,
        mouseButton: mouseButton
      )
    else {
      return .fail("Failed to create mouse drag event")
    }
    mouseDrag.post(tap: .cghidEventTap)

    Thread.sleep(forTimeInterval: 0.05)

    guard
      let mouseUp = CGEvent(
        mouseEventSource: SharedEventSource.source,
        mouseType: mouseUpType,
        mouseCursorPosition: end,
        mouseButton: mouseButton
      )
    else {
      return .fail("Failed to create mouse up event")
    }
    mouseUp.post(tap: .cghidEventTap)
    releaseFired = true

    return .ok()
  }
}

// MARK: - Keyboard Controller

/// Simulates keyboard input using CGEvent
final class KeyboardController: @unchecked Sendable {
  static let shared = KeyboardController()

  /// Strings longer than this trigger the "loose suppression" path so the user
  /// isn't locked out of their keyboard for the duration of a long paste.
  private static let longTypeThreshold: Int = 100

  private init() {}

  /// Type a string of text. Long strings (>100 chars) temporarily disable the
  /// shared event source's input suppression so the user isn't frozen for the
  /// entire paste duration; Esc-cancellation still works via the per-character
  /// check below.
  func type(text: String) -> InputResult {
    let isLong = text.count > Self.longTypeThreshold
    let originalSuppression = SharedEventSource.source.localEventsSuppressionInterval
    if isLong {
      SharedEventSource.setSuppression(0.0)
    }
    defer {
      if isLong {
        SharedEventSource.setSuppression(originalSuppression)
      }
    }

    for char in text {
      if AutomationSession.shared.isCancelled() {
        return .fail("Cancelled by user (Esc was pressed).")
      }
      if let result = typeCharacter(char), !result.success {
        return result
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return .ok()
  }

  private func typeCharacter(_ char: Character) -> InputResult? {
    let str = String(char)

    guard
      let keyDown = CGEvent(
        keyboardEventSource: SharedEventSource.source, virtualKey: 0, keyDown: true),
      let keyUp = CGEvent(
        keyboardEventSource: SharedEventSource.source, virtualKey: 0, keyDown: false)
    else {
      return .fail("Failed to create keyboard event")
    }

    var unicodeString = Array(str.utf16)
    keyDown.keyboardSetUnicodeString(
      stringLength: unicodeString.count, unicodeString: &unicodeString)
    keyUp.keyboardSetUnicodeString(stringLength: unicodeString.count, unicodeString: &unicodeString)

    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)

    return nil
  }

  /// Press a specific key with optional modifiers
  func pressKey(keyName: String, modifiers: CGEventFlags = []) -> InputResult {
    guard let keyCode = keyCodeForName(keyName) else {
      return .fail("Unknown key: \(keyName)")
    }

    guard
      let keyDown = CGEvent(
        keyboardEventSource: SharedEventSource.source, virtualKey: keyCode, keyDown: true),
      let keyUp = CGEvent(
        keyboardEventSource: SharedEventSource.source, virtualKey: keyCode, keyDown: false)
    else {
      return .fail("Failed to create keyboard event")
    }

    keyDown.flags = modifiers
    keyUp.flags = modifiers

    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)

    return .ok()
  }

  /// Map key names to virtual key codes
  private func keyCodeForName(_ name: String) -> CGKeyCode? {
    let lowerName = name.lowercased()

    let specialKeys: [String: CGKeyCode] = [
      "return": 0x24,
      "enter": 0x24,
      "tab": 0x30,
      "space": 0x31,
      "delete": 0x33,
      "backspace": 0x33,
      "escape": 0x35,
      "esc": 0x35,
      "command": 0x37,
      "cmd": 0x37,
      "shift": 0x38,
      "capslock": 0x39,
      "option": 0x3A,
      "alt": 0x3A,
      "control": 0x3B,
      "ctrl": 0x3B,
      "rightshift": 0x3C,
      "rightoption": 0x3D,
      "rightcontrol": 0x3E,
      "function": 0x3F,
      "fn": 0x3F,
      "f1": 0x7A,
      "f2": 0x78,
      "f3": 0x63,
      "f4": 0x76,
      "f5": 0x60,
      "f6": 0x61,
      "f7": 0x62,
      "f8": 0x64,
      "f9": 0x65,
      "f10": 0x6D,
      "f11": 0x67,
      "f12": 0x6F,
      "home": 0x73,
      "end": 0x77,
      "pageup": 0x74,
      "pagedown": 0x79,
      "arrowleft": 0x7B,
      "left": 0x7B,
      "arrowright": 0x7C,
      "right": 0x7C,
      "arrowdown": 0x7D,
      "down": 0x7D,
      "arrowup": 0x7E,
      "up": 0x7E,
      "forwarddelete": 0x75,
    ]

    if let code = specialKeys[lowerName] {
      return code
    }

    let letterKeys: [String: CGKeyCode] = [
      "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04,
      "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
      "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F,
      "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
      "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19,
      "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
      "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
      "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
      "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E,
      ".": 0x2F, "`": 0x32,
    ]

    if let code = letterKeys[lowerName] {
      return code
    }

    return nil
  }
}

// MARK: - Modifier Flags Parsing

func parseModifierFlags(_ flags: [String]?) -> CGEventFlags {
  guard let flags = flags else { return [] }

  var result: CGEventFlags = []
  for flag in flags {
    switch flag.lowercased() {
    case "capslock", "caps":
      result.insert(.maskAlphaShift)
    case "shift":
      result.insert(.maskShift)
    case "control", "ctrl":
      result.insert(.maskControl)
    case "option", "opt", "alt":
      result.insert(.maskAlternate)
    case "command", "cmd":
      result.insert(.maskCommand)
    case "function", "fn":
      result.insert(.maskSecondaryFn)
    default:
      break
    }
  }
  return result
}
