import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - JSON Helpers

private func jsonError(_ message: String) -> String {
  let escaped =
    message
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "\n", with: "\\n")
  return "{\"error\": \"\(escaped)\"}"
}

private func serializeResult<T: Encodable>(_ value: T) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  do {
    let jsonData = try encoder.encode(value)
    return String(data: jsonData, encoding: .utf8) ?? jsonError("Failed to encode result as UTF-8")
  } catch {
    return jsonError("Failed to serialize result: \(error.localizedDescription)")
  }
}

// MARK: - Async Runner Helper

private func runAsyncOnMain<T: Sendable>(_ block: @escaping @MainActor @Sendable () async -> T) -> T
{
  let semaphore = DispatchSemaphore(value: 0)
  nonisolated(unsafe) var result: T!

  Task { @MainActor in
    result = await block()
    semaphore.signal()
  }

  semaphore.wait()
  return result
}

// MARK: - Tool Implementations

// MARK: Open Application Tool

private struct OpenApplicationTool {
  let name = "open_application"

  struct Args: Decodable {
    let identifier: String
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return jsonError("Invalid arguments: expected 'identifier' field")
    }

    let result: Result<AppInfo, AppError> = runAsyncOnMain {
      await openApplication(identifier: input.identifier)
    }

    switch result {
    case .success(let info):
      return serializeResult(info)
    case .failure(let error):
      return jsonError(error.message)
    }
  }
}

// MARK: Get UI Elements Tool

private struct GetUIElementsTool {
  let name = "get_ui_elements"

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let filter = try? JSONDecoder().decode(ElementFilter.self, from: data)
    else {
      return jsonError("Invalid arguments: expected 'pid' field")
    }

    let result = AccessibilityManager.shared.traverse(filter: filter)
    return serializeResult(result)
  }
}

// MARK: Get Active Window Tool

private struct GetActiveWindowTool {
  let name = "get_active_window"

  func run(args: String) -> String {
    if let windowInfo = getActiveWindow() {
      return serializeResult(windowInfo)
    }
    return jsonError("No active window found")
  }
}

// MARK: Click Tool (Raw Coordinates)

private struct ClickTool {
  let name = "click"

  struct Args: Decodable {
    let x: Double
    let y: Double
    let button: String?
    let doubleClick: Bool?
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return jsonError("Invalid arguments: expected 'x' and 'y' fields")
    }

    let point = CGPoint(x: input.x, y: input.y)
    let button: MouseButton =
      switch input.button?.lowercased() {
      case "right": .right
      case "center", "middle": .center
      default: .left
      }

    let result: InputResult
    if input.doubleClick == true {
      result = MouseController.shared.doubleClick(at: point, button: button)
    } else {
      result = MouseController.shared.click(at: point, button: button)
    }

    return serializeResult(result)
  }
}

// MARK: Click Element Tool

private struct ClickElementTool {
  let name = "click_element"

  struct Args: Decodable {
    let id: Int
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return jsonError("Invalid arguments: expected 'id' field")
    }

    let result = ElementInteraction.shared.clickElement(id: input.id)
    return serializeResult(result)
  }
}

// MARK: Focus Element Tool

private struct FocusElementTool {
  let name = "focus_element"

  struct Args: Decodable {
    let id: Int
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return jsonError("Invalid arguments: expected 'id' field")
    }

    let result = ElementInteraction.shared.focusElement(id: input.id)
    return serializeResult(result)
  }
}

// MARK: Type Text Tool

private struct TypeTextTool {
  let name = "type_text"

  struct Args: Decodable {
    let text: String
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return jsonError("Invalid arguments: expected 'text' field")
    }

    let result = KeyboardController.shared.type(text: input.text)
    return serializeResult(result)
  }
}

// MARK: Press Key Tool

private struct PressKeyTool {
  let name = "press_key"

  struct Args: Decodable {
    let key: String
    let modifiers: [String]?
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return jsonError("Invalid arguments: expected 'key' field")
    }

    let flags = parseModifierFlags(input.modifiers)
    let result = KeyboardController.shared.pressKey(keyName: input.key, modifiers: flags)
    return serializeResult(result)
  }
}

// MARK: Scroll Tool

private struct ScrollTool {
  let name = "scroll"

  struct Args: Decodable {
    let direction: String
    let amount: Int32?
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return jsonError("Invalid arguments: expected 'direction' field")
    }

    let direction: ScrollDirection
    switch input.direction.lowercased() {
    case "up": direction = .up
    case "down": direction = .down
    case "left": direction = .left
    case "right": direction = .right
    default:
      return jsonError("Invalid direction: use 'up', 'down', 'left', or 'right'")
    }

    let result = MouseController.shared.scroll(direction: direction, amount: input.amount ?? 3)
    return serializeResult(result)
  }
}

// MARK: List Displays Tool

private struct ListDisplaysTool {
  let name = "list_displays"

  func run(args: String) -> String {
    let result = ScreenshotController.shared.listDisplays()
    return serializeResult(result)
  }
}

// MARK: Take Screenshot Tool

private struct TakeScreenshotTool {
  let name = "take_screenshot"

  func run(args: String) -> String {
    var options = ScreenshotOptions()

    if !args.isEmpty, let data = args.data(using: .utf8) {
      if let parsed = try? JSONDecoder().decode(ScreenshotOptions.self, from: data) {
        options = parsed
      }
    }

    let result = ScreenshotController.shared.capture(options: options)
    return serializeResult(result)
  }
}

// MARK: - Convenience Tools (Action + Observe)

// MARK: Click Element and Observe Tool

private struct ClickElementAndObserveTool {
  let name = "click_element_and_observe"

  struct Args: Decodable {
    let id: Int
    let maxElements: Int?
    let interactiveOnly: Bool?
  }

  struct Result: Encodable {
    let success: Bool
    let error: String?
    let elements: TraversalResult?
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return jsonError("Invalid arguments: expected 'id' field")
    }

    // Get the element's PID before clicking
    guard let element = AccessibilityManager.shared.getElement(id: input.id) else {
      return serializeResult(
        Result(success: false, error: "Element not found", elements: nil))
    }

    // Get PID from element
    var pidRef: pid_t = 0
    AXUIElementGetPid(element.axElement, &pidRef)

    // Perform the click
    let clickResult = ElementInteraction.shared.clickElement(id: input.id)

    if !clickResult.success {
      return serializeResult(
        Result(success: false, error: clickResult.error, elements: nil))
    }

    // Small delay for UI to update
    Thread.sleep(forTimeInterval: 0.2)

    // Traverse the UI
    let filter = ElementFilter(
      pid: pidRef,
      roles: nil,
      maxDepth: nil,
      maxElements: input.maxElements,
      interactiveOnly: input.interactiveOnly
    )

    let traversalResult = AccessibilityManager.shared.traverse(filter: filter)

    return serializeResult(
      Result(success: true, error: nil, elements: traversalResult))
  }
}

// MARK: Type and Observe Tool

private struct TypeAndObserveTool {
  let name = "type_and_observe"

  struct Args: Decodable {
    let text: String
    let pid: Int32
    let maxElements: Int?
    let interactiveOnly: Bool?
  }

  struct Result: Encodable {
    let success: Bool
    let error: String?
    let elements: TraversalResult?
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return jsonError("Invalid arguments: expected 'text' and 'pid' fields")
    }

    // Type the text
    let typeResult = KeyboardController.shared.type(text: input.text)

    if !typeResult.success {
      return serializeResult(
        Result(success: false, error: typeResult.error, elements: nil))
    }

    // Small delay for UI to update
    Thread.sleep(forTimeInterval: 0.1)

    // Traverse the UI
    let filter = ElementFilter(
      pid: input.pid,
      roles: nil,
      maxDepth: nil,
      maxElements: input.maxElements,
      interactiveOnly: input.interactiveOnly
    )

    let traversalResult = AccessibilityManager.shared.traverse(filter: filter)

    return serializeResult(
      Result(success: true, error: nil, elements: traversalResult))
  }
}

// MARK: Press Key and Observe Tool

private struct PressKeyAndObserveTool {
  let name = "press_key_and_observe"

  struct Args: Decodable {
    let key: String
    let modifiers: [String]?
    let pid: Int32
    let maxElements: Int?
    let interactiveOnly: Bool?
  }

  struct Result: Encodable {
    let success: Bool
    let error: String?
    let elements: TraversalResult?
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return jsonError("Invalid arguments: expected 'key' and 'pid' fields")
    }

    // Press the key
    let flags = parseModifierFlags(input.modifiers)
    let keyResult = KeyboardController.shared.pressKey(keyName: input.key, modifiers: flags)

    if !keyResult.success {
      return serializeResult(
        Result(success: false, error: keyResult.error, elements: nil))
    }

    // Small delay for UI to update
    Thread.sleep(forTimeInterval: 0.2)

    // Traverse the UI
    let filter = ElementFilter(
      pid: input.pid,
      roles: nil,
      maxDepth: nil,
      maxElements: input.maxElements,
      interactiveOnly: input.interactiveOnly
    )

    let traversalResult = AccessibilityManager.shared.traverse(filter: filter)

    return serializeResult(
      Result(success: true, error: nil, elements: traversalResult))
  }
}

// MARK: - C ABI Surface

private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
  @convention(c) (
    osr_plugin_ctx_t?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
  ) -> UnsafePointer<CChar>?

private struct osr_plugin_api {
  var free_string: osr_free_string_t?
  var `init`: osr_init_t?
  var destroy: osr_destroy_t?
  var get_manifest: osr_get_manifest_t?
  var invoke: osr_invoke_t?
}

// MARK: - Plugin Context

private class PluginContext {
  // Core action tools
  let openAppTool = OpenApplicationTool()
  let clickTool = ClickTool()
  let clickElementTool = ClickElementTool()
  let focusElementTool = FocusElementTool()
  let typeTextTool = TypeTextTool()
  let pressKeyTool = PressKeyTool()
  let scrollTool = ScrollTool()

  // Observation tools
  let getUIElementsTool = GetUIElementsTool()
  let getActiveWindowTool = GetActiveWindowTool()
  let listDisplaysTool = ListDisplaysTool()
  let takeScreenshotTool = TakeScreenshotTool()

  // Convenience tools
  let clickElementAndObserveTool = ClickElementAndObserveTool()
  let typeAndObserveTool = TypeAndObserveTool()
  let pressKeyAndObserveTool = PressKeyAndObserveTool()
}

// MARK: - Helper Functions

private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
  guard let ptr = strdup(s) else { return nil }
  return UnsafePointer(ptr)
}

// MARK: - API Implementation

nonisolated(unsafe) private var api: osr_plugin_api = {
  var api = osr_plugin_api()

  api.free_string = { ptr in
    if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
  }

  api.`init` = {
    let ctx = PluginContext()
    return Unmanaged.passRetained(ctx).toOpaque()
  }

  api.destroy = { ctxPtr in
    guard let ctxPtr = ctxPtr else { return }
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  }

  api.get_manifest = { _ in
    let manifest = """
      {
        "plugin_id": "osaurus.macos-use",
        "name": "macOS Use",
        "description": "Efficient macOS automation via accessibility APIs - supports element-based interactions, smart filtering, and decoupled actions/observations for minimal context usage",
        "license": "MIT",
        "authors": ["Dinoki Labs"],
        "min_macos": "13.0",
        "min_osaurus": "0.5.0",
        "capabilities": {
          "tools": [
            {
              "id": "open_application",
              "description": "Opens or activates an application by name, bundle ID, or path. Returns the app's PID for subsequent operations.",
              "parameters": {
                "type": "object",
                "properties": {
                  "identifier": {
                    "type": "string",
                    "description": "Application name (e.g., 'Safari'), bundle ID (e.g., 'com.apple.Safari'), or file path"
                  }
                },
                "required": ["identifier"]
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "get_ui_elements",
              "description": "Traverses the accessibility tree and returns interactive UI elements with assigned IDs. Use these IDs with click_element/focus_element. Elements are filtered to reduce output size.",
              "parameters": {
                "type": "object",
                "properties": {
                  "pid": {
                    "type": "integer",
                    "description": "Process ID of the target application"
                  },
                  "maxElements": {
                    "type": "integer",
                    "description": "Maximum number of elements to return (default: 100)"
                  },
                  "maxDepth": {
                    "type": "integer",
                    "description": "Maximum tree depth to traverse (default: 15)"
                  },
                  "interactiveOnly": {
                    "type": "boolean",
                    "description": "Only return interactive elements like buttons, links, text fields (default: true)"
                  },
                  "roles": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Filter to specific roles (e.g., ['button', 'textField'])"
                  }
                },
                "required": ["pid"]
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "get_active_window",
              "description": "Returns information about the currently active window including PID, app name, title, and bounds.",
              "parameters": {
                "type": "object",
                "properties": {}
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "click_element",
              "description": "Clicks an element by its ID (from get_ui_elements). Uses AXPress action when available, falls back to coordinate click. More reliable than raw coordinate clicks.",
              "parameters": {
                "type": "object",
                "properties": {
                  "id": {
                    "type": "integer",
                    "description": "Element ID from a previous get_ui_elements call"
                  }
                },
                "required": ["id"]
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "focus_element",
              "description": "Focuses an element by its ID. Useful for text fields before typing.",
              "parameters": {
                "type": "object",
                "properties": {
                  "id": {
                    "type": "integer",
                    "description": "Element ID from a previous get_ui_elements call"
                  }
                },
                "required": ["id"]
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "click",
              "description": "Clicks at raw screen coordinates. Use click_element instead when possible for better reliability.",
              "parameters": {
                "type": "object",
                "properties": {
                  "x": {
                    "type": "number",
                    "description": "X coordinate (screen pixels)"
                  },
                  "y": {
                    "type": "number",
                    "description": "Y coordinate (screen pixels)"
                  },
                  "button": {
                    "type": "string",
                    "description": "Mouse button: 'left' (default), 'right', or 'center'"
                  },
                  "doubleClick": {
                    "type": "boolean",
                    "description": "Perform a double-click (default: false)"
                  }
                },
                "required": ["x", "y"]
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "type_text",
              "description": "Types text into the currently focused element. Focus an element first using focus_element or click_element.",
              "parameters": {
                "type": "object",
                "properties": {
                  "text": {
                    "type": "string",
                    "description": "Text to type"
                  }
                },
                "required": ["text"]
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "press_key",
              "description": "Presses a keyboard key with optional modifiers.",
              "parameters": {
                "type": "object",
                "properties": {
                  "key": {
                    "type": "string",
                    "description": "Key name: 'return', 'escape', 'tab', 'delete', 'space', 'up', 'down', 'left', 'right', 'f1'-'f12', or a letter/number"
                  },
                  "modifiers": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Modifier keys: 'command', 'shift', 'option', 'control'"
                  }
                },
                "required": ["key"]
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "scroll",
              "description": "Scrolls in the specified direction.",
              "parameters": {
                "type": "object",
                "properties": {
                  "direction": {
                    "type": "string",
                    "description": "Scroll direction: 'up', 'down', 'left', or 'right'"
                  },
                  "amount": {
                    "type": "integer",
                    "description": "Scroll amount in pixels (default: 3)"
                  }
                },
                "required": ["direction"]
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "list_displays",
              "description": "Lists all connected displays with their positions and dimensions. Useful for multi-monitor setups.",
              "parameters": {
                "type": "object",
                "properties": {}
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "take_screenshot",
              "description": "Captures a screenshot. Supports multi-monitor setups: capture main display, specific display by index, all displays combined, or a specific window.",
              "parameters": {
                "type": "object",
                "properties": {
                  "pid": {
                    "type": "integer",
                    "description": "Capture only this app's window (works across all displays)"
                  },
                  "displayIndex": {
                    "type": "integer",
                    "description": "Display index to capture (0 = main, 1, 2, etc.). Use list_displays to see available displays."
                  },
                  "allDisplays": {
                    "type": "boolean",
                    "description": "Capture all displays as one combined image"
                  },
                  "format": {
                    "type": "string",
                    "description": "Image format: 'png' (default) or 'jpeg'"
                  },
                  "quality": {
                    "type": "number",
                    "description": "JPEG quality 0.0-1.0 (default: 0.8)"
                  },
                  "scale": {
                    "type": "number",
                    "description": "Scale factor 0.0-1.0 to reduce image size (default: 1.0)"
                  }
                }
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "click_element_and_observe",
              "description": "Clicks an element and returns the updated UI state. Convenience method combining click_element + get_ui_elements.",
              "parameters": {
                "type": "object",
                "properties": {
                  "id": {
                    "type": "integer",
                    "description": "Element ID to click"
                  },
                  "maxElements": {
                    "type": "integer",
                    "description": "Maximum elements to return (default: 100)"
                  },
                  "interactiveOnly": {
                    "type": "boolean",
                    "description": "Only return interactive elements (default: true)"
                  }
                },
                "required": ["id"]
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "type_and_observe",
              "description": "Types text and returns the updated UI state. Convenience method combining type_text + get_ui_elements.",
              "parameters": {
                "type": "object",
                "properties": {
                  "text": {
                    "type": "string",
                    "description": "Text to type"
                  },
                  "pid": {
                    "type": "integer",
                    "description": "Process ID for UI traversal after typing"
                  },
                  "maxElements": {
                    "type": "integer",
                    "description": "Maximum elements to return (default: 100)"
                  },
                  "interactiveOnly": {
                    "type": "boolean",
                    "description": "Only return interactive elements (default: true)"
                  }
                },
                "required": ["text", "pid"]
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            },
            {
              "id": "press_key_and_observe",
              "description": "Presses a key and returns the updated UI state. Convenience method combining press_key + get_ui_elements.",
              "parameters": {
                "type": "object",
                "properties": {
                  "key": {
                    "type": "string",
                    "description": "Key to press"
                  },
                  "modifiers": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Modifier keys"
                  },
                  "pid": {
                    "type": "integer",
                    "description": "Process ID for UI traversal after key press"
                  },
                  "maxElements": {
                    "type": "integer",
                    "description": "Maximum elements to return (default: 100)"
                  },
                  "interactiveOnly": {
                    "type": "boolean",
                    "description": "Only return interactive elements (default: true)"
                  }
                },
                "required": ["key", "pid"]
              },
              "requirements": ["accessibility"],
              "permission_policy": "ask"
            }
          ]
        }
      }
      """
    return makeCString(manifest)
  }

  api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
    guard let ctxPtr = ctxPtr,
      let typePtr = typePtr,
      let idPtr = idPtr,
      let payloadPtr = payloadPtr
    else { return nil }

    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)

    guard type == "tool" else {
      return makeCString(jsonError("Unknown capability type: \(type)"))
    }

    let result: String
    switch id {
    // Core action tools
    case ctx.openAppTool.name:
      result = ctx.openAppTool.run(args: payload)
    case ctx.clickTool.name:
      result = ctx.clickTool.run(args: payload)
    case ctx.clickElementTool.name:
      result = ctx.clickElementTool.run(args: payload)
    case ctx.focusElementTool.name:
      result = ctx.focusElementTool.run(args: payload)
    case ctx.typeTextTool.name:
      result = ctx.typeTextTool.run(args: payload)
    case ctx.pressKeyTool.name:
      result = ctx.pressKeyTool.run(args: payload)
    case ctx.scrollTool.name:
      result = ctx.scrollTool.run(args: payload)

    // Observation tools
    case ctx.getUIElementsTool.name:
      result = ctx.getUIElementsTool.run(args: payload)
    case ctx.getActiveWindowTool.name:
      result = ctx.getActiveWindowTool.run(args: payload)
    case ctx.listDisplaysTool.name:
      result = ctx.listDisplaysTool.run(args: payload)
    case ctx.takeScreenshotTool.name:
      result = ctx.takeScreenshotTool.run(args: payload)

    // Convenience tools
    case ctx.clickElementAndObserveTool.name:
      result = ctx.clickElementAndObserveTool.run(args: payload)
    case ctx.typeAndObserveTool.name:
      result = ctx.typeAndObserveTool.run(args: payload)
    case ctx.pressKeyAndObserveTool.name:
      result = ctx.pressKeyAndObserveTool.run(args: payload)

    default:
      result = jsonError("Unknown tool: \(id)")
    }

    return makeCString(result)
  }

  return api
}()

// MARK: - Plugin Entry Point

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
