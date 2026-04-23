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

/// Decode a tool's `Args` struct from a JSON string and run `body` with it,
/// or return a structured error mentioning `expecting`.
private func withArgs<Args: Decodable>(
  _ args: String,
  expecting: String,
  _ body: (Args) -> String
) -> String {
  guard let data = args.data(using: .utf8),
    let input = try? JSONDecoder().decode(Args.self, from: data)
  else {
    return jsonError("Invalid arguments: expected \(expecting)")
  }
  return body(input)
}

// MARK: - Async Runner Helpers

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

private func runOnMain<T>(_ block: @Sendable () -> T) -> T {
  if Thread.isMainThread {
    return block()
  } else {
    return DispatchQueue.main.sync { block() }
  }
}

/// Run a UI-element traversal on the main thread. Wraps the Sendable-capture
/// boilerplate in one place.
private func traverse(
  pid: Int32,
  maxElements: Int? = nil,
  focusedWindowOnly: Bool = false,
  search: SearchOptions? = nil
) -> TraversalResult {
  var f = ElementFilter(pid: pid)
  if let maxElements = maxElements { f.maxElements = maxElements }
  if focusedWindowOnly { f.focusedWindowOnly = true }
  let filter = f
  let s = search
  return runOnMain { AccessibilityManager.shared.traverse(filter: filter, search: s) }
}

// MARK: - Automation Gate

/// Called at the top of every action-style tool. Updates the HUD's narration
/// and bails immediately if the user pressed Esc. Returns the bail-out JSON
/// when cancelled, or nil to continue.
private func gateAutomation(narration: String?) -> String? {
  AutomationSession.shared.markActive(narration: narration)
  if AutomationSession.shared.isCancelled() {
    return serializeResult(ElementActionResult.cancelled())
  }
  return nil
}

/// Lightweight version for observation tools: keeps the HUD alive but does
/// NOT bail on cancel - the agent should still be able to read state during
/// or right after a cancellation.
private func markObservation() {
  AutomationSession.shared.markActive(narration: nil)
}

// MARK: - Tool Protocol

/// Every tool conforms to this. The C-ABI invoke layer routes by `name`.
/// Tools are stateless value types, so `Sendable` conformance is safe.
private protocol Tool: Sendable {
  var name: String { get }
  func run(args: String) -> String
}

// MARK: - Open Application Tool

private struct OpenApplicationTool: Tool {
  let name = "open_application"

  struct Args: Decodable {
    let identifier: String
    let observe: Bool?
    let maxElements: Int?
    let narration: String?
  }

  struct Result: Encodable {
    let pid: Int32
    let bundleId: String?
    let name: String
    let snapshot: TraversalResult?
  }

  func run(args: String) -> String {
    withArgs(args, expecting: "'identifier' field") { (input: Args) in
      if let bail = gateAutomation(narration: input.narration ?? "Opening \(input.identifier)...") {
        return bail
      }
      let opened: Swift.Result<AppInfo, AppError> = runAsyncOnMain {
        await openApplication(identifier: input.identifier)
      }
      switch opened {
      case .failure(let error):
        return jsonError(error.message)
      case .success(let info):
        let snapshot: TraversalResult? =
          (input.observe ?? true)
          ? traverse(pid: info.pid, maxElements: input.maxElements ?? 150)
          : nil
        return serializeResult(
          Result(pid: info.pid, bundleId: info.bundleId, name: info.name, snapshot: snapshot))
      }
    }
  }
}

// MARK: - Get UI Elements Tool

private struct GetUIElementsTool: Tool {
  let name = "get_ui_elements"

  func run(args: String) -> String {
    withArgs(args, expecting: "'pid' field") { (filter: ElementFilter) in
      markObservation()
      return serializeResult(runOnMain { AccessibilityManager.shared.traverse(filter: filter) })
    }
  }
}

// MARK: - Find Elements Tool

private struct FindElementsTool: Tool {
  let name = "find_elements"

  struct Args: Decodable {
    let pid: Int32
    let text: String?
    let role: String?
    let roles: [String]?
    let windowId: Int?
    let enabledOnly: Bool?
    let limit: Int?
    let maxDepth: Int?
    let interactiveOnly: Bool?
  }

  func run(args: String) -> String {
    withArgs(args, expecting: "'pid' field") { (input: Args) in
      markObservation()
      let limit = input.limit ?? 10
      let roles = input.roles ?? input.role.map { [$0] }

      var f = ElementFilter(pid: input.pid)
      f.roles = roles
      f.maxDepth = input.maxDepth ?? 25
      f.maxElements = limit
      f.interactiveOnly = input.interactiveOnly ?? true
      let filter = f

      let search = SearchOptions(
        text: input.text,
        enabledOnly: input.enabledOnly ?? false,
        windowId: input.windowId,
        limit: limit
      )
      return serializeResult(
        runOnMain { AccessibilityManager.shared.traverse(filter: filter, search: search) })
    }
  }
}

// MARK: - Get Active Window Tool

private struct GetActiveWindowTool: Tool {
  let name = "get_active_window"

  func run(args: String) -> String {
    markObservation()
    if let info = runOnMain({ getActiveWindow() }) {
      return serializeResult(info)
    }
    return jsonError("No active window found")
  }
}

// MARK: - Click Tool (Raw Coordinates)

private struct ClickTool: Tool {
  let name = "click"

  struct Args: Decodable {
    let x: Double
    let y: Double
    let button: String?
    let doubleClick: Bool?
    let narration: String?
  }

  func run(args: String) -> String {
    withArgs(args, expecting: "'x' and 'y' fields") { (input: Args) in
      if let bail = gateAutomation(narration: input.narration) { return bail }
      let point = CGPoint(x: input.x, y: input.y)
      let button: MouseButton =
        switch input.button?.lowercased() {
        case "right": .right
        case "center", "middle": .center
        default: .left
        }
      let result: InputResult =
        (input.doubleClick == true)
        ? MouseController.shared.doubleClick(at: point, button: button)
        : MouseController.shared.click(at: point, button: button)
      return serializeResult(result)
    }
  }
}

// MARK: - Click Element Tool

private struct ClickElementTool: Tool {
  let name = "click_element"

  struct Args: Decodable {
    let id: String
    let button: String?
    let doubleClick: Bool?
    let narration: String?
  }

  func run(args: String) -> String {
    withArgs(args, expecting: "'id' field (string, e.g. 's1-5')") { (input: Args) in
      if let bail = gateAutomation(narration: input.narration) { return bail }
      let result: ElementActionResult
      if input.button?.lowercased() == "right" {
        result = ElementInteraction.shared.rightClickElement(id: input.id)
      } else if input.doubleClick == true {
        result = ElementInteraction.shared.doubleClickElement(id: input.id)
      } else {
        result = ElementInteraction.shared.clickElement(id: input.id)
      }
      return serializeResult(result)
    }
  }
}

// MARK: - Type Text Tool

private struct TypeTextTool: Tool {
  let name = "type_text"

  struct Args: Decodable {
    let text: String
    let id: String?
    let replace: Bool?
    let narration: String?
  }

  func run(args: String) -> String {
    withArgs(args, expecting: "'text' field") { (input: Args) in
      if let bail = gateAutomation(narration: input.narration) { return bail }

      if let elementId = input.id {
        let focusResult = ElementInteraction.shared.focusElement(id: elementId)
        if !focusResult.success {
          return serializeResult(focusResult)
        }
        if input.replace ?? true {
          // Best-effort clear; some fields aren't AX-clearable, in which case
          // typing simply appends. Skip the explicit error path on stale/removed/cancelled.
          _ = ElementInteraction.shared.clearElement(id: elementId)
        }
      }

      let result = KeyboardController.shared.type(text: input.text)
      if result.success {
        let pid = input.id.flatMap { AccessibilityManager.shared.pid(for: $0) }
        let delta = pid.flatMap { computeFocusDelta(pid: $0) }
        return serializeResult(ElementActionResult.ok(delta: delta))
      }
      // KeyboardController.type returns the cancellation message verbatim.
      if result.error?.contains("Cancelled by user") == true {
        return serializeResult(ElementActionResult.cancelled())
      }
      return serializeResult(ElementActionResult.fail(result.error ?? "Type failed"))
    }
  }
}

// MARK: - Press Key Tool

private struct PressKeyTool: Tool {
  let name = "press_key"

  struct Args: Decodable {
    let key: String
    let modifiers: [String]?
    let pid: Int32?
    let narration: String?
  }

  func run(args: String) -> String {
    withArgs(args, expecting: "'key' field") { (input: Args) in
      if let bail = gateAutomation(narration: input.narration) { return bail }
      let flags = parseModifierFlags(input.modifiers)
      let result = KeyboardController.shared.pressKey(keyName: input.key, modifiers: flags)
      if result.success {
        let pid = input.pid ?? AccessibilityManager.shared.mostRecentPid()
        let delta = pid.flatMap { computeFocusDelta(pid: $0) }
        return serializeResult(ElementActionResult.ok(delta: delta))
      }
      return serializeResult(ElementActionResult.fail(result.error ?? "Press key failed"))
    }
  }
}

// MARK: - Scroll Tool

private struct ScrollTool: Tool {
  let name = "scroll"

  struct Args: Decodable {
    let direction: String
    let amount: Int32?
    let x: Double?
    let y: Double?
    let narration: String?
  }

  func run(args: String) -> String {
    withArgs(args, expecting: "'direction' field") { (input: Args) in
      if let bail = gateAutomation(narration: input.narration) { return bail }
      let direction: ScrollDirection
      switch input.direction.lowercased() {
      case "up": direction = .up
      case "down": direction = .down
      case "left": direction = .left
      case "right": direction = .right
      default:
        return jsonError("Invalid direction: use 'up', 'down', 'left', or 'right'")
      }
      if let x = input.x, let y = input.y {
        _ = MouseController.shared.moveTo(CGPoint(x: x, y: y))
      }
      let result = MouseController.shared.scroll(direction: direction, amount: input.amount ?? 3)
      return serializeResult(result)
    }
  }
}

// MARK: - Set Value Tool

private struct SetValueTool: Tool {
  let name = "set_value"

  struct Args: Decodable {
    let id: String
    let value: String
    let narration: String?
  }

  func run(args: String) -> String {
    withArgs(args, expecting: "'id' (string) and 'value' fields") { (input: Args) in
      if let bail = gateAutomation(narration: input.narration) { return bail }
      return serializeResult(
        ElementInteraction.shared.setElementValue(id: input.id, value: input.value))
    }
  }
}

// MARK: - Clear Field Tool

private struct ClearFieldTool: Tool {
  let name = "clear_field"

  struct Args: Decodable {
    let id: String
    let narration: String?
  }

  func run(args: String) -> String {
    withArgs(args, expecting: "'id' field (string, e.g. 's1-5')") { (input: Args) in
      if let bail = gateAutomation(narration: input.narration) { return bail }
      return serializeResult(ElementInteraction.shared.clearElement(id: input.id))
    }
  }
}

// MARK: - Drag Tool

private struct DragTool: Tool {
  let name = "drag"

  struct Args: Decodable {
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double
    let narration: String?
  }

  func run(args: String) -> String {
    withArgs(args, expecting: "'startX', 'startY', 'endX', 'endY' fields") { (input: Args) in
      if let bail = gateAutomation(narration: input.narration) { return bail }
      return serializeResult(
        MouseController.shared.drag(
          from: CGPoint(x: input.startX, y: input.startY),
          to: CGPoint(x: input.endX, y: input.endY)))
    }
  }
}

// MARK: - List Displays Tool

private struct ListDisplaysTool: Tool {
  let name = "list_displays"

  func run(args: String) -> String {
    serializeResult(ScreenshotController.shared.listDisplays())
  }
}

// MARK: - Take Screenshot Tool

private struct TakeScreenshotTool: Tool {
  let name = "take_screenshot"

  func run(args: String) -> String {
    var options = ScreenshotOptions()
    if !args.isEmpty, let data = args.data(using: .utf8),
      let parsed = try? JSONDecoder().decode(ScreenshotOptions.self, from: data)
    {
      options = parsed
    }
    markObservation()
    return serializeResult(ScreenshotController.shared.capture(options: options))
  }
}

// MARK: - Act and Observe Tool

/// Run an element action and re-observe in one round-trip. Implemented as a
/// dispatcher that re-routes args through the underlying tool and bolts a
/// fresh snapshot onto the response.
private struct ActAndObserveTool: Tool {
  let name = "act_and_observe"

  struct CombinedResult: Encodable {
    let action: ElementActionResult
    let snapshot: TraversalResult?
    let snapshotError: String?
  }

  /// Dispatch table mapping action names to the underlying tool implementation.
  private static let actions: [String: Tool] = {
    let tools: [Tool] = [
      ClickElementTool(), SetValueTool(), TypeTextTool(),
      PressKeyTool(), ClearFieldTool(),
    ]
    return Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
  }()

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      return jsonError("Invalid arguments: expected JSON object")
    }
    guard let actionName = obj["action"] as? String else {
      return jsonError(
        "Missing 'action' field. Supported: \(Self.actions.keys.sorted().joined(separator: ", "))")
    }
    guard let tool = Self.actions[actionName] else {
      return jsonError(
        "Unsupported action '\(actionName)'. Supported: "
          + Self.actions.keys.sorted().joined(separator: ", "))
    }

    let observeMode = (obj["observe"] as? String) ?? "full"
    let pidFromArgs: Int32? = (obj["pid"] as? Int).map { Int32($0) }

    var subArgs = obj
    subArgs.removeValue(forKey: "action")
    subArgs.removeValue(forKey: "observe")
    subArgs.removeValue(forKey: "pid")
    let subPayload =
      (try? JSONSerialization.data(withJSONObject: subArgs))
      .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

    let actionJSON = tool.run(args: subPayload)
    let actionResult: ElementActionResult = {
      guard let d = actionJSON.data(using: .utf8),
        let parsed = try? JSONDecoder().decode(ElementActionResult.self, from: d)
      else {
        return .fail(actionJSON)
      }
      return parsed
    }()

    if observeMode == "none" {
      return serializeResult(
        CombinedResult(action: actionResult, snapshot: nil, snapshotError: nil))
    }

    let pid: Int32? =
      pidFromArgs
      ?? (subArgs["id"] as? String).flatMap { AccessibilityManager.shared.pid(for: $0) }
      ?? AccessibilityManager.shared.mostRecentPid()
    guard let pid = pid else {
      return serializeResult(
        CombinedResult(
          action: actionResult, snapshot: nil,
          snapshotError:
            "Cannot observe: no pid available. Pass 'pid' explicitly to act_and_observe."))
    }

    let snapshot = traverse(
      pid: pid,
      maxElements: (obj["maxElements"] as? Int) ?? 150,
      focusedWindowOnly: observeMode == "focused_window"
    )
    return serializeResult(
      CombinedResult(action: actionResult, snapshot: snapshot, snapshotError: nil))
  }
}

// MARK: - Session Tools

/// Common envelope for session tool responses.
private struct SessionResult: Encodable {
  let success: Bool
  let title: String
  let isActive: Bool
  let isCancelled: Bool
  let stepIndex: Int?
  let totalSteps: Int?
  let narration: String?

  static func current(success: Bool = true) -> SessionResult {
    let s = AutomationSession.shared.currentState()
    return SessionResult(
      success: success, title: s.title, isActive: s.isActive, isCancelled: s.isCancelled,
      stepIndex: s.stepIndex, totalSteps: s.totalSteps, narration: s.narration)
  }
}

private struct StartAutomationSessionTool: Tool {
  let name = "start_automation_session"

  struct Args: Decodable {
    let title: String
    let totalSteps: Int?
    let narration: String?
  }

  func run(args: String) -> String {
    withArgs(args, expecting: "'title' field") { (input: Args) in
      AutomationSession.shared.startSession(
        title: input.title, totalSteps: input.totalSteps, narration: input.narration)
      return serializeResult(SessionResult.current())
    }
  }
}

private struct UpdateAutomationSessionTool: Tool {
  let name = "update_automation_session"

  struct Args: Decodable {
    let title: String?
    let narration: String?
    let stepIndex: Int?
    let totalSteps: Int?
  }

  func run(args: String) -> String {
    withArgs(args, expecting: "at least one of 'title', 'narration', 'stepIndex', 'totalSteps'") {
      (input: Args) in
      AutomationSession.shared.updateSession(
        title: input.title, narration: input.narration,
        stepIndex: input.stepIndex, totalSteps: input.totalSteps)
      return serializeResult(SessionResult.current())
    }
  }
}

private struct EndAutomationSessionTool: Tool {
  let name = "end_automation_session"

  struct Args: Decodable {
    let reason: String?
  }

  func run(args: String) -> String {
    var reason: String? = nil
    if !args.isEmpty, let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    {
      reason = input.reason
    }
    AutomationSession.shared.endSession(reason: reason)
    return serializeResult(SessionResult.current())
  }
}

// MARK: - Tool Registry

/// All tools, keyed by their public name. Single source of truth for routing.
private let toolRegistry: [String: Tool] = {
  let tools: [Tool] = [
    OpenApplicationTool(),
    GetUIElementsTool(),
    FindElementsTool(),
    GetActiveWindowTool(),
    ClickElementTool(),
    ClickTool(),
    TypeTextTool(),
    SetValueTool(),
    ClearFieldTool(),
    PressKeyTool(),
    ScrollTool(),
    DragTool(),
    ActAndObserveTool(),
    TakeScreenshotTool(),
    ListDisplaysTool(),
    StartAutomationSessionTool(),
    UpdateAutomationSessionTool(),
    EndAutomationSessionTool(),
  ]
  return Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
}()

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

/// Opaque handle the host uses to reference the plugin. Currently empty —
/// state lives in the singletons (`AutomationSession`, `AccessibilityManager`).
private final class PluginContext {}

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
    Unmanaged.passRetained(PluginContext()).toOpaque()
  }

  api.destroy = { ctxPtr in
    // Tear down any visible HUD / Esc tap before the plugin context goes
    // away, otherwise a dangling NSPanel and event tap would outlive us.
    AutomationSession.shared.endSession(reason: "plugin destroyed")
    if let ctxPtr = ctxPtr {
      Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
    }
  }

  api.get_manifest = { _ in
    makeCString(PluginManifest.json)
  }

  api.invoke = { _, typePtr, idPtr, payloadPtr in
    guard let typePtr = typePtr, let idPtr = idPtr, let payloadPtr = payloadPtr else {
      return nil
    }
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)

    guard type == "tool" else {
      return makeCString(jsonError("Unknown capability type: \(type)"))
    }
    guard let tool = toolRegistry[id] else {
      return makeCString(jsonError("Unknown tool: \(id)"))
    }
    return makeCString(tool.run(args: payload))
  }

  return api
}()

// MARK: - Plugin Entry Point

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
