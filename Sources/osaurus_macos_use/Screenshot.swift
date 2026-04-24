import AppKit
import CoreGraphics
import Foundation

// MARK: - MCP ImageContent (used within content array)

struct MCPImageContent: Codable, Sendable {
  let type: String  // "image"
  let data: String  // base64-encoded image data
  let mimeType: String  // e.g., "image/jpeg", "image/png"
}

// MARK: - MCP TextContent (used for errors and file paths)

struct MCPTextContent: Encodable {
  let type: String  // "text"
  let text: String
}

// MARK: - Screenshot Result (MCP CallToolResult format with content array)

struct ScreenshotResult: Encodable {
  /// MCP content array - contains ImageContent or TextContent items
  let content: [AnyCodable]

  /// Creates a successful image result in MCP format
  static func ok(width: Int, height: Int, data: String, mimeType: String) -> ScreenshotResult {
    let imageContent = MCPImageContent(type: "image", data: data, mimeType: mimeType)
    return ScreenshotResult(content: [AnyCodable(imageContent)])
  }

  /// Creates a successful file path result
  static func okWithPath(width: Int, height: Int, path: String) -> ScreenshotResult {
    let textContent = MCPTextContent(
      type: "text", text: "Screenshot saved to: \(path) (\(width)x\(height))")
    return ScreenshotResult(content: [AnyCodable(textContent)])
  }

  /// Creates an error result
  static func fail(_ message: String) -> ScreenshotResult {
    let textContent = MCPTextContent(type: "text", text: "Error: \(message)")
    return ScreenshotResult(content: [AnyCodable(textContent)])
  }
}

// MARK: - AnyCodable wrapper for heterogeneous content array

struct AnyCodable: Encodable {
  private let _encode: (Encoder) throws -> Void

  init<T: Encodable>(_ value: T) {
    _encode = { encoder in
      try value.encode(to: encoder)
    }
  }

  func encode(to encoder: Encoder) throws {
    try _encode(encoder)
  }
}

// MARK: - Screenshot Options

struct ScreenshotOptions: Decodable {
  /// Capture only this app's window. Without `windowId`, the largest
  /// on-screen window for that pid is chosen. Works for occluded and
  /// off-screen-Space windows too — `CGWindowListCreateImage` doesn't
  /// require the window to be visible.
  var pid: Int32?

  /// Capture this exact `CGWindowID` (returned by `list_windows`). Beats
  /// the pid heuristic when an app has multiple windows and the agent
  /// already knows which one it wants.
  var windowId: CGWindowID?

  /// Display index to capture (0 = main display, 1, 2, etc.)
  var displayIndex: Int?

  /// Capture all displays as one combined image
  var allDisplays: Bool?

  /// Image format: "png" or "jpeg"
  var format: String?

  /// JPEG quality (0.0 - 1.0), only used for JPEG format
  var quality: Double?

  /// Scale factor (0.0 - 1.0) to reduce image size
  var scale: Double?

  /// If specified, save screenshot to this file path instead of returning base64
  var savePath: String?

  /// If true, overlay element IDs from the most recent snapshot (matched by pid).
  /// Useful for vision-augmented agents to reference IDs straight from the image.
  /// Requires `pid` to be set, and that get_ui_elements has been called for that pid.
  var annotate: Bool?
}

// MARK: - Display Info

struct DisplayInfo: Encodable {
  let index: Int
  let displayId: UInt32
  let x: Int
  let y: Int
  let width: Int
  let height: Int
  let isMain: Bool
}

struct DisplayListResult: Encodable {
  let displays: [DisplayInfo]
}

// MARK: - Screenshot Controller

final class ScreenshotController: @unchecked Sendable {
  static let shared = ScreenshotController()

  private init() {}

  /// Get list of all connected displays
  func listDisplays() -> DisplayListResult {
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &displayCount)

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    CGGetActiveDisplayList(displayCount, &displays, &displayCount)

    let mainDisplayID = CGMainDisplayID()

    let displayInfos = displays.enumerated().map { index, displayId -> DisplayInfo in
      let bounds = CGDisplayBounds(displayId)
      return DisplayInfo(
        index: index,
        displayId: displayId,
        x: Int(bounds.origin.x),
        y: Int(bounds.origin.y),
        width: Int(bounds.width),
        height: Int(bounds.height),
        isMain: displayId == mainDisplayID
      )
    }

    return DisplayListResult(displays: displayInfos)
  }

  /// Capture a screenshot of the entire screen or a specific window
  func capture(options: ScreenshotOptions = ScreenshotOptions()) -> ScreenshotResult {
    let image: CGImage?

    if let windowId = options.windowId {
      // Direct window-id capture is the cleanest backgrounded path: it works
      // even if the window is hidden, occluded, or on a different Space.
      image = captureWindow(windowId: windowId)
    } else if let pid = options.pid {
      image = captureWindow(pid: pid)
    } else if options.allDisplays == true {
      image = captureAllDisplays()
    } else if let displayIndex = options.displayIndex {
      image = captureDisplay(at: displayIndex)
    } else {
      image = captureFullScreen()
    }

    guard let cgImage = image else {
      return .fail("Failed to capture screenshot")
    }

    // Optionally annotate with element IDs before scaling so labels stay legible.
    let annotatedImage: CGImage = {
      if options.annotate == true {
        // When the caller passed a windowId, use that to compute the
        // capture origin; otherwise fall back to the per-pid heuristic.
        let pidForElements: Int32? =
          options.pid
          ?? options.windowId.flatMap { ownerPid(for: $0) }
        guard let pid = pidForElements else { return cgImage }
        let elements = AccessibilityManager.shared.mostRecentElements(for: pid)
        let captureOrigin: CGPoint? =
          options.windowId.flatMap { captureBoundsForWindowId($0)?.origin }
          ?? captureBoundsForPid(pid)?.origin
        if let origin = captureOrigin,
          let overlaid = overlayElementIds(
            on: cgImage, elements: elements, captureOrigin: origin)
        {
          return overlaid
        }
      }
      return cgImage
    }()

    // Apply scaling - default to 0.5 for reasonable size on Retina displays
    let finalImage: CGImage
    let scale = options.scale ?? 0.5
    if scale > 0 && scale < 1.0 {
      if let scaled = scaleImage(annotatedImage, scale: scale) {
        finalImage = scaled
      } else {
        finalImage = annotatedImage
      }
    } else {
      finalImage = annotatedImage
    }

    // Convert to data - default to JPEG for much smaller file size
    let format = options.format?.lowercased() ?? "jpeg"
    let quality = options.quality ?? 0.7

    guard let data = imageToData(finalImage, format: format, quality: quality) else {
      return .fail("Failed to encode image")
    }

    // Save to file if path is specified
    if let savePath = options.savePath {
      let url = URL(fileURLWithPath: savePath)
      do {
        try data.write(to: url)
        return .okWithPath(
          width: finalImage.width,
          height: finalImage.height,
          path: savePath
        )
      } catch {
        return .fail("Failed to save screenshot: \(error.localizedDescription)")
      }
    }

    // Otherwise return base64 in MCP ImageContent format
    let base64 = data.base64EncodedString()
    let mimeType = format == "png" ? "image/png" : "image/jpeg"

    return .ok(
      width: finalImage.width,
      height: finalImage.height,
      data: base64,
      mimeType: mimeType
    )
  }

  private func captureFullScreen() -> CGImage? {
    // Get the main display
    let displayID = CGMainDisplayID()
    return CGDisplayCreateImage(displayID)
  }

  private func captureDisplay(at index: Int) -> CGImage? {
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &displayCount)

    guard index < displayCount else {
      return nil
    }

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    CGGetActiveDisplayList(displayCount, &displays, &displayCount)

    return CGDisplayCreateImage(displays[index])
  }

  private func captureAllDisplays() -> CGImage? {
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &displayCount)

    guard displayCount > 0 else {
      return nil
    }

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    CGGetActiveDisplayList(displayCount, &displays, &displayCount)

    // Calculate the bounding box of all displays
    var minX = CGFloat.infinity
    var minY = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var maxY = -CGFloat.infinity

    for displayId in displays {
      let bounds = CGDisplayBounds(displayId)
      minX = min(minX, bounds.origin.x)
      minY = min(minY, bounds.origin.y)
      maxX = max(maxX, bounds.origin.x + bounds.width)
      maxY = max(maxY, bounds.origin.y + bounds.height)
    }

    let totalWidth = Int(maxX - minX)
    let totalHeight = Int(maxY - minY)

    // Create a combined image
    guard
      let context = CGContext(
        data: nil,
        width: totalWidth,
        height: totalHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return nil
    }

    // Fill with black background (for gaps between displays)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

    // Draw each display
    for displayId in displays {
      guard let displayImage = CGDisplayCreateImage(displayId) else {
        continue
      }

      let bounds = CGDisplayBounds(displayId)

      // Calculate position in the combined image
      // Note: CGContext has origin at bottom-left, but display coordinates have origin at top-left
      let x = bounds.origin.x - minX
      let y = CGFloat(totalHeight) - (bounds.origin.y - minY) - bounds.height

      context.draw(
        displayImage,
        in: CGRect(x: x, y: y, width: bounds.width, height: bounds.height)
      )
    }

    return context.makeImage()
  }

  private func captureWindow(pid: Int32) -> CGImage? {
    // Get window list
    let windowList =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[CFString: Any]]

    guard let windows = windowList else {
      return nil
    }

    // Find windows belonging to the specified PID
    var targetWindowID: CGWindowID?

    for window in windows {
      if let windowPID = window[kCGWindowOwnerPID] as? Int32,
        windowPID == pid,
        let windowID = window[kCGWindowNumber] as? CGWindowID
      {
        // Prefer non-minimized windows with reasonable size
        if let bounds = window[kCGWindowBounds] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double,
          width > 100 && height > 100
        {
          targetWindowID = windowID
          break
        }
      }
    }

    guard let windowID = targetWindowID else {
      // Fall back to screen capture
      return captureFullScreen()
    }

    // Capture the window
    return CGWindowListCreateImage(
      .null,
      .optionIncludingWindow,
      windowID,
      [.boundsIgnoreFraming, .bestResolution]
    )
  }

  /// Capture exactly one CGWindow by id. Skips the heuristic that tries to
  /// pick "the right" window for a pid; the caller already decided.
  private func captureWindow(windowId: CGWindowID) -> CGImage? {
    return CGWindowListCreateImage(
      .null,
      .optionIncludingWindow,
      windowId,
      [.boundsIgnoreFraming, .bestResolution]
    )
  }

  /// Owner pid for a CGWindowID. Used to look up the element cache when
  /// the caller annotates a windowId-only screenshot.
  fileprivate func ownerPid(for windowId: CGWindowID) -> Int32? {
    let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowId) as? [[CFString: Any]]
    return info?.first?[kCGWindowOwnerPID] as? Int32
  }

  /// Bounds of a specific window in screen coordinates. Mirrors
  /// `captureBoundsForPid` for the windowId-driven path.
  fileprivate func captureBoundsForWindowId(_ windowId: CGWindowID) -> CGRect? {
    let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowId) as? [[CFString: Any]]
    guard let entry = info?.first,
      let bounds = entry[kCGWindowBounds] as? [String: Any],
      let x = bounds["X"] as? Double,
      let y = bounds["Y"] as? Double,
      let w = bounds["Width"] as? Double,
      let h = bounds["Height"] as? Double
    else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
  }

  private func scaleImage(_ image: CGImage, scale: Double) -> CGImage? {
    let newWidth = Int(Double(image.width) * scale)
    let newHeight = Int(Double(image.height) * scale)

    guard newWidth > 0, newHeight > 0 else {
      return nil
    }

    guard
      let context = CGContext(
        data: nil,
        width: newWidth,
        height: newHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return nil
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

    return context.makeImage()
  }

  private func imageToData(_ image: CGImage, format: String, quality: Double) -> Data? {
    let bitmapRep = NSBitmapImageRep(cgImage: image)

    switch format {
    case "jpeg", "jpg":
      return bitmapRep.representation(
        using: .jpeg,
        properties: [.compressionFactor: quality]
      )
    default:
      return bitmapRep.representation(using: .png, properties: [:])
    }
  }

  /// Compute the screen-space bounds of the captured region so we can map
  /// AX (global) coordinates to image-local coordinates.
  /// Returns nil if we can't determine bounds; callers should skip annotation.
  fileprivate func captureBoundsForPid(_ pid: Int32) -> CGRect? {
    let windowList =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[CFString: Any]]
    guard let windows = windowList else { return nil }

    for window in windows {
      if let windowPID = window[kCGWindowOwnerPID] as? Int32, windowPID == pid,
        let bounds = window[kCGWindowBounds] as? [String: Any],
        let x = bounds["X"] as? Double,
        let y = bounds["Y"] as? Double,
        let w = bounds["Width"] as? Double,
        let h = bounds["Height"] as? Double,
        w > 100, h > 100
      {
        return CGRect(x: x, y: y, width: w, height: h)
      }
    }
    return nil
  }
}

// MARK: - Annotation Overlay

/// Draws element-ID labels on top of `image` so vision-capable agents can
/// reference IDs visually. `captureOrigin` is the screen-space origin of the
/// capture so we can subtract it from each element's global AX coordinates.
private func overlayElementIds(
  on image: CGImage,
  elements: [(id: String, frame: CGRect)],
  captureOrigin: CGPoint
) -> CGImage? {
  let width = image.width
  let height = image.height
  guard width > 0, height > 0, !elements.isEmpty else { return image }

  guard
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else { return nil }

  // Draw original image
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

  // Set up colors: red boxes, white text on red
  let boxStroke = CGColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 0.95)
  let labelFill = CGColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 0.85)
  context.setStrokeColor(boxStroke)
  context.setLineWidth(1.5)

  let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = nsContext

  let font = NSFont.boldSystemFont(ofSize: 11)
  let textAttrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
  ]

  for element in elements {
    let f = element.frame
    // Convert global top-left coords to image-local coords.
    // CGContext is bottom-left origin; flip y.
    let localX = f.origin.x - captureOrigin.x
    let localTopY = f.origin.y - captureOrigin.y
    let bottomY = CGFloat(height) - localTopY - f.size.height
    let rect = CGRect(x: localX, y: bottomY, width: f.size.width, height: f.size.height)
    if rect.maxX <= 0 || rect.maxY <= 0 || rect.minX >= CGFloat(width)
      || rect.minY >= CGFloat(height)
    {
      continue
    }

    context.stroke(rect)

    // Draw a small label in the top-left of the element with the id
    let labelText = element.id
    let attributed = NSAttributedString(string: labelText, attributes: textAttrs)
    let textSize = attributed.size()
    let pad: CGFloat = 2
    let labelRect = CGRect(
      x: rect.minX,
      y: rect.maxY - textSize.height - pad * 2,
      width: textSize.width + pad * 2,
      height: textSize.height + pad * 2
    )
    context.setFillColor(labelFill)
    context.fill(labelRect)
    attributed.draw(at: CGPoint(x: labelRect.minX + pad, y: labelRect.minY + pad))
  }

  NSGraphicsContext.restoreGraphicsState()
  return context.makeImage()
}
