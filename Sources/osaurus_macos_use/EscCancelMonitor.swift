import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Esc Cancel Monitor

/// System-wide Escape-key listener that fires `onCancel` when:
/// 1. A session is active (`AutomationSession.shared.shouldConsumeEsc()` is true)
/// 2. The Escape key was pressed without modifiers
///
/// Uses a `CGEventTap` on a dedicated thread so cancellation works even when
/// the main thread is busy synthesizing input events. Consumes the Esc event
/// to prevent it from also reaching the focused app, but only when active.
///
/// Degrades gracefully:
/// - If tap creation fails (no Accessibility permission, sandboxing), the
///   monitor logs to stderr and becomes a no-op.
/// - If the system disables the tap (timeout / user input), the callback
///   re-enables it on the next event.
final class EscCancelMonitor: @unchecked Sendable {
  private let onCancel: () -> Void
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var thread: Thread?
  private var threadRunLoop: CFRunLoop?
  private let lock = NSLock()
  private var started: Bool = false

  init(onCancel: @escaping () -> Void) {
    self.onCancel = onCancel
  }

  deinit {
    stop()
  }

  /// Idempotent: starting an already-started monitor is a no-op.
  func start() {
    lock.lock()
    if started {
      lock.unlock()
      return
    }
    started = true
    lock.unlock()

    let thread = Thread { [weak self] in
      guard let self = self else { return }
      self.runTapLoop()
    }
    thread.name = "osaurus-macos-use.esc-cancel-monitor"
    thread.qualityOfService = .userInitiated
    self.thread = thread
    thread.start()
  }

  func stop() {
    lock.lock()
    let runLoop = threadRunLoop
    let tap = eventTap
    threadRunLoop = nil
    started = false
    lock.unlock()

    if let tap = tap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    if let runLoop = runLoop {
      CFRunLoopStop(runLoop)
    }
    // Thread will exit on its own once the runloop stops.
  }

  // MARK: Internals

  private func runTapLoop() {
    let mask: CGEventMask =
      (1 << CGEventType.keyDown.rawValue)
      | (1 << CGEventType.tapDisabledByTimeout.rawValue)
      | (1 << CGEventType.tapDisabledByUserInput.rawValue)

    let userInfo = Unmanaged.passUnretained(self).toOpaque()

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: escTapCallback,
        userInfo: userInfo
      )
    else {
      FileHandle.standardError.write(
        Data(
          "[osaurus-macos-use] Esc-cancel tap could not be created. Esc-to-cancel will not work. Grant Accessibility permission to the host app and try again.\n"
            .utf8))
      lock.lock()
      started = false
      lock.unlock()
      return
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

    lock.lock()
    self.eventTap = tap
    self.runLoopSource = source
    self.threadRunLoop = CFRunLoopGetCurrent()
    lock.unlock()

    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    CFRunLoopRun()

    // Cleanup on exit
    if let source = source {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
    }
    CGEvent.tapEnable(tap: tap, enable: false)

    lock.lock()
    self.eventTap = nil
    self.runLoopSource = nil
    self.threadRunLoop = nil
    lock.unlock()
  }

  fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    // Re-enable the tap if the system shut it off.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      lock.lock()
      let tap = eventTap
      lock.unlock()
      if let tap = tap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }

    if type != .keyDown {
      return Unmanaged.passUnretained(event)
    }

    // Only react to bare Escape (no command/control/option).
    let escKeyCode: Int64 = 0x35
    if event.getIntegerValueField(.keyboardEventKeycode) != escKeyCode {
      return Unmanaged.passUnretained(event)
    }
    let blockingMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
    if event.flags.intersection(blockingMods).rawValue != 0 {
      return Unmanaged.passUnretained(event)
    }

    // Only consume + cancel when the session actively wants Esc captured.
    // Defer the actual work off the tap thread so the callback stays cheap.
    if AutomationSession.shared.shouldConsumeEsc() {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.onCancel()
      }
      return nil
    }
    return Unmanaged.passUnretained(event)
  }
}

// MARK: - C-style Tap Callback

private func escTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo = userInfo else {
    return Unmanaged.passUnretained(event)
  }
  let monitor = Unmanaged<EscCancelMonitor>.fromOpaque(userInfo).takeUnretainedValue()
  return monitor.handle(type: type, event: event)
}
