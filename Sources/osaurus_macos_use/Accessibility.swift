import AppKit
import ApplicationServices
import Foundation

// MARK: - Element Info

/// Compact representation of an accessibility element for agent consumption
struct ElementInfo: Encodable {
  let id: Int
  let role: String
  let label: String?
  let value: String?
  let x: Int
  let y: Int
  let w: Int
  let h: Int
  let actions: [String]
}

// MARK: - Cached Element

/// Internal representation storing AXUIElement reference for later interaction
final class CachedElement: @unchecked Sendable {
  let axElement: AXUIElement
  let role: String
  let supportedActions: [String]

  init(axElement: AXUIElement, role: String, supportedActions: [String]) {
    self.axElement = axElement
    self.role = role
    self.supportedActions = supportedActions
  }

  /// Re-query the current frame from the accessibility element
  func getCurrentFrame() -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?

    guard
      AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &positionValue)
        == .success,
      AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeValue) == .success
    else {
      return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero

    if let posVal = positionValue {
      AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
    }
    if let sizeVal = sizeValue {
      AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
    }

    return CGRect(origin: position, size: size)
  }

  /// Check if this element supports a specific action
  func supportsAction(_ action: String) -> Bool {
    return supportedActions.contains(action)
  }

  /// Perform an accessibility action on this element
  func performAction(_ action: String) -> Bool {
    let result = AXUIElementPerformAction(axElement, action as CFString)
    return result == .success
  }
}

// MARK: - Element Filter

/// Filter options for UI element traversal
struct ElementFilter: Decodable {
  var pid: Int32
  var roles: [String]?
  var maxDepth: Int?
  var maxElements: Int?
  var interactiveOnly: Bool?
}

// MARK: - Traversal Result

struct TraversalResult: Encodable {
  let pid: Int32
  let app: String
  let elementCount: Int
  let elements: [ElementInfo]
}

// MARK: - Accessibility Manager

/// Manages accessibility tree traversal and element caching
final class AccessibilityManager: @unchecked Sendable {
  static let shared = AccessibilityManager()

  private var elementCache: [Int: CachedElement] = [:]
  private var nextElementId: Int = 1
  private let lock = NSLock()

  private init() {}

  /// Clear the element cache and reset IDs
  func clearCache() {
    lock.lock()
    defer { lock.unlock() }
    elementCache.removeAll()
    nextElementId = 1
  }

  /// Get a cached element by ID
  func getElement(id: Int) -> CachedElement? {
    lock.lock()
    defer { lock.unlock() }
    return elementCache[id]
  }

  /// Interactive roles that agents typically want to interact with
  private static let interactiveRoles: Set<String> = [
    "AXButton",
    "AXLink",
    "AXTextField",
    "AXTextArea",
    "AXCheckBox",
    "AXRadioButton",
    "AXPopUpButton",
    "AXComboBox",
    "AXSlider",
    "AXMenuItem",
    "AXMenuButton",
    "AXTab",
    "AXTabGroup",
    "AXDisclosureTriangle",
    "AXIncrementor",
    "AXColorWell",
    "AXSearchField",
    "AXSecureTextField",
  ]

  /// Traverse the accessibility tree for a given PID with filtering
  func traverse(filter: ElementFilter) -> TraversalResult {
    clearCache()

    let app = AXUIElementCreateApplication(filter.pid)
    let appName = getAppName(for: filter.pid) ?? "Unknown"

    var elements: [ElementInfo] = []
    let maxDepth = filter.maxDepth ?? 15
    let maxElements = filter.maxElements ?? 100
    let interactiveOnly = filter.interactiveOnly ?? true
    let allowedRoles: Set<String>? = filter.roles.map { Set($0) }

    traverseElement(
      element: app,
      depth: 0,
      maxDepth: maxDepth,
      maxElements: maxElements,
      interactiveOnly: interactiveOnly,
      allowedRoles: allowedRoles,
      elements: &elements
    )

    return TraversalResult(
      pid: filter.pid,
      app: appName,
      elementCount: elements.count,
      elements: elements
    )
  }

  private func traverseElement(
    element: AXUIElement,
    depth: Int,
    maxDepth: Int,
    maxElements: Int,
    interactiveOnly: Bool,
    allowedRoles: Set<String>?,
    elements: inout [ElementInfo]
  ) {
    // Stop if we've reached limits
    if depth > maxDepth || elements.count >= maxElements {
      return
    }

    // Get role
    guard let role = getAttribute(element, kAXRoleAttribute) as? String else {
      return
    }

    // Check if we should include this element
    let isInteractive = Self.interactiveRoles.contains(role)
    let matchesRoleFilter = allowedRoles == nil || allowedRoles!.contains(role)

    if (!interactiveOnly || isInteractive) && matchesRoleFilter {
      // Get frame
      if let frame = getFrame(element), frame.width > 0, frame.height > 0 {
        // Get label and value
        let label =
          getAttribute(element, kAXTitleAttribute) as? String
          ?? getAttribute(element, kAXDescriptionAttribute) as? String
        let value = getAttribute(element, kAXValueAttribute) as? String

        // Get supported actions
        let actions = getSupportedActions(element)

        // Only include if there's a label or it has actions
        if label != nil || !actions.isEmpty {
          lock.lock()
          let elementId = nextElementId
          nextElementId += 1

          // Cache the element
          let cached = CachedElement(
            axElement: element,
            role: role,
            supportedActions: actions
          )
          elementCache[elementId] = cached
          lock.unlock()

          // Create compact info
          let info = ElementInfo(
            id: elementId,
            role: simplifyRole(role),
            label: label,
            value: value,
            x: Int(frame.origin.x),
            y: Int(frame.origin.y),
            w: Int(frame.width),
            h: Int(frame.height),
            actions: actions.map { simplifyAction($0) }
          )
          elements.append(info)
        }
      }
    }

    // Traverse children
    guard let children = getAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
      return
    }

    for child in children {
      if elements.count >= maxElements {
        break
      }
      traverseElement(
        element: child,
        depth: depth + 1,
        maxDepth: maxDepth,
        maxElements: maxElements,
        interactiveOnly: interactiveOnly,
        allowedRoles: allowedRoles,
        elements: &elements
      )
    }
  }

  private func getAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return result == .success ? value : nil
  }

  private func getFrame(_ element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?

    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
    else {
      return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero

    if let posVal = positionValue {
      AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
    }
    if let sizeVal = sizeValue {
      AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
    }

    return CGRect(origin: position, size: size)
  }

  private func getSupportedActions(_ element: AXUIElement) -> [String] {
    var actionsRef: CFArray?
    guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
      let actions = actionsRef as? [String]
    else {
      return []
    }

    // Filter to commonly useful actions
    let usefulActions: Set<String> = [
      "AXPress", "AXCancel", "AXConfirm", "AXDecrement", "AXIncrement",
      "AXPick", "AXShowMenu",
    ]

    return actions.filter { usefulActions.contains($0) }
  }

  private func simplifyRole(_ role: String) -> String {
    // Remove "AX" prefix for cleaner output
    if role.hasPrefix("AX") {
      return String(role.dropFirst(2)).lowercased()
    }
    return role.lowercased()
  }

  private func simplifyAction(_ action: String) -> String {
    // Remove "AX" prefix for cleaner output
    if action.hasPrefix("AX") {
      return String(action.dropFirst(2)).lowercased()
    }
    return action.lowercased()
  }

  private func getAppName(for pid: Int32) -> String? {
    let app = NSRunningApplication(processIdentifier: pid)
    return app?.localizedName
  }
}

// MARK: - App Opener

struct AppInfo: Encodable, Sendable {
  let pid: Int32
  let bundleId: String?
  let name: String
}

struct AppError: Error, Sendable {
  let message: String
}

/// Open or activate an application
func openApplication(identifier: String) async -> Result<AppInfo, AppError> {
  let workspace = NSWorkspace.shared
  let runningApps = workspace.runningApplications
  let lowerId = identifier.lowercased()

  // Check if already running (by name or bundle ID)
  if let app = runningApps.first(where: {
    $0.localizedName?.lowercased() == lowerId || $0.bundleIdentifier?.lowercased() == lowerId
  }) {
    app.activate()
    try? await Task.sleep(nanoseconds: 300_000_000)
    return .success(
      AppInfo(
        pid: app.processIdentifier,
        bundleId: app.bundleIdentifier,
        name: app.localizedName ?? identifier
      ))
  }

  // Not running — try to launch
  do {
    let app = try await launchApplication(identifier: identifier, workspace: workspace)
    try? await Task.sleep(nanoseconds: 500_000_000)
    return .success(
      AppInfo(
        pid: app.processIdentifier,
        bundleId: app.bundleIdentifier,
        name: app.localizedName ?? identifier
      ))
  } catch {
    return .failure(AppError(message: "Failed to open application: \(error.localizedDescription)"))
  }
}

/// Launch an application by bundle ID or name
private func launchApplication(
  identifier: String, workspace: NSWorkspace
) async throws -> NSRunningApplication {
  let config = NSWorkspace.OpenConfiguration()
  config.activates = true

  // Try by bundle ID first
  if let url = workspace.urlForApplication(withBundleIdentifier: identifier) {
    return try await workspace.openApplication(at: url, configuration: config)
  }

  // Try by name in common application directories
  let searchPaths = [
    "/Applications/\(identifier).app",
    "/System/Applications/\(identifier).app",
    "/System/Applications/Utilities/\(identifier).app",
    NSHomeDirectory() + "/Applications/\(identifier).app",
  ]

  for path in searchPaths where FileManager.default.fileExists(atPath: path) {
    return try await workspace.openApplication(
      at: URL(fileURLWithPath: path), configuration: config)
  }

  throw AppError(message: "Application not found: \(identifier)")
}

// MARK: - Active Window Info

struct WindowInfo: Encodable {
  let pid: Int32
  let app: String
  let title: String?
  let x: Int
  let y: Int
  let w: Int
  let h: Int
}

/// Get information about the active window
func getActiveWindow() -> WindowInfo? {
  guard let frontApp = NSWorkspace.shared.frontmostApplication else {
    return nil
  }

  let pid = frontApp.processIdentifier
  let appName = frontApp.localizedName ?? "Unknown"

  let app = AXUIElementCreateApplication(pid)

  // Get focused window
  var windowRef: CFTypeRef?
  guard
    AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef)
      == .success,
    let window = windowRef
  else {
    // Return app info without window details
    return WindowInfo(pid: pid, app: appName, title: nil, x: 0, y: 0, w: 0, h: 0)
  }

  let windowElement = window as! AXUIElement

  // Get title
  var titleRef: CFTypeRef?
  let title: String?
  if AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef)
    == .success
  {
    title = titleRef as? String
  } else {
    title = nil
  }

  // Get position and size
  var positionRef: CFTypeRef?
  var sizeRef: CFTypeRef?
  var position = CGPoint.zero
  var size = CGSize.zero

  if AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionRef)
    == .success,
    let posVal = positionRef
  {
    AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
  }

  if AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef)
    == .success,
    let sizeVal = sizeRef
  {
    AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
  }

  return WindowInfo(
    pid: pid,
    app: appName,
    title: title,
    x: Int(position.x),
    y: Int(position.y),
    w: Int(size.width),
    h: Int(size.height)
  )
}
