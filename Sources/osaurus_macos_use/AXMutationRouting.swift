import Foundation

/// AX mutations targeting the plugin host can enter AppKit directly on the
/// calling thread. For example, clearing the host's NSTextView invokes its
/// main-actor undo delegate synchronously (Sentry APPLE-MACOS-3MR).
/// Keep other applications' AX IPC on the caller's worker queue.
func performAXMutation<T>(targetPID: Int32, _ operation: @Sendable () -> T) -> T {
  if targetPID == ProcessInfo.processInfo.processIdentifier && !Thread.isMainThread {
    return DispatchQueue.main.sync(execute: operation)
  }
  return operation()
}
