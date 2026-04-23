import AppKit
import Foundation

// MARK: - Automation Session

/// Tracks the lifecycle of a user-visible automation session.
///
/// Three responsibilities:
/// 1. Show/update/hide the floating HUD ("Automation in progress").
/// 2. Listen for global Esc presses and expose `isCancelled()` to action tools
///    so they can bail with a clear `cancelled: true` result.
/// 3. Auto-show on the first action call and auto-hide after a short idle
///    window so agents that don't know about session tools still get the HUD.
final class AutomationSession: @unchecked Sendable {
  static let shared = AutomationSession()

  private let lock = NSLock()

  // Lifecycle / cancellation flags
  private var _isActive: Bool = false
  private var _isCancelled: Bool = false
  private var sessionStartedAt: Date = .distantPast
  private var lastActiveAt: Date = .distantPast

  // Display state
  private var title: String = "Automation in progress"
  private var narration: String? = nil
  private var stepIndex: Int? = nil
  private var totalSteps: Int? = nil
  private var hudVisible: Bool = false

  // Idle auto-hide
  private static let idleTimeoutSeconds: TimeInterval = 3.0
  private var idleTimer: DispatchSourceTimer? = nil

  // Owned subsystems. The HUD is `@MainActor`-isolated so it has to be
  // constructed on the main thread. We initialize it lazily inside `showHud`,
  // which always runs in a `DispatchQueue.main.async` block.
  private var hud: AutomationHUD?
  private lazy var escMonitor: EscCancelMonitor = EscCancelMonitor { [weak self] in
    self?.cancel(reason: "User pressed Esc")
  }

  private init() {}

  // MARK: Read-only state used by the Esc tap

  /// Whether a session is currently active. Reads are lock-protected and fast.
  func isActive() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return _isActive
  }

  /// Whether Esc should be consumed right now. Used by the Esc tap to avoid
  /// stealing Esc from legitimate modals that came up at the same time.
  func shouldConsumeEsc() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard _isActive, hudVisible else { return false }
    return Date().timeIntervalSince(sessionStartedAt) >= 0.5
  }

  /// True if the session has been cancelled and the action should bail.
  func isCancelled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return _isCancelled
  }

  /// Snapshot of the displayed state for tests and tool responses.
  func currentState() -> (
    title: String, narration: String?, stepIndex: Int?, totalSteps: Int?,
    isActive: Bool, isCancelled: Bool
  ) {
    lock.lock()
    defer { lock.unlock() }
    return (title, narration, stepIndex, totalSteps, _isActive, _isCancelled)
  }

  // MARK: Public lifecycle

  /// Called at the top of every action tool. Resets idle timer, ensures the
  /// HUD is visible, and updates the subtitle if narration is provided.
  func markActive(narration: String? = nil) {
    var shouldShow = false
    var newNarration: String? = nil
    var snapshot: HudSnapshot? = nil

    lock.lock()
    if !_isActive {
      _isActive = true
      sessionStartedAt = Date()
      shouldShow = true
    }
    lastActiveAt = Date()
    if let n = narration, !n.isEmpty {
      self.narration = n
      newNarration = n
    }
    snapshot = currentSnapshotLocked()
    lock.unlock()

    if shouldShow {
      escMonitor.start()
      startIdleTimer()
    }
    if shouldShow || newNarration != nil {
      showHud(snapshot: snapshot)
    }
  }

  /// Explicit session start. Supersedes any in-flight session.
  func startSession(title: String, totalSteps: Int? = nil, narration: String? = nil) {
    var snapshot: HudSnapshot? = nil

    lock.lock()
    // Single-session guard: end any prior session cleanly first.
    if _isActive {
      _isCancelled = false
    }
    _isActive = true
    _isCancelled = false
    sessionStartedAt = Date()
    lastActiveAt = Date()
    self.title = title.isEmpty ? "Automation in progress" : title
    self.narration = narration
    self.stepIndex = nil
    self.totalSteps = totalSteps
    snapshot = currentSnapshotLocked()
    lock.unlock()

    escMonitor.start()
    startIdleTimer()
    showHud(snapshot: snapshot)
  }

  /// Update one or more display fields without performing an action.
  func updateSession(
    title: String? = nil, narration: String? = nil,
    stepIndex: Int? = nil, totalSteps: Int? = nil
  ) {
    var snapshot: HudSnapshot? = nil

    lock.lock()
    if let title = title { self.title = title }
    if let narration = narration { self.narration = narration }
    if let stepIndex = stepIndex { self.stepIndex = stepIndex }
    if let totalSteps = totalSteps { self.totalSteps = totalSteps }
    if _isActive {
      lastActiveAt = Date()
    }
    snapshot = currentSnapshotLocked()
    lock.unlock()

    showHud(snapshot: snapshot)
  }

  /// Explicit teardown. Hides HUD, stops Esc tap, resets cancellation flag.
  func endSession(reason: String? = nil) {
    var wasActive = false
    lock.lock()
    wasActive = _isActive
    _isActive = false
    _isCancelled = false
    hudVisible = false
    narration = nil
    stepIndex = nil
    totalSteps = nil
    title = "Automation in progress"
    lock.unlock()

    if wasActive {
      stopIdleTimer()
      escMonitor.stop()
      DispatchQueue.main.async { [weak self] in
        self?.hud?.hide()
      }
    }
    _ = reason  // reserved for future logging
  }

  /// Triggered by the Esc tap. Sets the cancel flag and flashes the HUD.
  func cancel(reason: String) {
    lock.lock()
    guard _isActive, !_isCancelled else {
      lock.unlock()
      return
    }
    _isCancelled = true
    lock.unlock()

    DispatchQueue.main.async { [weak self] in
      self?.hud?.flashCancelled()
    }
    // Schedule auto-end so the HUD fades away after the cancel flash.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      self?.endSession(reason: reason)
    }
  }

  // MARK: Idle auto-hide

  private func startIdleTimer() {
    stopIdleTimer()
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
    timer.setEventHandler { [weak self] in
      self?.checkIdle()
    }
    timer.resume()
    idleTimer = timer
  }

  private func stopIdleTimer() {
    idleTimer?.cancel()
    idleTimer = nil
  }

  private func checkIdle() {
    lock.lock()
    let active = _isActive
    let elapsed = Date().timeIntervalSince(lastActiveAt)
    lock.unlock()

    if active && elapsed > Self.idleTimeoutSeconds {
      endSession(reason: "idle")
    }
  }

  // MARK: HUD plumbing

  private struct HudSnapshot {
    let title: String
    let narration: String?
    let stepIndex: Int?
    let totalSteps: Int?
  }

  /// Caller must hold `lock`.
  private func currentSnapshotLocked() -> HudSnapshot {
    return HudSnapshot(
      title: title, narration: narration, stepIndex: stepIndex, totalSteps: totalSteps)
  }

  private func showHud(snapshot: HudSnapshot?) {
    guard let snap = snapshot else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // Lazy-construct on the main thread (HUD is @MainActor).
      let hud = self.hud ?? AutomationHUD()
      self.hud = hud
      hud.setText(
        title: snap.title,
        narration: snap.narration,
        stepIndex: snap.stepIndex,
        totalSteps: snap.totalSteps
      )
      hud.show()
      self.lock.lock()
      self.hudVisible = true
      self.lock.unlock()
    }
  }
}
