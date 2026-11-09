# Self-target text mutation crash

APPLE-MACOS-3MR records `type_text` on the host accessibility worker, followed
by `AXUIElementSetAttributeValue`, AppKit's text-value setter, and the host
editor's main-actor `undoManager(for:)` delegate. `type_text` clears the cached
element before posting text; that clear is an AX value mutation. For an
in-process target, AX can enter AppKit synchronously on the caller's thread.

Route host-target focus/value mutations and actions onto the main thread.
Already-main callers execute inline; other applications' AX IPC remains on
the worker. No change to the host undo delegate, input events, or permissions.

Validation against base `34add4c83f5459e41588e206f155db94c570c0ac`:

- Full plugin suite: 103/103 tests in 16 suites, including the C ABI tool
  contracts and three host/external/main-thread routing cases.
- A native AppKit fixture using the exact current Osaurus undo delegate and
  AppKit text-value setter reproduces SIGTRAP without routing. The crash
  stack matches the reported setter/undo/executor chain. With the production
  routing helper, the edit, scoped undo, and redo complete successfully.
- Release dynamic-library build and focused formatting checks pass.

Evidence is retained privately at
`/Users/eric/vmlx-private-evidence/sentry-inference-20261108/undo-actor/`,
including the old crash report, both native fixtures, complete test output,
and failed setup attempts. The first test command used a Command Line Tools
SDK without Testing; the next exposed a new test's async thread-check compile
error. Both are retained alongside the successful Xcode rerun.

This establishes the synchronous self-target actor violation and its routing
correction. It does not establish release adoption or a full Osaurus Chat
automation pass. No plugin was installed into the user's profile or released.
