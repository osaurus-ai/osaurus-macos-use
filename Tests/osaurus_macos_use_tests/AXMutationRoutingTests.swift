import Foundation
import Testing

@testable import osaurus_macos_use

@Suite("Self-target AX mutation routing")
struct AXMutationRoutingTests {
  @Test("A worker targeting the host enters the main thread and returns its result")
  func hostFromWorker() async {
    let result = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        let callerWasMain = Thread.isMainThread
        let operationWasMain = performAXMutation(
          targetPID: ProcessInfo.processInfo.processIdentifier
        ) { Thread.isMainThread }
        continuation.resume(returning: (callerWasMain, operationWasMain))
      }
    }
    #expect(!result.0)
    #expect(result.1)
  }

  @Test("Host mutations already on main execute inline without deadlocking")
  @MainActor
  func hostFromMain() {
    let value = performAXMutation(targetPID: ProcessInfo.processInfo.processIdentifier) {
      Thread.isMainThread ? 42 : -1
    }
    #expect(value == 42)
  }

  @Test("Other applications stay on the worker so AX IPC does not block the UI")
  func externalFromWorker() async {
    let stayedOnWorker = await Task.detached {
      performAXMutation(targetPID: -1) { !Thread.isMainThread }
    }.value
    #expect(stayedOnWorker)
  }
}
