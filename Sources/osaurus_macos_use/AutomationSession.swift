import Foundation

// MARK: - Automation Session
//
// Side-effect-free telemetry holder. v0.4 removed the on-screen HUD and the
// global Esc-cancel monitor: when the driver runs fully backgrounded the
// user neither sees nor needs to interrupt the agent's actions.
//
// The `start_/update_/end_automation_session` tools are still part of the
// surface area so existing agent prompts keep working; they just record a
// title/narration/step pair the agent can read back. Nothing in the input
// path consults this state any more.

final class AutomationSession: @unchecked Sendable {
  static let shared = AutomationSession()

  private let lock = NSLock()

  private var _isActive: Bool = false
  private var title: String = "Automation in progress"
  private var narration: String? = nil
  private var stepIndex: Int? = nil
  private var totalSteps: Int? = nil

  private init() {}

  // MARK: - State

  func isActive() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return _isActive
  }

  /// Snapshot used by the session tools to report current state. The
  /// `isCancelled` field is retained for response-shape stability with
  /// older clients but is now always `false`.
  func currentState() -> (
    title: String, narration: String?, stepIndex: Int?, totalSteps: Int?,
    isActive: Bool, isCancelled: Bool
  ) {
    lock.lock()
    defer { lock.unlock() }
    return (title, narration, stepIndex, totalSteps, _isActive, false)
  }

  // MARK: - Lifecycle

  func startSession(title: String, totalSteps: Int? = nil, narration: String? = nil) {
    lock.lock()
    _isActive = true
    self.title = title.isEmpty ? "Automation in progress" : title
    self.narration = narration
    self.stepIndex = nil
    self.totalSteps = totalSteps
    lock.unlock()
  }

  func updateSession(
    title: String? = nil, narration: String? = nil,
    stepIndex: Int? = nil, totalSteps: Int? = nil
  ) {
    lock.lock()
    if let title = title { self.title = title }
    if let narration = narration { self.narration = narration }
    if let stepIndex = stepIndex { self.stepIndex = stepIndex }
    if let totalSteps = totalSteps { self.totalSteps = totalSteps }
    lock.unlock()
  }

  func endSession(reason: String? = nil) {
    lock.lock()
    _isActive = false
    narration = nil
    stepIndex = nil
    totalSteps = nil
    title = "Automation in progress"
    lock.unlock()
    _ = reason
  }
}
