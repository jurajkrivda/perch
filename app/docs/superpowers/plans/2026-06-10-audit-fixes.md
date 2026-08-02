# Perch Audit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the 5 priority findings from the technical audit: shared SlotEngine + atomic store updates (data-loss race), corrupt-store recovery, display-bounds clamping on restore, O(n²) AX capture, and dead-code/normalization cleanup.

**Architecture:** All read-modify-write store operations move inside the `SlotStore` actor (`update`), a single memoized `SlotEngine.shared()` replaces the per-window engine instances, restore geometry becomes a pure testable static (`SlotEngine.targetFrame(for:displays:)`) that clamps to display bounds, and `WindowSnapshotter` caches AX window metadata per PID. Dead API in `WindowMover`/`DisplayManager`/`ToastWindow` is deleted and title normalization is consolidated to `WindowMover.normalizedTitle`.

**Tech Stack:** Swift 6 (strict concurrency `complete`), XCTest, XcodeGen, macOS 14 target.

---

## Conventions used by every task

- Test command (fast, single class):
  `xcodebuild test -project Perch.xcodeproj -scheme PerchModelTests -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:PerchTests/<ClassName> 2>&1 | tail -20`
- Full test suite:
  `xcodebuild test -project Perch.xcodeproj -scheme PerchModelTests -destination 'platform=macOS' -derivedDataPath build/DerivedData 2>&1 | tail -20`
- App build check:
  `xcodebuild -project Perch.xcodeproj -scheme Perch -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -5`
- After ADDING or DELETING any file: run `xcodegen generate` first, then build/test (project.pbxproj is generated from project.yml; both targets pick up files from there).
- Tests live in `PerchTests/`. `PerchTests/SlotStoreTests.swift` already has helpers `makeTemporaryStoreURL() -> (URL, URL)` (returns `(directoryURL, fileURL)`) and `posixPermissions(of:)` — reuse them for store tests.
- Commit messages end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 0: Baseline — commit pre-existing WIP

The working tree contains the user's uncommitted work (accessibility tests, release docs, Info.plist termination keys, hardening changes). Commit it as-is, separately, so audit fixes are isolated and reviewable.

**Files:** all currently modified/untracked files (no source edits in this task).

- [ ] **Step 1: Verify baseline tests pass on the current working tree**

Run the full test suite (command above). Expected: `** TEST SUCCEEDED **`. If it fails, STOP and report — do not start fixes on a red baseline.

- [ ] **Step 2: Review and commit the WIP**

Run `git status --short` and `git diff --stat` to confirm the change set, then:

```bash
git add -A
git commit -m "$(cat <<'EOF'
Add accessibility manager tests, release docs, and menu bar runtime protections

Pre-existing work in progress committed as a baseline before applying
technical-audit fixes.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

(Adjust the first line if `git diff --stat` shows the summary is inaccurate.)

---

### Task 1: Atomic `SlotStore.update` + unique temp file

**Files:**
- Modify: `Perch/Models/SlotStore.swift`
- Test: `PerchTests/SlotStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `final class SlotStoreTests`:

```swift
func testUpdateAppliesMutationAndPersists() async throws {
    let (directoryURL, fileURL) = makeTemporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    let store = try SlotStore(fileURL: fileURL)
    try await store.save(SlotStoreDocument())

    let updated = try await store.update { document in
        document.settings.retryAttempts = 7
    }

    XCTAssertEqual(updated.settings.retryAttempts, 7)
    let reloaded = try await store.load()
    XCTAssertEqual(reloaded.settings.retryAttempts, 7)
}

func testUpdateDoesNotPersistWhenMutationThrows() async throws {
    struct MutationError: Error {}
    let (directoryURL, fileURL) = makeTemporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    let store = try SlotStore(fileURL: fileURL)
    try await store.save(SlotStoreDocument())

    do {
        try await store.update { _ in throw MutationError() }
        XCTFail("Expected update to rethrow the mutation error")
    } catch is MutationError {
        // expected
    }

    let reloaded = try await store.load()
    XCTAssertEqual(reloaded.settings.retryAttempts, 3)
}

func testSaveLeavesNoTemporaryFilesBehind() async throws {
    let (directoryURL, fileURL) = makeTemporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    let store = try SlotStore(fileURL: fileURL)
    try await store.save(SlotStoreDocument())
    try await store.save(SlotStoreDocument())

    let contents = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
    XCTAssertEqual(contents.sorted(), [SlotStore.fileName])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: single-class command with `SlotStoreTests`.
Expected: compile error `value of type 'SlotStore' has no member 'update'`.

- [ ] **Step 3: Implement `update` and unique temp name**

In `Perch/Models/SlotStore.swift`, add below `save(_:)`:

```swift
@discardableResult
func update(_ mutate: @Sendable (inout SlotStoreDocument) throws -> Void) throws -> SlotStoreDocument {
    var document = try load()
    try mutate(&document)
    try save(document)
    return document
}
```

In `save(_:)`, replace the fixed temp path:

```swift
let temporaryURL = fileURL
    .deletingLastPathComponent()
    .appendingPathComponent("\(fileURL.lastPathComponent).tmp")
```

with a unique one plus cleanup:

```swift
let temporaryURL = fileURL
    .deletingLastPathComponent()
    .appendingPathComponent("\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
defer { try? fileManager.removeItem(at: temporaryURL) }
```

(The `defer` is a no-op after a successful `rename`; it only cleans up when the write or rename fails.)

- [ ] **Step 4: Run tests to verify they pass**

Single-class command with `SlotStoreTests`. Expected: PASS, including the pre-existing tests.

- [ ] **Step 5: Commit**

```bash
git add Perch/Models/SlotStore.swift PerchTests/SlotStoreTests.swift
git commit -m "$(cat <<'EOF'
Add atomic SlotStore.update and unique temp file for saves

Read-modify-write now happens inside the actor so concurrent writers
cannot interleave loads and saves, and parallel saves no longer share
one .tmp path.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Corrupt store quarantine + recovery

**Files:**
- Modify: `Perch/Models/SlotStore.swift`
- Test: `PerchTests/SlotStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside `final class SlotStoreTests`:

```swift
func testLoadQuarantinesCorruptStoreAndReturnsDefaults() async throws {
    let (directoryURL, fileURL) = makeTemporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try Data("{ not valid json".utf8).write(to: fileURL)

    let store = try SlotStore(fileURL: fileURL)
    let document = try await store.load()

    XCTAssertEqual(document, SlotStoreDocument())

    let contents = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
    XCTAssertEqual(contents.count, 1)
    XCTAssertTrue(
        contents[0].hasPrefix("\(SlotStore.fileName).corrupt-"),
        "Expected quarantined file, found: \(contents)"
    )

    try await store.save(document)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
}
```

- [ ] **Step 2: Run test to verify it fails**

Single-class command with `SlotStoreTests`.
Expected: FAIL — `load()` currently throws a `DecodingError` instead of recovering.

- [ ] **Step 3: Implement quarantine in `load()`**

Replace the body of `load()`:

```swift
func load() throws -> SlotStoreDocument {
    try hardenExistingStorePermissions()

    guard fileManager.fileExists(atPath: fileURL.path) else {
        return SlotStoreDocument()
    }

    let data = try Data(contentsOf: fileURL)
    do {
        return try decoder.decode(SlotStoreDocument.self, from: data)
    } catch {
        try quarantineCorruptStore(decodeError: error)
        return SlotStoreDocument()
    }
}
```

Add a private method:

```swift
private func quarantineCorruptStore(decodeError: Error) throws {
    let quarantineURL = fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(UUID().uuidString)")

    do {
        try fileManager.moveItem(at: fileURL, to: quarantineURL)
    } catch {
        AppLog.persistence.error(
            "Store file is corrupt and could not be quarantined: \(error.localizedDescription, privacy: .public)"
        )
        throw decodeError
    }

    AppLog.persistence.error(
        "Store file was corrupt; moved to \(quarantineURL.lastPathComponent, privacy: .public) and reset to defaults: \(decodeError.localizedDescription, privacy: .public)"
    )
}
```

Note: only decode failures recover. Read failures (`Data(contentsOf:)`) still throw — never destroy data we could not even read.

- [ ] **Step 4: Run tests to verify they pass**

Single-class command with `SlotStoreTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Perch/Models/SlotStore.swift PerchTests/SlotStoreTests.swift
git commit -m "$(cat <<'EOF'
Quarantine corrupt store file and recover with defaults

A corrupt slots.json previously made every operation fail with a decode
error and no way out. The file is now moved aside as
slots.json.corrupt-<id> and the app restarts from defaults.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Shared `SlotEngine` + engine ops via `store.update`

**Files:**
- Modify: `Perch/Core/SlotEngine.swift`
- Modify: `Perch/PerchApp.swift:36`
- Modify: `Perch/UI/Settings/SettingsModel.swift:30-38`
- Test: `PerchTests/SlotStoreTests.swift`

The SwiftUI `Settings` scene in `PerchApp.swift` stays (an `App` body must declare a scene); the fix is that every `SettingsModel` now reuses one engine instead of building its own store.

- [ ] **Step 1: Write the failing test**

Append inside `final class SlotStoreTests`:

```swift
@MainActor
func testSharedEngineReturnsSameInstance() throws {
    let first = try SlotEngine.shared()
    let second = try SlotEngine.shared()
    XCTAssertTrue(first === second)
}
```

(Safe: constructing the live engine performs no file I/O until an operation runs.)

- [ ] **Step 2: Run test to verify it fails**

Single-class command with `SlotStoreTests`.
Expected: compile error `type 'SlotEngine' has no member 'shared'`.

- [ ] **Step 3: Implement `SlotEngine.shared()` and convert ops to `update`**

In `Perch/Core/SlotEngine.swift`, below `static func live()`:

```swift
private static var sharedEngine: SlotEngine?

static func shared() throws -> SlotEngine {
    if let sharedEngine {
        return sharedEngine
    }

    let engine = try SlotEngine.live()
    sharedEngine = engine
    return engine
}
```

Make the index helper usable inside `@Sendable` closures — replace the instance method `index(of:in:)` with:

```swift
private nonisolated static func index(of slotID: String, in document: SlotStoreDocument) throws -> Int {
    guard let index = document.slots.firstIndex(where: { $0.id == slotID }) else {
        throw SlotEngineError.slotNotFound(slotID)
    }

    return index
}
```

and update existing call sites (`setRestoreHotkey`, `save(slotID:)`, `restore(slotID:)`) to `Self.index(of:in:)`.

Convert the three load-modify-save sequences:

```swift
func setRestoreHotkey(layoutID: String, hotkey: HotkeyBinding?) async throws {
    try await store.update { document in
        let slotIndex = try Self.index(of: layoutID, in: document)

        if let conflict = document.hotkeyConflict(for: hotkey, layoutID: layoutID) {
            throw SlotEngineError.hotkeyConflict(conflict)
        }

        document.slots[slotIndex].restoreHotkey = hotkey
    }
    notifyDocumentDidChange()

    AppLog.hotkeys.info("Updated restore hotkey for layout \(layoutID, privacy: .public)")
}

func updateSettings(_ update: @Sendable (inout PerchSettings) -> Void) async throws -> PerchSettings {
    let document = try await store.update { document in
        update(&document.settings)
    }
    notifyDocumentDidChange()

    return document.settings
}

func save(slotID: String) async throws -> SlotOperationResult {
    let snapshots = try snapshotter.captureCurrentWindows()
    let savedAt = Date()

    let document = try await store.update { document in
        let slotIndex = try Self.index(of: slotID, in: document)
        document.slots[slotIndex].windows = snapshots
        document.slots[slotIndex].lastSaved = savedAt
    }
    notifyDocumentDidChange()

    guard let slot = document.slots.first(where: { $0.id == slotID }) else {
        throw SlotEngineError.slotNotFound(slotID)
    }

    AppLog.persistence.info("Saved \(snapshots.count) windows to slot \(slot.id, privacy: .public)")

    return SlotOperationResult(
        slotID: slot.id,
        slotName: slot.name,
        succeeded: snapshots.count,
        total: snapshots.count
    )
}
```

(Behavior note: `save` now captures windows before validating the slot ID exists; both callers — hotkeys and menu — only pass IDs from the loaded document, so this is unobservable in practice.)

In `Perch/PerchApp.swift` replace `let slotEngine = try SlotEngine.live()` with:

```swift
let slotEngine = try SlotEngine.shared()
```

In `Perch/UI/Settings/SettingsModel.swift` replace the body of `initializeEngineIfNeeded()`:

```swift
private func initializeEngineIfNeeded() {
    guard slotEngine == nil else { return }

    do {
        slotEngine = try SlotEngine.shared()
    } catch {
        errorMessage = error.localizedDescription
    }
}
```

- [ ] **Step 4: Run the full test suite**

Full-suite command. Expected: PASS (existing engine tests in `SlotStoreTests` act as regression for the converted methods).

- [ ] **Step 5: Build the app target**

App build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Perch/Core/SlotEngine.swift Perch/PerchApp.swift Perch/UI/Settings/SettingsModel.swift PerchTests/SlotStoreTests.swift
git commit -m "$(cat <<'EOF'
Share one SlotEngine and run engine mutations atomically

AppDelegate and every SettingsModel previously built independent
engines and stores over the same slots.json, so concurrent
load-modify-save sequences could drop each other's writes. All
mutations now go through SlotStore.update on a single shared engine.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Shared `CGRect` extensions + `clamped(to:)`

**Files:**
- Create: `Perch/Core/CGRectExtensions.swift`
- Create: `PerchTests/WindowGeometryTests.swift`
- Modify: `Perch/Core/WindowMover.swift:1323-1347` (delete private extension)
- Modify: `Perch/Core/WindowSnapshotter.swift:341-356` (delete private extension)
- Modify: `project.yml` (add both new files to the `PerchTests` target sources)

- [ ] **Step 1: Create the new test file with failing tests**

Create `PerchTests/WindowGeometryTests.swift`:

```swift
import CoreGraphics
import XCTest

final class WindowGeometryTests: XCTestCase {
    func testClampedKeepsFrameAlreadyInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

        XCTAssertEqual(frame.clamped(to: bounds), frame)
    }

    func testClampedShrinksOversizedFrameToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)

        XCTAssertEqual(frame.clamped(to: bounds), bounds)
    }

    func testClampedMovesOffscreenOriginInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 2000, y: 850, width: 1200, height: 600)

        XCTAssertEqual(
            frame.clamped(to: bounds),
            CGRect(x: 240, y: 300, width: 1200, height: 600)
        )
    }

    func testClampedHandlesDisplaysWithNegativeOrigin() {
        let bounds = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let frame = CGRect(x: -3000, y: -100, width: 800, height: 600)

        XCTAssertEqual(
            frame.clamped(to: bounds),
            CGRect(x: -2560, y: 0, width: 800, height: 600)
        )
    }
}
```

- [ ] **Step 2: Create `Perch/Core/CGRectExtensions.swift`**

Move the duplicated private helpers here as one internal extension (union of both copies, plus the new `clamped(to:)`):

```swift
import CoreGraphics

extension CGRect {
    var isValidWindowFrame: Bool {
        origin.x.isFinite &&
            origin.y.isFinite &&
            size.width.isFinite &&
            size.height.isFinite &&
            width > 0 &&
            height > 0
    }

    var area: CGFloat {
        guard width > 0, height > 0 else {
            return 0
        }

        return width * height
    }

    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance &&
            abs(origin.y - other.origin.y) <= tolerance &&
            abs(size.width - other.size.width) <= tolerance &&
            abs(size.height - other.size.height) <= tolerance
    }

    func clamped(to bounds: CGRect) -> CGRect {
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let x = min(max(origin.x, bounds.minX), bounds.maxX - width)
        let y = min(max(origin.y, bounds.minY), bounds.maxY - height)

        return CGRect(x: x, y: y, width: width, height: height)
    }
}
```

- [ ] **Step 3: Delete the two private duplicates**

- In `Perch/Core/WindowMover.swift`: delete the whole `private extension CGRect { ... }` block at the end of the file (contains `isValidWindowFrame`, `area`, `isApproximatelyEqual`).
- In `Perch/Core/WindowSnapshotter.swift`: delete the whole `private extension CGRect { ... }` block at the end of the file (contains `area`, `isApproximatelyEqual`).

- [ ] **Step 4: Register the files with both targets**

In `project.yml`, in the `PerchTests` target `sources` list, add:

```yaml
      - path: Perch/Core/CGRectExtensions.swift
```

(`PerchTests/WindowGeometryTests.swift` is picked up automatically via `- path: PerchTests`; the app target picks up the new Core file via `- path: Perch`.)

Then run:

```bash
xcodegen generate
```

- [ ] **Step 5: Run tests and build**

Single-class command with `WindowGeometryTests` — expected PASS.
Full suite — expected PASS (WindowMover/Snapshotter still compile against the shared extension).
App build command — expected `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Perch/Core/CGRectExtensions.swift PerchTests/WindowGeometryTests.swift Perch/Core/WindowMover.swift Perch/Core/WindowSnapshotter.swift project.yml Perch.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Consolidate CGRect helpers and add clamped(to:)

WindowMover and WindowSnapshotter carried duplicate private CGRect
extensions; they now share one internal extension that also provides
display-bounds clamping for restore.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Clamp restore target frames to display bounds

> **Review amendment (applied in commit `beaac7e`):** unconditional clamping was a faithfulness regression — windows saved deliberately hanging over a display edge were repositioned. Final semantics: **"faithful unless invisible"** — `targetFrame` returns the computed frame verbatim whenever it still intersects the resolved display, and clamps via a `rescuedFrame(_:on:)` helper only when the frame would be completely offscreen (zero intersection, including the degenerate 0×0-bounds guard). The test set below was superseded by 9 tests covering: faithful map, UUID fallback, edge-hanging window kept, oversized-but-intersecting kept, rescue after display resize, partially-visible legacy kept, fully-offscreen legacy rescued, no displays, degenerate bounds.

**Files:**
- Modify: `Perch/Core/SlotEngine.swift:770-787` (`targetFrame`), plus the `restore`/`moveRequests` call chain
- Modify: `Perch/Core/DisplayManager.swift` (pure `in displays:` overloads)
- Test: `PerchTests/WindowGeometryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `PerchTests/WindowGeometryTests.swift` (inside the class), plus the helpers below the class:

```swift
    // MARK: - SlotEngine.targetFrame

    private let mainDisplay = DisplayInfo(
        id: 1,
        uuid: "MAIN",
        bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
        isMain: true
    )
    private let sideDisplay = DisplayInfo(
        id: 2,
        uuid: "SIDE",
        bounds: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
        isMain: false
    )

    func testTargetFrameMapsLocalFrameOntoSavedDisplay() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 1540, y: 100, width: 800, height: 600),
            displayUUID: "SIDE",
            localFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [mainDisplay, sideDisplay])

        XCTAssertEqual(target, CGRect(x: 1540, y: 100, width: 800, height: 600))
    }

    func testTargetFrameFallsBackToDisplayContainingSavedFrame() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 200, y: 100, width: 800, height: 600),
            displayUUID: "GONE",
            localFrame: CGRect(x: 200, y: 100, width: 800, height: 600)
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [mainDisplay])

        XCTAssertEqual(target, CGRect(x: 200, y: 100, width: 800, height: 600))
    }

    func testTargetFrameClampsOversizedWindowToSmallerDisplay() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 100, y: 100, width: 2560, height: 1440),
            displayUUID: "GONE",
            localFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [mainDisplay])

        XCTAssertEqual(target, CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func testTargetFrameClampsOffscreenOriginIntoDisplay() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 3440, y: 200, width: 1200, height: 600),
            displayUUID: "SIDE",
            localFrame: CGRect(x: 2000, y: 200, width: 1200, height: 600)
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [mainDisplay, sideDisplay])

        XCTAssertEqual(target, CGRect(x: 2800, y: 200, width: 1200, height: 600))
    }

    func testTargetFrameClampsLegacySnapshotWithoutLocalFrame() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: -100, y: 850, width: 400, height: 300),
            displayUUID: nil,
            localFrame: nil
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [mainDisplay])

        XCTAssertEqual(target, CGRect(x: 0, y: 600, width: 400, height: 300))
    }

    func testTargetFrameReturnsSavedFrameWhenNoDisplays() {
        let snapshot = makeSnapshot(
            frame: CGRect(x: 100, y: 100, width: 800, height: 600),
            displayUUID: "MAIN",
            localFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        let target = SlotEngine.targetFrame(for: snapshot, displays: [])

        XCTAssertEqual(target, CGRect(x: 100, y: 100, width: 800, height: 600))
    }
```

Below the class, add:

```swift
private func makeSnapshot(
    frame: CGRect,
    displayUUID: String?,
    localFrame: CGRect?
) -> WindowSnapshot {
    WindowSnapshot(
        bundleIdentifier: "com.example.app",
        windowTitle: "Example",
        frame: CodableRect(frame),
        displayUUID: displayUUID,
        displayLocalFrame: localFrame.map { CodableRect($0) },
        windowRole: "AXWindow",
        processIdentifier: 100,
        capturedAt: Date(timeIntervalSince1970: 1_779_190_400)
    )
}
```

- [ ] **Step 2: Run tests to verify they fail**

Single-class command with `WindowGeometryTests`.
Expected: compile error — `SlotEngine` has no static `targetFrame(for:displays:)`.

- [ ] **Step 3: Add pure display-resolution overloads to `DisplayManager`**

In `Perch/Core/DisplayManager.swift`, refactor so the lookup logic takes displays as a parameter and the existing API delegates:

```swift
static func display(withUUID uuid: String) -> DisplayInfo? {
    display(withUUID: uuid, in: currentDisplays())
}

static func display(withUUID uuid: String, in displays: [DisplayInfo]) -> DisplayInfo? {
    displays.first { $0.uuid == uuid }
}

static func display(containing point: CGPoint) -> DisplayInfo? {
    display(containing: point, in: currentDisplays())
}

static func display(containing point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
    let containingDisplay = displays.first { $0.bounds.contains(point) }

    if let containingDisplay {
        return containingDisplay
    }

    AppLog.display.debug("No display contains point x=\(point.x), y=\(point.y); falling back to nearest display")
    return nearestDisplay(to: point, in: displays)
}

static func display(containing frame: CGRect) -> DisplayInfo? {
    display(containing: frame, in: currentDisplays())
}

static func display(containing frame: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
    if let display = displays
        .map({ display in
            (display: display, intersectionArea: intersectionArea(display.bounds, frame))
        })
        .filter({ $0.intersectionArea > 0 })
        .max(by: { $0.intersectionArea < $1.intersectionArea })?
        .display {
        return display
    }

    let center = CGPoint(x: frame.midX, y: frame.midY)
    AppLog.display.debug("No display intersects frame x=\(frame.origin.x), y=\(frame.origin.y), width=\(frame.width), height=\(frame.height); falling back to center point")
    return display(containing: center, in: displays)
}
```

(The bodies are the existing ones — only the `displays` source changes from `currentDisplays()` to the parameter.)

- [ ] **Step 4: Replace `SlotEngine.targetFrame` and thread displays through restore**

In `Perch/Core/SlotEngine.swift`, replace the private `targetFrame(for:)` with:

```swift
nonisolated static func targetFrame(for snapshot: WindowSnapshot, displays: [DisplayInfo]) -> CGRect {
    let savedFrame = snapshot.frame.cgRect

    guard let displayLocalFrame = snapshot.displayLocalFrame?.cgRect else {
        guard let display = DisplayManager.display(containing: savedFrame, in: displays) else {
            return savedFrame
        }

        return savedFrame.clamped(to: display.bounds)
    }

    let display = snapshot.displayUUID.flatMap { DisplayManager.display(withUUID: $0, in: displays) }
        ?? DisplayManager.display(containing: savedFrame, in: displays)

    guard let display else {
        return savedFrame
    }

    let globalFrame = displayLocalFrame.offsetBy(
        dx: display.bounds.origin.x,
        dy: display.bounds.origin.y
    )

    return globalFrame.clamped(to: display.bounds)
}
```

Thread one display snapshot through the restore chain so all windows of one restore see the same configuration:

In `restore(slotID:)`, after `await DisplayStabilizer.shared.waitForStable(...)`:

```swift
let displays = DisplayManager.currentDisplays()
```

and pass it down: `restore(snapshots:settings:displays:launchResults:)` gains a `displays: [DisplayInfo]` parameter, which forwards to `launchAndRestore(snapshots:requests:settings:launchResults:)` unchanged (requests are built before launching) and to:

```swift
private func moveRequests(
    for snapshots: [WindowSnapshot],
    settings: PerchSettings,
    displays: [DisplayInfo]
) -> [WindowBatchMoveRequest] {
    snapshots.map { snapshot in
        WindowBatchMoveRequest(
            snapshot: snapshot,
            frame: Self.targetFrame(for: snapshot, displays: displays),
            attempts: settings.retryAttempts
        )
    }
}
```

- [ ] **Step 5: Run tests and build**

Single-class command with `WindowGeometryTests` — expected PASS.
Full suite — expected PASS.
App build — expected `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Perch/Core/SlotEngine.swift Perch/Core/DisplayManager.swift PerchTests/WindowGeometryTests.swift
git commit -m "$(cat <<'EOF'
Clamp restore target frames to the resolved display bounds

Restoring a layout saved on a larger or disconnected display could
place windows fully offscreen and then fail frame verification. Target
frames are now clamped into the resolved display, the geometry mapping
is a pure tested function, and one display snapshot is used for the
whole restore.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Per-PID AX metadata cache in `WindowSnapshotter`

**Files:**
- Modify: `Perch/Core/WindowSnapshotter.swift`
- Create: `PerchTests/WindowSnapshotterTests.swift`

Current behavior: for every CG window, `axWindowMetadata` re-fetches **all** AX windows of that process and reads ~6 attributes from each — O(windows²) synchronous IPC per app. Split it into an expensive per-PID enumeration (cached) and a pure matching function (tested).

- [ ] **Step 1: Create the failing test file**

Create `PerchTests/WindowSnapshotterTests.swift`:

```swift
import CoreGraphics
import XCTest

@MainActor
final class WindowSnapshotterTests: XCTestCase {
    func testMatchPrefersUniqueExactTitle() {
        let windows = [
            metadata(title: "Inbox", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            metadata(title: "Budget", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "Budget",
            cgFrame: CGRect(x: 500, y: 500, width: 100, height: 100)
        )

        XCTAssertEqual(match?.title, "Budget")
    }

    func testMatchFallsBackToFrameWhenTitlesUnavailable() {
        let windows = [
            metadata(title: "", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            metadata(title: "", frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "",
            cgFrame: CGRect(x: 901, y: 1, width: 799, height: 600)
        )

        XCTAssertEqual(match?.frame, CGRect(x: 900, y: 0, width: 800, height: 600))
    }

    func testMatchUsesCaseInsensitiveTitleFallback() {
        let windows = [
            metadata(title: "BUDGET", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            metadata(title: "Inbox", frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "Budget",
            cgFrame: CGRect(x: 500, y: 500, width: 100, height: 100)
        )

        XCTAssertEqual(match?.title, "BUDGET")
    }

    func testMatchFallsBackToOnlyWindow() {
        let windows = [
            metadata(title: "Something Else", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "Budget",
            cgFrame: CGRect(x: 500, y: 500, width: 100, height: 100)
        )

        XCTAssertEqual(match?.title, "Something Else")
    }

    func testMatchReturnsNilWhenAmbiguous() {
        let windows = [
            metadata(title: "Untitled", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            metadata(title: "Untitled", frame: CGRect(x: 10, y: 10, width: 800, height: 600))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "Untitled",
            cgFrame: CGRect(x: 500, y: 500, width: 100, height: 100)
        )

        XCTAssertNil(match)
    }

    func testMatchIgnoresNonWindowRoles() {
        let windows = [
            metadata(title: "Budget", role: "AXSheet", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        ]

        let match = WindowSnapshotter.matchAXWindow(
            in: windows,
            cgTitle: "Budget",
            cgFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertNil(match)
    }

    private func metadata(
        title: String,
        role: String = "AXWindow",
        frame: CGRect?
    ) -> WindowSnapshotter.AXWindowMetadata {
        WindowSnapshotter.AXWindowMetadata(
            title: title,
            role: role,
            isMinimized: false,
            isFullscreen: false,
            accessibilityIdentifier: nil,
            frame: frame
        )
    }
}
```

Then run `xcodegen generate` (new file in `PerchTests/` is picked up via the directory path).

- [ ] **Step 2: Run tests to verify they fail**

Single-class command with `WindowSnapshotterTests`.
Expected: compile error — `AXWindowMetadata` is private and `matchAXWindow` does not exist.

- [ ] **Step 3: Refactor `WindowSnapshotter`**

In `Perch/Core/WindowSnapshotter.swift`:

1. Make the metadata struct internal and `Equatable` (replace `private struct AXWindowMetadata`):

```swift
struct AXWindowMetadata: Equatable {
    let title: String
    let role: String
    let isMinimized: Bool
    let isFullscreen: Bool
    let accessibilityIdentifier: String?
    let frame: CGRect?
}
```

2. In `captureCurrentWindows()`, add a cache and pass it down:

```swift
var axMetadataByProcess: [pid_t: [AXWindowMetadata]] = [:]
let snapshots = rawWindowList.compactMap { windowInfo in
    snapshot(from: windowInfo, displays: displays, axMetadataByProcess: &axMetadataByProcess)
}
```

3. In `snapshot(from:displays:)` add the parameter `axMetadataByProcess: inout [pid_t: [AXWindowMetadata]]` and replace the `axWindowMetadata(for:title:frame:)` call with:

```swift
let pid = pid_t(processIdentifier)
let processMetadata: [AXWindowMetadata]
if let cached = axMetadataByProcess[pid] {
    processMetadata = cached
} else {
    let fetched = axWindowList(for: pid)
    axMetadataByProcess[pid] = fetched
    processMetadata = fetched
}
let axMetadata = Self.matchAXWindow(in: processMetadata, cgTitle: cgTitle, cgFrame: frame)
```

4. Split `axWindowMetadata(for:title:frame:)` into two functions. The enumeration (expensive, once per PID):

```swift
private func axWindowList(for processIdentifier: pid_t) -> [AXWindowMetadata] {
    let appElement = AXUIElementCreateApplication(processIdentifier)
    guard let rawWindows = copyAttribute("AXWindows", from: appElement) as? [AXUIElement] else {
        return []
    }

    return rawWindows.compactMap { window -> AXWindowMetadata? in
        guard let role = copyAttribute("AXRole", from: window) as? String else {
            return nil
        }

        return AXWindowMetadata(
            title: copyAttribute("AXTitle", from: window) as? String ?? "",
            role: role,
            isMinimized: copyAttribute("AXMinimized", from: window) as? Bool ?? false,
            isFullscreen: copyAttribute("AXFullScreen", from: window) as? Bool ?? false,
            accessibilityIdentifier: copyAttribute("AXIdentifier", from: window) as? String,
            frame: readFrame(from: window)
        )
    }
}
```

And the matching (pure, static — the four existing match stages verbatim):

```swift
static func matchAXWindow(
    in metadata: [AXWindowMetadata],
    cgTitle: String,
    cgFrame: CGRect
) -> AXWindowMetadata? {
    if let exactMatch = uniqueMatch(
        in: metadata,
        matching: { $0.role == "AXWindow" && !$0.title.isEmpty && $0.title == cgTitle }
    ) {
        return exactMatch
    }

    if let frameMatch = uniqueMatch(
        in: metadata,
        matching: { $0.role == "AXWindow" && $0.frame?.isApproximatelyEqual(to: cgFrame, tolerance: 2) == true }
    ) {
        return frameMatch
    }

    if let caseInsensitiveMatch = uniqueMatch(
        in: metadata,
        matching: {
            $0.role == "AXWindow" &&
                !$0.title.isEmpty &&
                $0.title.localizedCaseInsensitiveCompare(cgTitle) == .orderedSame
        }
    ) {
        return caseInsensitiveMatch
    }

    return uniqueMatch(in: metadata, matching: { $0.role == "AXWindow" })
}

private static func uniqueMatch(
    in metadata: [AXWindowMetadata],
    matching predicate: (AXWindowMetadata) -> Bool
) -> AXWindowMetadata? {
    let matches = metadata.filter(predicate)
    return matches.count == 1 ? matches[0] : nil
}
```

(Delete the old `axWindowMetadata(for:title:frame:)` and the old instance `uniqueMatch`; keep the debug log for a nil match at the call site in `snapshot(from:...)` if desired.)

- [ ] **Step 4: Run tests and build**

Single-class command with `WindowSnapshotterTests` — expected PASS.
Full suite — expected PASS.
App build — expected `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Perch/Core/WindowSnapshotter.swift PerchTests/WindowSnapshotterTests.swift Perch.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Cache AX window metadata per process during capture

Capturing previously re-enumerated every AX window of an app for each
of its CG windows (O(n^2) synchronous IPC on the main actor). Metadata
is now fetched once per PID and the CG-to-AX correlation is a pure
tested function. Matching behavior is unchanged.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Dead code removal + single title normalizer

**Files:**
- Delete: `Perch/UI/OnboardingView.swift` (contains only `import SwiftUI`)
- Modify: `Perch/UI/ToastWindow.swift:27-30`
- Modify: `Perch/Core/WindowMover.swift`
- Modify: `Perch/Core/DisplayManager.swift`
- Modify: `Perch/Models/WindowSnapshot.swift`
- Modify: `Perch/Core/WindowSnapshotter.swift`
- Modify: `PerchTests/SlotStoreTests.swift`, `PerchTests/WindowMoverTests.swift`

**Rule for every deletion below: run the grep first. If it shows a production call site (not the definition, not a test), KEEP the symbol and note it in the final report instead.**

- [ ] **Step 1: Verify each symbol is unused, then delete**

```bash
grep -rn "findLiveWindows\|findWindow(\|readFrame(bundleIdentifier\|move(saved\|restore(snapshots\|WindowRestoreResult\|titleScoreMatrix\|bestTitleAssignments\|showRestoredWindowCount\|normalizedWindowTitle\|normalizeTitle\|displayContaining\|currentDisplayUUIDMap\|displayID(for" Perch PerchTests
```

Deletions:

1. `Perch/UI/OnboardingView.swift` — delete the file (`rm`).
2. `Perch/UI/ToastWindow.swift` — delete `showRestoredWindowCount(_:total:duration:)`.
3. `Perch/Core/WindowMover.swift` — delete:
   - `func findLiveWindows(...)` (~line 180)
   - `func findWindow(...)` (~line 203)
   - `func readFrame(bundleIdentifier:title:processIdentifier:strictness:)` (~line 216)
   - `func setFrame(_ frame:bundleIdentifier:title:processIdentifier:attempts:strictness:)` (~line 238, the title-based convenience; keep `setFrame(_ request:strictness:)`)
   - `func move(snapshot:to:attempts:)` (~line 290, the 3-argument overload; keep the 4-argument one — it is the `WindowMoving` protocol requirement)
   - `func move(saved:attempts:strictness:)` (~line 315)
   - `func restore(snapshots:settings:)` (~line 332)
   - `struct WindowRestoreResult` (~line 120)
   - `static func titleScoreMatrix(targets:candidates:)` (~line 480)
   - `static func bestTitleAssignments(targets:candidates:minimumScore:)` (~line 488) — production-unused; only referenced by one test
   - `static func restoreLogDescription(for:)` (~line 879) — its only caller was `move(saved:)`
4. `PerchTests/WindowMoverTests.swift` — delete `testBestTitleAssignmentsUsesEachCandidateOnce` (tests a deleted symbol).
5. `Perch/Core/DisplayManager.swift` — delete `displayContaining(point:)`, `displayContaining(frame:)`, `displayID(for:)`, `currentDisplayUUIDMap()` if the grep confirms no production call sites.

- [ ] **Step 2: Consolidate title normalization**

The single surviving normalizer is `WindowMover.normalizedTitle` (trim + case/diacritic fold + whitespace collapse).

1. `Perch/Models/WindowSnapshot.swift` — remove the stored field (it is written but never read by any matcher):
   - delete `var normalizedWindowTitle: String`
   - delete the `normalizedWindowTitle: String? = nil` init parameter and its assignment
   - delete `static func normalizeTitle(_:)`
   - delete `case normalizedWindowTitle = "normalizedTitle"` from `CodingKeys`
   - JSONDecoder ignores unknown keys, so existing `slots.json` files with `normalizedTitle` still decode.
2. `Perch/Core/WindowSnapshotter.swift` — remove the `normalizedWindowTitle: Self.normalizedTitle(windowTitle)` argument from the `WindowSnapshot(...)` call and delete `static func normalizedTitle(_:)` (its only consumer was that argument).
3. `PerchTests/SlotStoreTests.swift` — remove the `normalizedWindowTitle:` argument from the three `WindowSnapshot(...)` constructions (~lines 17, 145, 430). If `testLegacySnapshotsWithoutWindowIdentityDecode` asserts on `normalizedWindowTitle`, drop that assertion; keep the rest of the test.

- [ ] **Step 3: Regenerate project, run everything**

```bash
xcodegen generate
```

Full test suite — expected PASS.
App build — expected `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
Remove dead window-mover API and consolidate title normalization

Deletes unused WindowMover entry points, WindowRestoreResult,
DisplayManager wrappers, ToastWindow.showRestoredWindowCount, the empty
OnboardingView, and the never-read WindowSnapshot.normalizedWindowTitle
field. WindowMover.normalizedTitle is now the single title normalizer.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Final verification

- [ ] **Step 1: Full test suite**

Full-suite command. Expected: `** TEST SUCCEEDED **`, with the new tests visible in the log (`WindowGeometryTests`, `WindowSnapshotterTests`, new `SlotStoreTests` cases).

- [ ] **Step 2: Debug build of the app**

App build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Sanity-check the diff**

```bash
git log --oneline main@{u}..HEAD 2>/dev/null || git log --oneline -8
git diff --stat HEAD~7..HEAD 2>/dev/null || true
```

Confirm: one WIP baseline commit + one commit per task, no unrelated files touched, no leftover `.tmp` or `.corrupt-` artifacts in the repo.

- [ ] **Step 4: Report**

Summarize for the user (in Czech): what changed per fix, test counts before/after, and explicitly list any symbol from Task 7 that was KEPT because the grep found a real call site.
