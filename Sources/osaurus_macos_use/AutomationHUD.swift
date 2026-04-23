import AppKit
import Foundation

// MARK: - Automation HUD

/// A floating, mouse-transparent HUD that says "Automation in progress" and
/// reminds the user they can press Esc to stop. Designed for visibility (large,
/// high-contrast text) so non-technical and elderly users can follow what the
/// agent is doing in real time.
///
/// Lifecycle is owned by `AutomationSession`; it constructs and calls into
/// the HUD only from the main thread, so the whole class is `@MainActor`.
@MainActor
final class AutomationHUD {
  private static let panelWidth: CGFloat = 540
  private static let panelHeight: CGFloat = 96
  private static let bottomMargin: CGFloat = 240
  private static let cornerRadius: CGFloat = 14
  private static let fadeInDuration: TimeInterval = 0.20
  private static let fadeOutDuration: TimeInterval = 0.25

  private var panel: NSPanel?
  private var titleLabel: NSTextField?
  private var narrationLabel: NSTextField?
  private var stepLabel: NSTextField?
  private var hintLabel: NSTextField?

  init() {
    // Re-center the HUD when displays are added/removed/reconfigured.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      DispatchQueue.main.async {
        self?.repositionToCurrentScreen()
      }
    }
  }

  // MARK: Public API

  func setText(title: String, narration: String?, stepIndex: Int?, totalSteps: Int?) {
    ensureBuilt()
    titleLabel?.stringValue = title

    let narrationText = (narration?.isEmpty == false) ? narration! : "Working..."
    narrationLabel?.stringValue = narrationText

    stepLabel?.stringValue = formatStep(stepIndex: stepIndex, totalSteps: totalSteps)
    stepLabel?.isHidden = stepLabel?.stringValue.isEmpty ?? true

    hintLabel?.stringValue = "Press esc to stop"

    announceForAccessibility(narrationText)
  }

  func show() {
    ensureBuilt()
    guard let panel = panel else { return }
    repositionToCurrentScreen()

    if shouldReduceMotion || panel.isVisible {
      panel.alphaValue = 1.0
      panel.orderFrontRegardless()
      return
    }

    panel.alphaValue = 0.0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.fadeInDuration
      ctx.allowsImplicitAnimation = true
      panel.animator().alphaValue = 1.0
    }
  }

  func hide() {
    guard let panel = panel, panel.isVisible else { return }

    if shouldReduceMotion {
      panel.orderOut(nil)
      return
    }

    NSAnimationContext.runAnimationGroup(
      { ctx in
        ctx.duration = Self.fadeOutDuration
        ctx.allowsImplicitAnimation = true
        panel.animator().alphaValue = 0.0
      },
      completionHandler: {
        DispatchQueue.main.async {
          panel.orderOut(nil)
        }
      })
  }

  /// Briefly show "Cancelled" before fading. Used after an Esc cancel.
  func flashCancelled() {
    ensureBuilt()
    titleLabel?.stringValue = "Cancelled"
    narrationLabel?.stringValue = "Stopped by user"
    stepLabel?.isHidden = true
    hintLabel?.stringValue = ""
    announceForAccessibility("Automation cancelled")
  }

  // MARK: Internals

  private func formatStep(stepIndex: Int?, totalSteps: Int?) -> String {
    if let total = totalSteps {
      return "Step \(stepIndex ?? 0) of \(total)"
    }
    if let current = stepIndex {
      return "Step \(current)"
    }
    return ""
  }

  private func ensureBuilt() {
    if panel != nil { return }

    let rect = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
    let panel = NSPanel(
      contentRect: rect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
    ]

    let container = NSView(frame: rect)
    container.wantsLayer = true
    container.layer?.cornerRadius = Self.cornerRadius
    container.layer?.masksToBounds = true
    container.addSubview(makeBackground(rect: rect))

    self.titleLabel = addLabel(
      to: container, font: .systemFont(ofSize: 18, weight: .semibold),
      color: .white, text: "Automation in progress")
    self.narrationLabel = addLabel(
      to: container, font: .systemFont(ofSize: 14, weight: .regular),
      color: NSColor(white: 1.0, alpha: 0.92), text: "Working...")
    self.stepLabel = addLabel(
      to: container, font: .systemFont(ofSize: 12, weight: .medium),
      color: NSColor(white: 1.0, alpha: 0.75), text: "", hidden: true)
    self.hintLabel = addLabel(
      to: container, font: .systemFont(ofSize: 12, weight: .medium),
      color: NSColor(white: 1.0, alpha: 0.85), text: "Press esc to stop", alignment: .right)

    activateLayout(in: container)

    panel.contentView = container
    self.panel = panel
  }

  private func makeBackground(rect: NSRect) -> NSView {
    if shouldReduceTransparency {
      let bg = NSView(frame: rect)
      bg.wantsLayer = true
      bg.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.96).cgColor
      bg.layer?.cornerRadius = Self.cornerRadius
      bg.autoresizingMask = [.width, .height]
      return bg
    }
    let effect = NSVisualEffectView(frame: rect)
    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = Self.cornerRadius
    effect.autoresizingMask = [.width, .height]
    return effect
  }

  private func addLabel(
    to container: NSView,
    font: NSFont,
    color: NSColor,
    text: String,
    alignment: NSTextAlignment = .natural,
    hidden: Bool = false
  ) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color
    label.alignment = alignment
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.isHidden = hidden
    label.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    return label
  }

  private func activateLayout(in container: NSView) {
    guard let title = titleLabel, let narration = narrationLabel,
      let step = stepLabel, let hint = hintLabel
    else { return }

    NSLayoutConstraint.activate([
      title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
      title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -18),
      title.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),

      narration.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
      narration.trailingAnchor.constraint(
        lessThanOrEqualTo: container.trailingAnchor, constant: -18),
      narration.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),

      step.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
      step.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

      hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
      hint.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
      hint.leadingAnchor.constraint(greaterThanOrEqualTo: step.trailingAnchor, constant: 12),
    ])
  }

  private func repositionToCurrentScreen() {
    guard let panel = panel,
      let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
    else { return }
    let originX = frame.midX - Self.panelWidth / 2
    let originY = frame.minY + Self.bottomMargin
    panel.setFrame(
      NSRect(x: originX, y: originY, width: Self.panelWidth, height: Self.panelHeight),
      display: true)
  }

  // MARK: Accessibility helpers

  private var shouldReduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private var shouldReduceTransparency: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
  }

  private func announceForAccessibility(_ text: String) {
    guard !text.isEmpty else { return }
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: text,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
  }
}
