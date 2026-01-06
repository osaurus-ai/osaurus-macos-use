import AppKit
import CoreGraphics
import Foundation

// MARK: - Screenshot Result (MCP ImageContent format)

struct ScreenshotResult: Encodable {
  /// MCP content type - "image" for image content
  let type: String?
  /// Base64-encoded image data (MCP ImageContent format uses "data" field)
  let data: String?
  /// MIME type of the image (e.g., "image/jpeg", "image/png")
  let mimeType: String?
  /// Image width in pixels
  let width: Int?
  /// Image height in pixels
  let height: Int?
  /// File path when saved to disk instead of returning base64
  let path: String?
  /// Error message if capture failed
  let error: String?

  static func ok(width: Int, height: Int, data: String, mimeType: String) -> ScreenshotResult {
    return ScreenshotResult(
      type: "image",
      data: data,
      mimeType: mimeType,
      width: width,
      height: height,
      path: nil,
      error: nil
    )
  }

  static func okWithPath(width: Int, height: Int, path: String) -> ScreenshotResult {
    return ScreenshotResult(
      type: nil,
      data: nil,
      mimeType: nil,
      width: width,
      height: height,
      path: path,
      error: nil
    )
  }

  static func fail(_ message: String) -> ScreenshotResult {
    return ScreenshotResult(
      type: nil,
      data: nil,
      mimeType: nil,
      width: nil,
      height: nil,
      path: nil,
      error: message
    )
  }
}

// MARK: - Screenshot Options

struct ScreenshotOptions: Decodable {
  /// If specified, capture only this window's owner PID
  var pid: Int32?

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

    if let pid = options.pid {
      // Capture specific window (works across all displays)
      image = captureWindow(pid: pid)
    } else if options.allDisplays == true {
      // Capture all displays combined
      image = captureAllDisplays()
    } else if let displayIndex = options.displayIndex {
      // Capture specific display by index
      image = captureDisplay(at: displayIndex)
    } else {
      // Capture main display
      image = captureFullScreen()
    }

    guard let cgImage = image else {
      return .fail("Failed to capture screenshot")
    }

    // Apply scaling - default to 0.5 for reasonable size on Retina displays
    let finalImage: CGImage
    let scale = options.scale ?? 0.5
    if scale > 0 && scale < 1.0 {
      if let scaled = scaleImage(cgImage, scale: scale) {
        finalImage = scaled
      } else {
        finalImage = cgImage
      }
    } else {
      finalImage = cgImage
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
}
