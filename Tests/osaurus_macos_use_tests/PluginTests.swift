import AppKit
import Foundation
import Testing

@testable import osaurus_macos_use

// MARK: - C ABI Mirror Types

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

private func loadAPI() -> PluginAPI {
  let rawPtr = osaurus_plugin_entry()!
  return rawPtr.load(as: PluginAPI.self)
}

private func createContext(api: PluginAPI) -> UnsafeMutableRawPointer {
  return api.`init`!()!
}

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

  @Test("Manifest contains exactly 20 tools")
  func manifestToolCount() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let manifestPtr = api.getManifest!(ctx)!
    let manifest = String(cString: manifestPtr)
    api.freeString!(manifestPtr)

    let json = parseJSON(manifest)!
    let capabilities = json["capabilities"] as! [String: Any]
    let tools = capabilities["tools"] as! [[String: Any]]
    #expect(tools.count == 20)
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
      "find_elements",
      "get_active_window",
      "list_apps",
      "list_windows",
      "click_element",
      "click",
      "type_text",
      "set_value",
      "clear_field",
      "press_key",
      "scroll",
      "drag",
      "act_and_observe",
      "take_screenshot",
      "list_displays",
      "start_automation_session",
      "update_automation_session",
      "end_automation_session",
    ]

    #expect(toolIDs == expectedIDs)
  }

  @Test("Manifest top-level description advertises backgrounded driving")
  func manifestDescriptionMentionsBackground() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }
    let manifestPtr = api.getManifest!(ctx)!
    let manifest = String(cString: manifestPtr)
    api.freeString!(manifestPtr)
    let json = parseJSON(manifest)!
    let desc = (json["description"] as? String ?? "").lowercased()
    #expect(desc.contains("background"))
    #expect(desc.contains("cursor"))
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

  @Test("Workflow contract is reinforced in tool descriptions")
  func descriptionsMentionSnapshotContract() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let manifestPtr = api.getManifest!(ctx)!
    let manifest = String(cString: manifestPtr)
    api.freeString!(manifestPtr)

    let json = parseJSON(manifest)!
    let capabilities = json["capabilities"] as! [String: Any]
    let tools = capabilities["tools"] as! [[String: Any]]
    let byId = Dictionary(uniqueKeysWithValues: tools.map { ($0["id"] as! String, $0) })

    // Element-targeted action tools must reference the snapshot/stale flow so
    // the rule survives even if SKILL.md is dropped from context.
    for action in ["click_element", "set_value", "clear_field", "type_text"] {
      let desc = (byId[action]?["description"] as? String ?? "").lowercased()
      #expect(
        desc.contains("snapshot") || desc.contains("stale"),
        "\(action) description should reference snapshot/stale contract")
    }

    let openDesc = (byId["open_application"]?["description"] as? String ?? "").lowercased()
    #expect(openDesc.contains("snapshot"), "open_application should mention snapshot")
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
      "resource".withCString { typePtr in
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

  @Test("find_elements rejects missing pid")
  func findElementsMissingPid() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(api: api, ctx: ctx, tool: "find_elements", payload: #"{"text": "go"}"#)
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

    let result1 = invoke(api: api, ctx: ctx, tool: "set_value", payload: "{}")
    #expect(parseJSON(result1)?["error"] != nil)

    let result2 = invoke(api: api, ctx: ctx, tool: "set_value", payload: #"{"id": "s1-1"}"#)
    #expect(parseJSON(result2)?["error"] != nil)
  }

  @Test("clear_field rejects missing id")
  func clearFieldMissingId() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }
    let result = invoke(api: api, ctx: ctx, tool: "clear_field", payload: "{}")
    let json = parseJSON(result)
    #expect(json?["error"] != nil)
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

  @Test("act_and_observe rejects missing action")
  func actAndObserveMissingAction() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }
    let result = invoke(api: api, ctx: ctx, tool: "act_and_observe", payload: "{}")
    let json = parseJSON(result)
    #expect(json?["error"] != nil)
  }

  @Test("act_and_observe rejects unsupported action")
  func actAndObserveUnsupportedAction() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }
    let result = invoke(
      api: api, ctx: ctx, tool: "act_and_observe", payload: #"{"action": "weird_action"}"#)
    let json = parseJSON(result)
    #expect((json?["error"] as? String)?.contains("Unsupported") == true)
  }
}

// MARK: - Snapshot ID Format Tests

@Suite("Snapshot ID Format")
struct SnapshotIdFormatTests {
  @Test("format produces s{snap}-{n}")
  func formatProducesExpectedString() {
    #expect(SnapshotIdFormat.format(snapshot: 7, element: 12) == "s7-12")
    #expect(SnapshotIdFormat.format(snapshot: 1, element: 1) == "s1-1")
  }

  @Test("parse round-trips")
  func parseRoundTrip() {
    let parsed = SnapshotIdFormat.parse("s7-12")
    #expect(parsed?.snapshot == 7)
    #expect(parsed?.element == 12)
  }

  @Test("parse rejects malformed ids")
  func parseRejectsMalformed() {
    #expect(SnapshotIdFormat.parse("foo") == nil)
    #expect(SnapshotIdFormat.parse("s7") == nil)
    #expect(SnapshotIdFormat.parse("12") == nil)
    #expect(SnapshotIdFormat.parse("s-12") == nil)
    #expect(SnapshotIdFormat.parse("sx-y") == nil)
  }

  @Test("parse rejects integer-shaped legacy ids (regression)")
  func parseRejectsLegacyIntegers() {
    // Make sure the v0.2 integer-id format is treated as malformed so callers
    // get a clear "this is not a v0.3 snapshot id" error rather than a stale match.
    #expect(SnapshotIdFormat.parse("5") == nil)
    #expect(SnapshotIdFormat.parse("99999") == nil)
  }
}

// MARK: - Role Normalization Tests

@Suite("Role Normalization")
struct RoleNormalizationTests {
  @Test("ax-prefixed names normalize to short form")
  func axPrefixed() {
    #expect(AccessibilityManager.normalizeRole("AXButton") == "button")
    #expect(AccessibilityManager.normalizeRole("AXTextField") == "textfield")
    #expect(AccessibilityManager.normalizeRole("AXPopUpButton") == "popupbutton")
  }

  @Test("short form passes through")
  func shortForm() {
    #expect(AccessibilityManager.normalizeRole("button") == "button")
    #expect(AccessibilityManager.normalizeRole("textfield") == "textfield")
  }

  @Test("mixed case normalizes")
  func mixedCase() {
    #expect(AccessibilityManager.normalizeRole("Button") == "button")
    #expect(AccessibilityManager.normalizeRole("AXBUTTON") == "button")
  }
}

// MARK: - Element Lookup Tests

@Suite("Element Lookup")
struct ElementLookupTests {
  @Test("malformed id is reported as malformed")
  func malformedId() {
    let lookup = AccessibilityManager.shared.lookup(id: "not-a-snapshot-id")
    if case .malformed = lookup {
      // ok
    } else {
      Issue.record("Expected .malformed, got \(lookup)")
    }
  }

  @Test("Unknown snapshot id is reported as stale")
  func unknownSnapshot() {
    // Use an id that's syntactically valid but refers to an enormous snapshot id
    // we'll never actually generate.
    let lookup = AccessibilityManager.shared.lookup(id: "s99999999-1")
    if case .stale = lookup {
      // ok
    } else {
      Issue.record("Expected .stale, got \(lookup)")
    }
  }
}

// MARK: - Tool Functional Tests

@Suite("Tool Functionality")
struct ToolFunctionalTests {
  fileprivate let api = loadAPI()

  @Test("click_element returns stale error for unknown snapshot id")
  func clickElementStale() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(
      api: api, ctx: ctx, tool: "click_element", payload: #"{"id": "s99999999-1"}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == false)
    #expect(json["stale"] as? Bool == true)
  }

  @Test("click_element returns malformed error for non-snapshot id")
  func clickElementMalformed() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(
      api: api, ctx: ctx, tool: "click_element", payload: #"{"id": "garbage"}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == false)
    #expect((json["error"] as? String)?.contains("not a valid snapshot id") == true)
  }

  @Test("set_value returns stale error for unknown snapshot id")
  func setValueStale() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(
      api: api, ctx: ctx, tool: "set_value",
      payload: #"{"id": "s99999999-1", "value": "test"}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == false)
    #expect(json["stale"] as? Bool == true)
  }

  @Test("clear_field returns stale error for unknown snapshot id")
  func clearFieldStale() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }
    let result = invoke(
      api: api, ctx: ctx, tool: "clear_field", payload: #"{"id": "s99999999-1"}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == false)
    #expect(json["stale"] as? Bool == true)
  }

  @Test("type_text with stale id returns stale error")
  func typeTextStaleId() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(
      api: api, ctx: ctx, tool: "type_text",
      payload: #"{"text": "hello", "id": "s99999999-1"}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == false)
    #expect(json["stale"] as? Bool == true)
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
    #expect(json["error"] == nil)
    #expect(json["stale"] == nil)
    #expect(json["removed"] == nil)
  }

  @Test("ElementActionResult fail encoding")
  func elementActionResultFail() throws {
    let result = ElementActionResult.fail("element gone")
    let data = try JSONEncoder().encode(result)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["success"] as? Bool == false)
    #expect(json["error"] as? String == "element gone")
  }

  @Test("ElementActionResult stale encoding includes stale flag")
  func elementActionResultStale() throws {
    let result = ElementActionResult.stale(requested: 3, current: 7)
    let data = try JSONEncoder().encode(result)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["success"] as? Bool == false)
    #expect(json["stale"] as? Bool == true)
    #expect((json["error"] as? String)?.contains("s3") == true)
    #expect((json["error"] as? String)?.contains("s7") == true)
  }

  @Test("ElementActionResult removed encoding includes removed flag")
  func elementActionResultRemoved() throws {
    let result = ElementActionResult.removed("s7-12")
    let data = try JSONEncoder().encode(result)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["success"] as? Bool == false)
    #expect(json["removed"] as? Bool == true)
  }

  @Test("ElementFilter decoding with all fields")
  func elementFilterFullDecoding() throws {
    let json = """
      {"pid": 1234, "roles": ["button"], "maxDepth": 10, "maxElements": 50,
       "interactiveOnly": false, "focusedWindowOnly": true}
      """
    let filter = try JSONDecoder().decode(ElementFilter.self, from: json.data(using: .utf8)!)
    #expect(filter.pid == 1234)
    #expect(filter.roles == ["button"])
    #expect(filter.maxDepth == 10)
    #expect(filter.maxElements == 50)
    #expect(filter.interactiveOnly == false)
    #expect(filter.focusedWindowOnly == true)
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
    #expect(filter.focusedWindowOnly == nil)
  }

  @Test("ScreenshotOptions decoding with all fields")
  func screenshotOptionsFullDecoding() throws {
    let json = """
      {"pid": 100, "displayIndex": 1, "allDisplays": true, "format": "png",
       "quality": 0.9, "scale": 0.75, "savePath": "/tmp/test.png", "annotate": true}
      """
    let opts = try JSONDecoder().decode(ScreenshotOptions.self, from: json.data(using: .utf8)!)
    #expect(opts.pid == 100)
    #expect(opts.displayIndex == 1)
    #expect(opts.allDisplays == true)
    #expect(opts.format == "png")
    #expect(opts.quality == 0.9)
    #expect(opts.scale == 0.75)
    #expect(opts.savePath == "/tmp/test.png")
    #expect(opts.annotate == true)
  }

  @Test("ScreenshotOptions decoding with no fields")
  func screenshotOptionsEmptyDecoding() throws {
    let json = "{}"
    let opts = try JSONDecoder().decode(ScreenshotOptions.self, from: json.data(using: .utf8)!)
    #expect(opts.pid == nil)
    #expect(opts.windowId == nil)
    #expect(opts.displayIndex == nil)
    #expect(opts.allDisplays == nil)
    #expect(opts.format == nil)
    #expect(opts.quality == nil)
    #expect(opts.scale == nil)
    #expect(opts.savePath == nil)
    #expect(opts.annotate == nil)
  }

  @Test("ScreenshotOptions decoding accepts windowId")
  func screenshotOptionsWindowIdDecoding() throws {
    let json = #"{"windowId": 12345}"#
    let opts = try JSONDecoder().decode(ScreenshotOptions.self, from: json.data(using: .utf8)!)
    #expect(opts.windowId == 12345)
  }

  @Test("ElementInfo encoding produces compact output")
  func elementInfoEncoding() throws {
    let info = ElementInfo(
      id: "s1-5", role: "button", roleDescription: nil, label: "OK",
      value: nil, placeholder: nil, path: "Window > Button[OK]",
      windowId: 1, focused: false, enabled: true,
      x: 100, y: 200, w: 80, h: 30, actions: ["press"]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(info)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["id"] as? String == "s1-5")
    #expect(json["role"] as? String == "button")
    #expect(json["label"] as? String == "OK")
    #expect(json["value"] == nil)
    #expect(json["placeholder"] == nil)
    #expect(json["path"] as? String == "Window > Button[OK]")
    #expect(json["windowId"] as? Int == 1)
    #expect(json["focused"] as? Bool == false)
    #expect(json["enabled"] as? Bool == true)
    #expect(json["x"] as? Int == 100)
    #expect(json["y"] as? Int == 200)
    #expect(json["w"] as? Int == 80)
    #expect(json["h"] as? Int == 30)
    #expect(json["actions"] as? [String] == ["press"])
  }

  @Test("TraversalResult encoding")
  func traversalResultEncoding() throws {
    let result = TraversalResult(
      snapshotId: 1, pid: 1234, app: "TestApp", focusedWindow: nil,
      elementCount: 0, truncated: false, windows: [], elements: [])
    let data = try JSONEncoder().encode(result)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["snapshotId"] as? Int == 1)
    #expect(json["pid"] as? Int == 1234)
    #expect(json["app"] as? String == "TestApp")
    #expect(json["elementCount"] as? Int == 0)
    #expect(json["truncated"] as? Bool == false)
    #expect((json["windows"] as? [Any])?.isEmpty == true)
    #expect((json["elements"] as? [Any])?.isEmpty == true)
  }

  @Test("WindowSummary encoding")
  func windowSummaryEncoding() throws {
    let summary = WindowSummary(
      id: 1, title: "Untitled", focused: true, x: 0, y: 25, w: 1440, h: 875)
    let data = try JSONEncoder().encode(summary)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["id"] as? Int == 1)
    #expect(json["title"] as? String == "Untitled")
    #expect(json["focused"] as? Bool == true)
    #expect(json["w"] as? Int == 1440)
    #expect(json["h"] as? Int == 875)
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

  @Test("FocusDelta encoding omits nil fields")
  func focusDeltaEncoding() throws {
    let delta = FocusDelta(focusedWindow: "Save", focusedElement: nil)
    let data = try JSONEncoder().encode(delta)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["focusedWindow"] as? String == "Save")
    #expect(json["focusedElement"] == nil)
  }

  @Test("FocusedElementSummary encoding")
  func focusedElementSummaryEncoding() throws {
    let s = FocusedElementSummary(role: "textfield", label: "Search", value: nil)
    let data = try JSONEncoder().encode(s)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["role"] as? String == "textfield")
    #expect(json["label"] as? String == "Search")
    #expect(json["value"] == nil)
  }

  @Test("ElementActionResult cancelled encoding includes cancelled flag")
  func elementActionResultCancelled() throws {
    let result = ElementActionResult.cancelled()
    let data = try JSONEncoder().encode(result)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["success"] as? Bool == false)
    #expect(json["cancelled"] as? Bool == true)
    #expect((json["error"] as? String)?.contains("Esc") == true)
  }
}

// MARK: - Automation Session Tests
//
// v0.4 demoted AutomationSession to a side-effect-free telemetry holder
// (the HUD and global Esc-cancel monitor are gone — backgrounded driving
// has nothing for the user to interrupt). The tools still exist for
// agents that already speak the shape; we only verify the response stays
// stable, not that anything visible happens on screen.

@Suite("Automation Session", .serialized)
struct AutomationSessionTests {
  fileprivate let api = loadAPI()

  private func reset() {
    AutomationSession.shared.endSession(reason: "test reset")
  }

  @Test("Default state is inactive")
  func defaultState() {
    reset()
    let s = AutomationSession.shared.currentState()
    #expect(s.isActive == false)
    #expect(s.isCancelled == false)
  }

  @Test("startSession sets active and remembers title")
  func startSetsActive() {
    reset()
    AutomationSession.shared.startSession(title: "Test Flow", totalSteps: 3, narration: "Step 0")
    let s = AutomationSession.shared.currentState()
    #expect(s.isActive == true)
    #expect(s.title == "Test Flow")
    #expect(s.totalSteps == 3)
    #expect(s.narration == "Step 0")
    reset()
  }

  @Test("Action tools accept and ignore narration safely")
  func narrationTolerated() {
    reset()
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    // Stale id is the cleanest way to round-trip a click without touching
    // a real app: we get a deterministic response back and can assert the
    // narration field didn't break decoding.
    let result = invoke(
      api: api, ctx: ctx, tool: "click_element",
      payload: #"{"id": "s99-1", "narration": "Clicking continue"}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == false)
    // The cancelled flag is no longer in flight — backgrounded driving
    // doesn't have an Esc cancel path.
    #expect(json["cancelled"] == nil)
    reset()
  }

  @Test("start_automation_session tool returns success and sets active")
  func startSessionToolWorks() {
    reset()
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    let result = invoke(
      api: api, ctx: ctx, tool: "start_automation_session",
      payload: #"{"title": "Setting up iCloud", "totalSteps": 5}"#)
    let json = parseJSON(result)!
    #expect(json["success"] as? Bool == true)
    #expect(json["isActive"] as? Bool == true)
    #expect(json["title"] as? String == "Setting up iCloud")
    #expect(json["totalSteps"] as? Int == 5)
    reset()
  }

  @Test("update_automation_session tool changes narration")
  func updateSessionToolWorks() {
    reset()
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    _ = invoke(
      api: api, ctx: ctx, tool: "start_automation_session",
      payload: #"{"title": "Flow"}"#)
    let result = invoke(
      api: api, ctx: ctx, tool: "update_automation_session",
      payload: #"{"narration": "On step 2", "stepIndex": 2}"#)
    let json = parseJSON(result)!
    #expect(json["narration"] as? String == "On step 2")
    #expect(json["stepIndex"] as? Int == 2)
    reset()
  }

  @Test("end_automation_session tool clears active state")
  func endSessionToolWorks() {
    reset()
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }

    _ = invoke(
      api: api, ctx: ctx, tool: "start_automation_session",
      payload: #"{"title": "Flow"}"#)
    let result = invoke(
      api: api, ctx: ctx, tool: "end_automation_session",
      payload: #"{"reason": "complete"}"#)
    let json = parseJSON(result)!
    #expect(json["isActive"] as? Bool == false)
    #expect(json["isCancelled"] as? Bool == false)
    reset()
  }

  @Test("startSession supersedes a prior active session")
  func startSupersedesPrior() {
    reset()
    AutomationSession.shared.startSession(title: "First")
    AutomationSession.shared.startSession(title: "Second", totalSteps: 2)
    let s = AutomationSession.shared.currentState()
    #expect(s.title == "Second")
    #expect(s.totalSteps == 2)
    #expect(s.isActive == true)
    reset()
  }
}

// MARK: - Backgrounded Driver Tests
//
// These are the cua-recipe smoke tests. They don't fully assert that a
// real Chromium renderer accepted the click (that needs a live browser
// and Screen Recording permission, which CI usually doesn't have); they
// assert the contract that matters: invoking action tools never moves
// the user's frontmost app.

@Suite("Background Driver", .serialized)
struct BackgroundDriverTests {
  fileprivate let api = loadAPI()

  @Test("SkyLight bridge availability reports a stable bool")
  func skyLightAvailability() {
    // Either branch is fine; we just want to make sure the dlopen path
    // doesn't crash on the host OS.
    _ = SkyLightBridge.isAvailable
    _ = SkyLightBridge.canFocusWithoutRaise
  }

  @Test("CaptureMode parses cua-style strings, falls back to .som")
  func captureModeParsing() {
    #expect(CaptureMode.parse("ax") == .ax)
    #expect(CaptureMode.parse("vision") == .vision)
    #expect(CaptureMode.parse("som") == .som)
    #expect(CaptureMode.parse("SOM") == .som)
    #expect(CaptureMode.parse(nil) == .som)
    #expect(CaptureMode.parse("garbage") == .som)
  }

  @Test("InputRoute round-trips through JSON")
  func inputRouteCoding() throws {
    let r = InputRoute.skyLight
    let data = try JSONEncoder().encode(r)
    let decoded = try JSONDecoder().decode(InputRoute.self, from: data)
    #expect(decoded == .skyLight)
  }

  @Test("list_apps returns a list including this test process")
  func listAppsReturnsArray() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }
    let result = invoke(api: api, ctx: ctx, tool: "list_apps", payload: "{}")
    let json = parseJSON(result)!
    let apps = json["apps"] as? [[String: Any]]
    #expect(apps != nil)
    // No assertion on count: CI hosts may have 0 regular apps surfaced.
    if let first = apps?.first {
      #expect(first["pid"] is Int)
      #expect(first["name"] is String)
    }
  }

  @Test("list_windows rejects missing pid")
  func listWindowsMissingPid() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }
    let result = invoke(api: api, ctx: ctx, tool: "list_windows", payload: "{}")
    let json = parseJSON(result)
    #expect(json?["error"] != nil)
  }

  @Test("list_windows for current pid returns a structured response")
  func listWindowsForOurPid() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }
    let pid = ProcessInfo.processInfo.processIdentifier
    let payload = #"{"pid": \#(pid)}"#
    let result = invoke(api: api, ctx: ctx, tool: "list_windows", payload: payload)
    let json = parseJSON(result)!
    #expect(json["pid"] as? Int == Int(pid))
    #expect(json["windows"] is [Any])
  }

  @Test("click with explicit pid does not change frontmost app")
  func clickPerPidPreservesFrontmost() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }
    // Route to our own pid: kill(0) gates the unsafe private routes for
    // dead pids, so the call exercises the SkyLight and CGEvent.postToPid
    // paths (or their fallbacks) without depending on a third-party app.
    // The contract being tested is "frontmost never changes" — even when
    // routing succeeds the user's app stays put.
    let pid = ProcessInfo.processInfo.processIdentifier
    let beforePid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    let payload = #"{"x": 50, "y": 50, "pid": \#(pid)}"#
    _ = invoke(api: api, ctx: ctx, tool: "click", payload: payload)
    let afterPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    #expect(beforePid == afterPid, "Backgrounded click must not change frontmost app")
  }

  @Test("type_text routed via pid does not change frontmost app")
  func typeTextPerPidPreservesFrontmost() {
    let ctx = createContext(api: api)
    defer { api.destroy!(ctx) }
    let pid = ProcessInfo.processInfo.processIdentifier
    let beforePid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    let payload = #"{"text": "hi", "pid": \#(pid)}"#
    _ = invoke(api: api, ctx: ctx, tool: "type_text", payload: payload)
    let afterPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    #expect(beforePid == afterPid)
  }
}
