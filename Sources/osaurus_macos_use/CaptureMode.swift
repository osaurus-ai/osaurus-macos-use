import CoreGraphics
import Foundation

// MARK: - Capture Mode
//
// cua's three modalities, ported to our tool surface:
//
//   .ax     — accessibility tree only, no pixels. No Screen Recording
//             permission needed. Fastest. Best for AppKit/SwiftUI apps
//             with rich AX trees.
//   .vision — screenshot only, no AX tree. Smallest payload for
//             vision-first VLMs that ground on pixels.
//   .som    — set-of-mark: AX tree + screenshot, with element_index
//             numbers drawn on every actionable element. Default: lets
//             pixel-grounded models reason visually while still using
//             stable element ids for clicks.

enum CaptureMode: String, Codable, Sendable {
  case ax
  case vision
  case som

  static let `default`: CaptureMode = .som

  static func parse(_ raw: String?) -> CaptureMode {
    guard let raw = raw?.lowercased() else { return .default }
    return CaptureMode(rawValue: raw) ?? .default
  }
}

// MARK: - SOM Result
//
// Encoded as a top-level object so MCP clients can pull either the tree or
// the screenshot without re-parsing. `elementIndex` is the cua-style
// addressing layer: a stable integer per element in display order, useful
// for vision-first agents that don't want to parse `s7-42` ids.

/// One actionable element annotated with both its snapshot id and its
/// SOM-mode index. The agent can use either to address the element in
/// follow-up clicks.
struct SOMElementRef: Encodable, Sendable {
  let elementIndex: Int
  let id: String
  let role: String
  let label: String?
  let x: Int
  let y: Int
  let w: Int
  let h: Int
}

struct SOMResult: Encodable, Sendable {
  let mode: String
  let snapshot: TraversalResult
  let image: MCPImageContent?
  let windowId: Int?
  let elements: [SOMElementRef]
  let routeUsed: InputRoute?
}

// MARK: - Builder

/// Build a capture envelope for a given pid, switching on `mode`.
///
/// `windowId` is forwarded to the screenshot path; if absent we fall back
/// to the largest on-screen window for the pid (existing behavior).
func buildCapture(
  pid: Int32,
  mode: CaptureMode,
  windowId: Int? = nil,
  maxElements: Int? = nil,
  focusedWindowOnly: Bool = false
) -> SOMResult {
  var filter = ElementFilter(pid: pid)
  if let maxElements = maxElements { filter.maxElements = maxElements }
  if focusedWindowOnly { filter.focusedWindowOnly = true }
  let snapshot = AccessibilityManager.shared.traverse(filter: filter)

  let elementRefs: [SOMElementRef] = snapshot.elements.enumerated().map { idx, info in
    SOMElementRef(
      elementIndex: idx + 1,
      id: info.id,
      role: info.role,
      label: info.label,
      x: info.x, y: info.y, w: info.w, h: info.h
    )
  }

  let imageContent: MCPImageContent? = {
    guard mode == .som || mode == .vision else { return nil }
    var opts = ScreenshotOptions()
    opts.pid = pid
    if let wid = windowId { opts.windowId = CGWindowID(wid) }
    // SOM annotation reuses the existing element-id overlay; the agent
    // gets both the numeric index in `elements[]` and the visual id label
    // burned onto the image.
    opts.annotate = (mode == .som)
    let result = ScreenshotController.shared.capture(options: opts)
    // Pull the embedded ImageContent out of the MCP envelope.
    for item in result.content {
      if let mirror = mirrorImage(item) { return mirror }
    }
    return nil
  }()

  return SOMResult(
    mode: mode.rawValue,
    snapshot: snapshot,
    image: imageContent,
    windowId: windowId,
    elements: elementRefs,
    routeUsed: nil
  )
}

/// `ScreenshotResult.content` is a heterogeneous array (`AnyCodable`) so
/// we can't down-cast directly. Re-encode the item and try to decode it
/// as an image — silently drops text-content entries that we don't want
/// in the SOM payload.
private func mirrorImage(_ item: AnyCodable) -> MCPImageContent? {
  let encoder = JSONEncoder()
  guard let data = try? encoder.encode(item) else { return nil }
  return try? JSONDecoder().decode(MCPImageContent.self, from: data)
}
