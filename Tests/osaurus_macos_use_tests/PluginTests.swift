import Foundation
import Testing

@testable import osaurus_macos_use

// MARK: - C ABI Mirror Types

// Mirror the plugin API struct layout to test through the C entry point
private typealias FreeStringFn = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias InitFn = @convention(c) () -> UnsafeMutableRawPointer?
private typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias GetManifestFn =
  @convention(c) (UnsafeMutableRawPointer?) ->
  UnsafePointer<CChar>?
private typealias InvokeFn =
  @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
  ) -> UnsafePointer<CChar>?

private struct PluginAPI {
  var freeString: FreeStringFn?
  var `init`: InitFn?
  var destroy: DestroyFn?
  var getManifest: GetManifestFn?
  var invoke: InvokeFn?
}

// MARK: - Test Helpers

/// Load the plugin API from the entry point
private func loadAPI() -> PluginAPI {
  let rawPtr = osaurus_plugin_entry()!
  return rawPtr.load(as: PluginAPI.self)
}

/// Create a plugin context via the C ABI
private func createContext(api: PluginAPI) -> UnsafeMutableRawPointer {
  return api.`init`!()!
}

/// Invoke a tool and return the result as a String
private func invoke(
  api: PluginAPI, ctx: UnsafeMutableRawPointer, tool: String, payload: String
) -> String {
  let resultPtr = tool.withCString { toolPtr in
    "tool".withCString { typePtr in
      payload.withCString { payloadPtr in
        api.invoke!(ctx, typePtr, toolPtr, payloadPtr)
      }
    }
  }
  guard let resultPtr else { return "" }
  let result = String(cString: resultPtr)
  api.freeString!(resultPtr)
  return result
}

/// Parse a JSON string into a dictionary
private func parseJSON(_ json: String) -> [String: Any]? {
  guard let data = json.data(using: .utf8) else { return nil }
  return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// MARK: - Plugin Entry Point Tests

@Suite("Plugin Entry Point")
struct PluginEntryTests {
  @Test("osaurus_plugin_entry returns a valid API pointer")
  func entryReturnsValidPointer() {
    let ptr = osaurus_plugin_entry()
    #expect(ptr != nil)
  }

  @Test("API has all function pointers set")
  func apiHasAllFunctions() {
    let api = loadAPI()
    #expect(api.freeString != nil)
    #expect(api.`init` != nil)
    #expect(api.destroy != nil)
    #expect(api.getManifest != nil)
    #expect(api.invoke != nil)
  }

  @Test("init and destroy lifecycle works")
  func initDestroyLifecycle() {
    let api = loadAPI()
    let ctx = api.`init`!()
    #expect(ctx != nil)
    api.destroy!(ctx)
  }
}

// MARK: - Manifest Tests

@Suite("Plugin Manifest")
struct ManifestTests {
  fileprivate let api = loadAPI()

  @Test("Manifest is valid JSON")
  func manifestIsValidJSON() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let manifestPtr = api.getManifest!(ctx)!
    let manifest = String(cString: manifestPtr)
    api.freeString!(manifestPtr)

    let json = parseJSON(manifest)
    #expect(json != nil)
  }

  @Test("Manifest contains correct plugin metadata")
  func manifestMetadata() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let manifestPtr = api.getManifest!(ctx)!
    let manifest = String(cString: manifestPtr)
    api.freeString!(manifestPtr)

    let json = parseJSON(manifest)!
    #expect(json["plugin_id"] as? String == "osaurus.macos-use")
    #expect(json["name"] as? String == "macOS Use")
    #expect(json["min_macos"] as? String == "13.0")
  }

  @Test("Manifest contains exactly 12 tools")
  func manifestToolCount() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let manifestPtr = api.getManifest!(ctx)!
    let manifest = String(cString: manifestPtr)
    api.freeString!(manifestPtr)

    let json = parseJSON(manifest)!
    let capabilities = json["capabilities"] as! [String: Any]
    let tools = capabilities["tools"] as! [[String: Any]]
    #expect(tools.count == 12)
  }

  @Test("Manifest contains all expected tool IDs")
  func manifestToolIDs() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let manifestPtr = api.getManifest!(ctx)!
    let manifest = String(cString: manifestPtr)
    api.freeString!(manifestPtr)

    let json = parseJSON(manifest)!
    let capabilities = json["capabilities"] as! [String: Any]
    let tools = capabilities["tools"] as! [[String: Any]]
    let toolIDs = Set(tools.compactMap { $0["id"] as? String })

    let expectedIDs: Set<String> = [
      "open_application",
      "get_ui_elements",
      "get_active_window",
      "click_element",
      "click",
      "type_text",
      "set_value",
      "press_key",
      "scroll",
      "drag",
      "take_screenshot",
      "list_displays",
    ]

    #expect(toolIDs == expectedIDs)
  }

  @Test("No removed tools in manifest")
  func noRemovedTools() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let manifestPtr = api.getManifest!(ctx)!
    let manifest = String(cString: manifestPtr)
    api.freeString!(manifestPtr)

    let json = parseJSON(manifest)!
    let capabilities = json["capabilities"] as! [String: Any]
    let tools = capabilities["tools"] as! [[String: Any]]
    let toolIDs = Set(tools.compactMap { $0["id"] as? String })

    let removedTools = [
      "focus_element",
      "click_element_and_observe",
      "type_and_observe",
      "press_key_and_observe",
    ]

    for removed in removedTools {
      #expect(!toolIDs.contains(removed), "Tool '\(removed)' should have been removed")
    }
  }

  @Test("Each tool has required fields")
  func toolsHaveRequiredFields() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let manifestPtr = api.getManifest!(ctx)!
    let manifest = String(cString: manifestPtr)
    api.freeString!(manifestPtr)

    let json = parseJSON(manifest)!
    let capabilities = json["capabilities"] as! [String: Any]
    let tools = capabilities["tools"] as! [[String: Any]]

    for tool in tools {
      let toolId = tool["id"] as? String ?? "unknown"
      #expect(tool["id"] is String, "Tool missing 'id'")
      #expect(tool["description"] is String, "Tool '\(toolId)' missing 'description'")
      #expect(tool["parameters"] is [String: Any], "Tool '\(toolId)' missing 'parameters'")
      #expect(
        tool["permission_policy"] as? String == "ask",
        "Tool '\(toolId)' should have permission_policy 'ask'")
    }
  }
}

// MARK: - Invoke Routing Tests

@Suite("Tool Invoke Routing")
struct InvokeRoutingTests {
  fileprivate let api = loadAPI()

  @Test("Unknown tool returns error")
  func unknownToolError() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "nonexistent_tool", payload: "{}")
    let json = parseJSON(result)
    #expect(json?["error"] as? String == "Unknown tool: nonexistent_tool")
  }

  @Test("Unknown capability type returns error")
  func unknownCapabilityType() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let resultPtr = "open_application".withCString { toolPtr in
      "resource".withCString { typePtr in  // "resource" instead of "tool"
        "{}".withCString { payloadPtr in
          api.invoke!(ctx, typePtr, toolPtr, payloadPtr)
        }
      }
    }
    guard let resultPtr else { return }
    let result = String(cString: resultPtr)
    api.freeString!(resultPtr)

    let json = parseJSON(result)
    #expect((json?["error"] as? String)?.contains("Unknown capability type") == true)
  }
}

// MARK: - Tool Argument Validation Tests

@Suite("Tool Argument Validation")
struct ArgumentValidationTests {
  fileprivate let api = loadAPI()

  @Test("open_application rejects missing identifier")
  func openAppMissingIdentifier() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "open_application", payload: "{}")
    let json = parseJSON(result)
    #expect(json?["error"] != nil)
  }

  @Test("get_ui_elements rejects missing pid")
  func getUIElementsMissingPid() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "get_ui_elements", payload: "{}")
    let json = parseJSON(result)
    #expect(json?["error"] != nil)
  }

  @Test("click rejects missing coordinates")
  func clickMissingCoords() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "click", payload: "{}")
    let json = parseJSON(result)
    #expect(json?["error"] != nil)
  }

  @Test("click_element rejects missing id")
  func clickElementMissingId() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "click_element", payload: "{}")
    let json = parseJSON(result)
    #expect(json?["error"] != nil)
  }

  @Test("type_text rejects missing text")
  func typeTextMissingText() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "type_text", payload: "{}")
    let json = parseJSON(result)
    #expect(json?["error"] != nil)
  }

  @Test("set_value rejects missing fields")
  func setValueMissingFields() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    // Missing both id and value
    let result1 = invoke(api: api, ctx: ctx, tool: "set_value", payload: "{}")
    #expect(parseJSON(result1)?["error"] != nil)

    // Missing value
    let result2 = invoke(api: api, ctx: ctx, tool: "set_value", payload: #"{"id": 1}"#)
    #expect(parseJSON(result2)?["error"] != nil)
  }

  @Test("press_key rejects missing key")
  func pressKeyMissingKey() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "press_key", payload: "{}")
    let json = parseJSON(result)
    #expect(json?["error"] != nil)
  }

  @Test("scroll rejects missing direction")
  func scrollMissingDirection() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "scroll", payload: "{}")
    let json = parseJSON(result)
    #expect(json?["error"] != nil)
  }

  @Test("scroll rejects invalid direction")
  func scrollInvalidDirection() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(
      api: api, ctx: ctx, tool: "scroll", payload: #"{"direction": "diagonal"}"#)
    let json = parseJSON(result)
    #expect(json?["error"] != nil)
  }

  @Test("drag rejects missing coordinates")
  func dragMissingCoords() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "drag", payload: "{}")
    let json = parseJSON(result)
    #expect(json?["error"] != nil)
  }
}

// MARK: - Tool Functional Tests

@Suite("Tool Functionality")
struct ToolFunctionalTests {
  fileprivate let api = loadAPI()

  @Test("click_element returns error for non-existent element")
  func clickElementNotFound() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "click_element", payload: #"{"id": 99999}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == false)
    #expect((json["error"] as? String)?.contains("not found") == true)
  }

  @Test("click_element with right button returns error for non-existent element")
  func clickElementRightNotFound() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(
      api: api, ctx: ctx, tool: "click_element",
      payload: #"{"id": 99999, "button": "right"}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == false)
  }

  @Test("click_element with doubleClick returns error for non-existent element")
  func clickElementDoubleNotFound() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(
      api: api, ctx: ctx, tool: "click_element",
      payload: #"{"id": 99999, "doubleClick": true}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == false)
  }

  @Test("set_value returns error for non-existent element")
  func setValueNotFound() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(
      api: api, ctx: ctx, tool: "set_value",
      payload: #"{"id": 99999, "value": "test"}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == false)
    #expect((json["error"] as? String)?.contains("not found") == true)
  }

  @Test("type_text with non-existent element id returns focus error")
  func typeTextBadIdFails() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(
      api: api, ctx: ctx, tool: "type_text",
      payload: #"{"text": "hello", "id": 99999}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == false)
  }

  @Test("press_key with unknown key returns error")
  func pressKeyUnknownKey() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(
      api: api, ctx: ctx, tool: "press_key",
      payload: #"{"key": "nonexistent_key_name"}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == false)
    #expect((json["error"] as? String)?.contains("Unknown key") == true)
  }

  @Test("get_active_window returns valid structure")
  func getActiveWindowStructure() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "get_active_window", payload: "{}")
    let json = parseJSON(result)
    #expect(json != nil)
    // Should have either window info or an error (if no window is active in CI)
    if json?["error"] == nil {
      #expect(json?["pid"] is Int)
      #expect(json?["app"] is String)
    }
  }

  @Test("list_displays returns valid structure")
  func listDisplaysStructure() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "list_displays", payload: "{}")
    let json = parseJSON(result)!
    let displays = json["displays"] as? [[String: Any]]
    #expect(displays != nil)
    // Should have at least one display
    #expect((displays?.count ?? 0) >= 1)

    if let first = displays?.first {
      #expect(first["index"] is Int)
      #expect(first["width"] is Int)
      #expect(first["height"] is Int)
      #expect(first["isMain"] is Bool)
    }
  }

  @Test("take_screenshot returns content array")
  func takeScreenshotReturnsContent() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "take_screenshot", payload: "{}")
    let json = parseJSON(result)!
    let content = json["content"] as? [[String: Any]]
    #expect(content != nil)
    #expect((content?.count ?? 0) >= 1)
  }
}

// MARK: - Modifier Flags Parsing Tests

@Suite("Modifier Flags Parsing")
struct ModifierFlagsTests {
  @Test("nil flags returns empty")
  func nilFlags() {
    let flags = parseModifierFlags(nil)
    #expect(flags == [])
  }

  @Test("empty array returns empty")
  func emptyFlags() {
    let flags = parseModifierFlags([])
    #expect(flags == [])
  }

  @Test("command modifier")
  func commandModifier() {
    let flags = parseModifierFlags(["command"])
    #expect(flags.contains(.maskCommand))
  }

  @Test("cmd alias")
  func cmdAlias() {
    let flags = parseModifierFlags(["cmd"])
    #expect(flags.contains(.maskCommand))
  }

  @Test("shift modifier")
  func shiftModifier() {
    let flags = parseModifierFlags(["shift"])
    #expect(flags.contains(.maskShift))
  }

  @Test("control modifier")
  func controlModifier() {
    let flags = parseModifierFlags(["control"])
    #expect(flags.contains(.maskControl))
  }

  @Test("ctrl alias")
  func ctrlAlias() {
    let flags = parseModifierFlags(["ctrl"])
    #expect(flags.contains(.maskControl))
  }

  @Test("option modifier")
  func optionModifier() {
    let flags = parseModifierFlags(["option"])
    #expect(flags.contains(.maskAlternate))
  }

  @Test("alt alias")
  func altAlias() {
    let flags = parseModifierFlags(["alt"])
    #expect(flags.contains(.maskAlternate))
  }

  @Test("opt alias")
  func optAlias() {
    let flags = parseModifierFlags(["opt"])
    #expect(flags.contains(.maskAlternate))
  }

  @Test("function modifier")
  func functionModifier() {
    let flags = parseModifierFlags(["fn"])
    #expect(flags.contains(.maskSecondaryFn))
  }

  @Test("capslock modifier")
  func capslockModifier() {
    let flags = parseModifierFlags(["capslock"])
    #expect(flags.contains(.maskAlphaShift))
  }

  @Test("multiple modifiers combined")
  func multipleModifiers() {
    let flags = parseModifierFlags(["command", "shift", "option"])
    #expect(flags.contains(.maskCommand))
    #expect(flags.contains(.maskShift))
    #expect(flags.contains(.maskAlternate))
  }

  @Test("case insensitive")
  func caseInsensitive() {
    let flags = parseModifierFlags(["Command", "SHIFT", "Option"])
    #expect(flags.contains(.maskCommand))
    #expect(flags.contains(.maskShift))
    #expect(flags.contains(.maskAlternate))
  }

  @Test("unknown modifier is ignored")
  func unknownModifier() {
    let flags = parseModifierFlags(["command", "unknown"])
    #expect(flags.contains(.maskCommand))
    // "unknown" should be silently ignored
  }
}

// MARK: - Data Model Tests

@Suite("Data Models")
struct DataModelTests {
  @Test("InputResult ok encoding")
  func inputResultOk() throws {
    let result = InputResult.ok()
    let data = try JSONEncoder().encode(result)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["success"] as? Bool == true)
    // nil optionals are omitted by Swift's default Encodable
    #expect(json["error"] == nil)
  }

  @Test("InputResult fail encoding")
  func inputResultFail() throws {
    let result = InputResult.fail("something went wrong")
    let data = try JSONEncoder().encode(result)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["success"] as? Bool == false)
    #expect(json["error"] as? String == "something went wrong")
  }

  @Test("ElementActionResult ok encoding")
  func elementActionResultOk() throws {
    let result = ElementActionResult.ok()
    let data = try JSONEncoder().encode(result)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["success"] as? Bool == true)
    // nil optionals are omitted by Swift's default Encodable
    #expect(json["error"] == nil)
  }

  @Test("ElementActionResult fail encoding")
  func elementActionResultFail() throws {
    let result = ElementActionResult.fail("element gone")
    let data = try JSONEncoder().encode(result)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["success"] as? Bool == false)
    #expect(json["error"] as? String == "element gone")
  }

  @Test("ElementFilter decoding with all fields")
  func elementFilterFullDecoding() throws {
    let json =
      #"{"pid": 1234, "roles": ["button"], "maxDepth": 10, "maxElements": 50, "interactiveOnly": false}"#
    let filter = try JSONDecoder().decode(ElementFilter.self, from: json.data(using: .utf8)!)
    #expect(filter.pid == 1234)
    #expect(filter.roles == ["button"])
    #expect(filter.maxDepth == 10)
    #expect(filter.maxElements == 50)
    #expect(filter.interactiveOnly == false)
  }

  @Test("ElementFilter decoding with only required fields")
  func elementFilterMinimalDecoding() throws {
    let json = #"{"pid": 5678}"#
    let filter = try JSONDecoder().decode(ElementFilter.self, from: json.data(using: .utf8)!)
    #expect(filter.pid == 5678)
    #expect(filter.roles == nil)
    #expect(filter.maxDepth == nil)
    #expect(filter.maxElements == nil)
    #expect(filter.interactiveOnly == nil)
  }

  @Test("ScreenshotOptions decoding with all fields")
  func screenshotOptionsFullDecoding() throws {
    let json =
      #"{"pid": 100, "displayIndex": 1, "allDisplays": true, "format": "png", "quality": 0.9, "scale": 0.75, "savePath": "/tmp/test.png"}"#
    let opts = try JSONDecoder().decode(ScreenshotOptions.self, from: json.data(using: .utf8)!)
    #expect(opts.pid == 100)
    #expect(opts.displayIndex == 1)
    #expect(opts.allDisplays == true)
    #expect(opts.format == "png")
    #expect(opts.quality == 0.9)
    #expect(opts.scale == 0.75)
    #expect(opts.savePath == "/tmp/test.png")
  }

  @Test("ScreenshotOptions decoding with no fields")
  func screenshotOptionsEmptyDecoding() throws {
    let json = "{}"
    let opts = try JSONDecoder().decode(ScreenshotOptions.self, from: json.data(using: .utf8)!)
    #expect(opts.pid == nil)
    #expect(opts.displayIndex == nil)
    #expect(opts.allDisplays == nil)
    #expect(opts.format == nil)
    #expect(opts.quality == nil)
    #expect(opts.scale == nil)
    #expect(opts.savePath == nil)
  }

  @Test("ElementInfo encoding produces compact output")
  func elementInfoEncoding() throws {
    let info = ElementInfo(
      id: 1, role: "button", label: "OK", value: nil,
      x: 100, y: 200, w: 80, h: 30, actions: ["press"]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(info)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["id"] as? Int == 1)
    #expect(json["role"] as? String == "button")
    #expect(json["label"] as? String == "OK")
    // nil optionals are omitted by Swift's default Encodable
    #expect(json["value"] == nil)
    #expect(json["x"] as? Int == 100)
    #expect(json["y"] as? Int == 200)
    #expect(json["w"] as? Int == 80)
    #expect(json["h"] as? Int == 30)
    #expect(json["actions"] as? [String] == ["press"])
  }

  @Test("TraversalResult encoding")
  func traversalResultEncoding() throws {
    let result = TraversalResult(pid: 1234, app: "TestApp", elementCount: 0, elements: [])
    let data = try JSONEncoder().encode(result)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["pid"] as? Int == 1234)
    #expect(json["app"] as? String == "TestApp")
    #expect(json["elementCount"] as? Int == 0)
    #expect((json["elements"] as? [Any])?.isEmpty == true)
  }

  @Test("WindowInfo encoding")
  func windowInfoEncoding() throws {
    let info = WindowInfo(pid: 42, app: "Finder", title: "Documents", x: 0, y: 25, w: 1440, h: 875)
    let data = try JSONEncoder().encode(info)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["pid"] as? Int == 42)
    #expect(json["app"] as? String == "Finder")
    #expect(json["title"] as? String == "Documents")
    #expect(json["w"] as? Int == 1440)
    #expect(json["h"] as? Int == 875)
  }

  @Test("AppInfo encoding")
  func appInfoEncoding() throws {
    let info = AppInfo(pid: 100, bundleId: "com.apple.Safari", name: "Safari")
    let data = try JSONEncoder().encode(info)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["pid"] as? Int == 100)
    #expect(json["bundleId"] as? String == "com.apple.Safari")
    #expect(json["name"] as? String == "Safari")
  }
}
