# Feature brief: Automatic restore after wake / display change

**Status:** Phase 1 code complete; Task 1.8 hardware verification pending; Phase 2 deferred
**Target version:** 0.2.0
**Schema impact:** `slots.json` v2 → v3 (migration required)

---

## 1. Problem

Perch today only restores window layouts when the user presses a shortcut. The
problem Perch exists to solve — MacBook wakes from sleep with external displays
attached and macOS scatters every window — happens *without* the user asking for
anything. The user has to notice the mess, remember Perch exists, and remember
which shortcut to press.

Every competitor (Display Maid, Stay, Moom, Layoutish, Memmon) restores
automatically. Perch does not. This is the single largest functional gap.

## 2. What we are NOT building, and why

**We are not building blind auto-restore.** Moom does this and its most common
user complaint is exactly that: it fires at the wrong moment, restores the wrong
thing, and the user only finds out when a window is missing.

The window-moving machinery (`WindowMover`) is equally reliable whether a human
or a timer triggers it. What automation cannot do reliably is supply the two
pieces of judgement a human supplies for free:

1. **"Now is the right moment."** After wake, displays settle asynchronously.
   A DisplayLink dock can take 5+ seconds and arrive in waves.
2. **"This is the layout I want."** Topology alone is ambiguous.

Therefore the default behaviour is **detect and offer**, not **detect and act**.
Fully automatic mode exists as an opt-in for users who want it.

## 3. Design summary

Two phases, shippable independently.

**Phase 1 — Detection and prompt.** Perch watches for wake / display
reconfiguration / screen unlock. When the environment settles and the display
topology has changed, and a saved layout matches the new topology, Perch shows a
non-intrusive prompt: *"Restore Work? Press ⌘⌥1"*. The user confirms or ignores
it. Nothing moves without confirmation.

**Phase 2 — Live layouts (auto-save).** Perch keeps one automatically-maintained
snapshot **per display topology**, refreshed while the environment is stable.
After a topology change it offers to restore the live snapshot for that topology.
The user never has to save anything manually.

Phase 2 is what makes the product invisible. Phase 1 is what makes Phase 2 safe.

## 4. Key correctness rules

These are the rules that make or break the feature. Violating any of them turns
Perch from helpful into destructive.

**R1 — Never auto-save a scrambled state.** After any topology change, auto-save
must be suspended until the environment has been stable *and* the user has
either accepted or dismissed the prompt. Otherwise the 3-second window where
macOS has piled every window onto the built-in display gets written over a good
snapshot, and the good layout is gone forever.

**R2 — One live snapshot per topology, never cross-contaminated.** A snapshot
captured with two external displays must never overwrite the laptop-only
snapshot, or vice versa. Keying live snapshots by topology identity enforces
this structurally.

**R3 — Topology matching must be tolerant of bounds, strict about identity.**
`DisplayTopologyFingerprint` currently compares exact `CGRect` bounds. Bounds
shift by a point after a resolution renegotiation, which would make every match
fail. Matching must use the **set of display UUIDs plus which one is main**.
Bounds stay in the fingerprint for diagnostics only.

**R4 — Never move windows while the user is already moving them.** If the user
has interacted with the machine since the trigger fired, do not auto-restore in
automatic mode; downgrade to a prompt.

**R5 — Failures stay visible.** An automatic restore produces the same
`SlotOperationResult` report as a manual one. Partial failures must surface, not
be swallowed because nobody was watching.

---

# Phase 1 — Detection and prompt

## Task 1.1: Tolerant topology identity

**Files:**
- Modify: `Perch/Core/SlotEngine.swift` (`DisplayTopologyFingerprint`)
- Modify: `project.yml` (if the fingerprint moves to its own file, add it to
  `PerchTests.sources`)
- Create: `PerchTests/DisplayTopologyFingerprintTests.swift`

**Interfaces produced:**

```swift
extension DisplayTopologyFingerprint {
    /// Stable, order-independent identity of a display arrangement.
    /// Format: sorted display UUIDs joined by "|", with the main display
    /// suffixed "*". Used as a dictionary key and for layout matching.
    var identity: String { get }

    /// True when both fingerprints describe the same set of displays with the
    /// same main display, regardless of exact bounds.
    func matchesIdentity(of other: DisplayTopologyFingerprint) -> Bool
}
```

**Steps:**

- [ ] Add `identity` as a computed property over the already-sorted `entries`.
      Entries are sorted by UUID in `init`, so the string is deterministic.
- [ ] Add `matchesIdentity(of:)` comparing `identity` strings.
- [ ] Make `DisplayTopologyFingerprint` `Codable` and `Hashable` — it will be
      persisted in `slots.json` from Task 1.2 onward. `CGRect` is not `Codable`;
      reuse the existing `CodableRect` from `WindowSnapshot.swift` for `bounds`.
- [ ] Consider moving the type out of `SlotEngine.swift` into
      `Perch/Models/DisplayTopologyFingerprint.swift` so the test target can
      compile it without pulling in AppKit. `PerchTests.sources` in `project.yml`
      lists files explicitly — add it there.
- [ ] Tests: identity is order-independent; identity changes when the main
      display changes; identity is unchanged when only bounds change; round-trip
      `Codable`.

## Task 1.2: Persist the topology a layout was captured under

**Files:**
- Modify: `Perch/Models/Slot.swift` (`Slot`, `SlotStoreDocument`, `PerchSettings`)
- Modify: `Perch/Models/SlotStore.swift` (migration v2 → v3)
- Modify: `Perch/Core/SlotEngine.swift` (`save(slotID:)`)
- Modify: `PerchTests/SlotStoreTests.swift` (or equivalent existing file)

**Interfaces produced:**

```swift
struct Slot {
    // ...existing fields...
    /// Display arrangement present when this layout was last saved.
    /// nil for layouts saved before schema v3.
    var capturedTopology: DisplayTopologyFingerprint?
}
```

**Steps:**

- [ ] Add `capturedTopology` to `Slot` with `decodeIfPresent` in the custom
      `init(from:)`, defaulting to `nil`. Add to `CodingKeys`.
- [ ] Bump `SlotStoreDocument.currentVersion` to `3`.
- [ ] Add a v2 → v3 migration alongside the existing v1 → v2 path in `SlotStore`.
      v3 adds only optional fields, so migration is: accept v2, write v3. Follow
      the existing pattern — do not touch the reject-newer-version behaviour.
- [ ] In `SlotEngine.save(slotID:)`, capture
      `DisplayTopologyFingerprint(displays: displayProvider())` alongside the
      snapshots and store it on the slot.
- [ ] `SlotStoreDocument.validate()`: no new validation needed, but confirm an
      absent `capturedTopology` does not trip anything.
- [ ] Tests: v2 document loads and upgrades cleanly with `capturedTopology == nil`;
      a v3 round-trip preserves the fingerprint; a v4 document is still rejected.

## Task 1.3: Environment change observer

**Files:**
- Create: `Perch/Core/EnvironmentChangeObserver.swift`
- Modify: `Perch/Core/DisplayStabilizer.swift` (expose change notifications)
- Modify: `Perch/PerchApp.swift` (start the observer)

**Interfaces produced:**

```swift
/// Reason the environment was considered to have changed. Diagnostic only —
/// the coordinator treats all reasons identically.
enum EnvironmentChangeReason: String, Sendable {
    case systemWake
    case screensWake
    case displayReconfiguration
    case screenUnlock
    case sessionActive
}

@MainActor
final class EnvironmentChangeObserver {
    init(onSettled: @escaping @MainActor (EnvironmentChangeReason) -> Void)
    func start()
    func stop()
}
```

**Behaviour:**

Observe, all coalescing into one pipeline:

| Source | Notification | Center |
|---|---|---|
| System wake | `NSWorkspace.didWakeNotification` | `NSWorkspace.shared.notificationCenter` |
| Display wake | `NSWorkspace.screensDidWakeNotification` | `NSWorkspace.shared.notificationCenter` |
| Session active | `NSWorkspace.sessionDidBecomeActiveNotification` | `NSWorkspace.shared.notificationCenter` |
| Screen params | `NSApplication.didChangeScreenParametersNotification` | `NotificationCenter.default` |
| Screen unlock | `com.apple.screenIsUnlocked` | `DistributedNotificationCenter.default()` |

The distributed notification requires the app to be unsandboxed. `Perch.entitlements`
is empty, so this works — but leave a comment saying so, because it silently
stops working if sandboxing is ever added.

**Steps:**

- [ ] Register all five observers in `start()`, remove them in `stop()` and
      `deinit`.
- [ ] Coalesce: any trigger cancels the in-flight settle task and starts a new
      one. Never fire `onSettled` more than once per burst.
- [ ] The settle task awaits
      `DisplayStabilizer.shared.waitForStable(quietPeriod: 2.0, timeout: settleTimeout)`.
      The existing default quiet period of 1.0 s is too short for docks —
      pass 2.0 explicitly.
- [ ] `settleTimeout` comes from the new `PerchSettings.autoRestoreSettleTimeout`
      (Task 1.5), default **10 s**. Do not reuse `stabilizationTimeout` (2.5 s) —
      that value is tuned for a manual restore where displays are already stable.
- [ ] After `waitForStable` returns, wait an additional grace period of **1.5 s**
      before calling `onSettled`. Displays report themselves ready before macOS
      has finished relocating windows; firing too early means reading a topology
      that is about to change again.
- [ ] `DisplayStabilizer` currently only records a timestamp. Keep that, but the
      observer needs to know a reconfiguration *happened*, not just when. Either
      expose `var lastChangeTime: Date { get }` on the actor or have the
      reconfiguration callback post `.perchDisplayDidReconfigure` — the second is
      cleaner and matches the existing `.perchDocumentDidChange` pattern.
- [ ] Log every trigger at `.info` on `AppLog.display` with the reason. This is
      the only way to debug a user report of "it didn't fire".
- [ ] Start the observer from `AppDelegate.applicationDidFinishLaunching`, after
      `SlotEngine` is constructed. Store it on the delegate so it stays alive.

## Task 1.4: Auto-restore policy (pure logic, fully testable)

**Files:**
- Create: `Perch/Core/AutoRestorePolicy.swift`
- Create: `PerchTests/AutoRestorePolicyTests.swift`
- Modify: `project.yml` (add both to the relevant `sources` lists)

This type must have **no AppKit or CoreGraphics-callback dependencies** so the
`PerchTests` target can compile it. All inputs are passed in.

**Interfaces produced:**

```swift
enum AutoRestoreDecision: Equatable, Sendable {
    /// Topology unchanged, or feature off.
    case doNothing(reason: String)
    /// Offer this layout to the user.
    case prompt(layoutID: String, layoutName: String)
    /// Restore without asking (automatic mode only).
    case restore(layoutID: String, layoutName: String)
}

struct AutoRestoreInput: Sendable {
    var mode: AutoRestoreMode
    var currentTopology: DisplayTopologyFingerprint
    var topologyAtLastDecision: DisplayTopologyFingerprint?
    var slots: [Slot]
    var userInteractedSinceTrigger: Bool
    var alreadyPromptedForCurrentTopology: Bool
}

enum AutoRestorePolicy {
    static func decide(_ input: AutoRestoreInput) -> AutoRestoreDecision
}
```

**Decision order — implement exactly this sequence:**

1. `mode == .off` → `.doNothing("disabled")`
2. `topologyAtLastDecision` matches `currentTopology` by identity →
   `.doNothing("topology unchanged")`
3. `alreadyPromptedForCurrentTopology` → `.doNothing("already offered")`
4. Find candidate: the slot whose `capturedTopology` matches `currentTopology`
   by identity. If several match, pick the most recently saved (`lastSaved`).
   If none match → `.doNothing("no layout for this arrangement")`
5. Candidate has zero windows → `.doNothing("layout is empty")`
6. `mode == .automatic && !userInteractedSinceTrigger` → `.restore(...)` (R4)
7. Otherwise → `.prompt(...)`

**Steps:**

- [ ] Implement `decide` as a flat sequence of guards in the order above.
- [ ] Tests, one per branch, plus: two candidates → newest wins; a layout with
      `capturedTopology == nil` (pre-v3) is never selected; automatic mode
      downgrades to prompt when the user has interacted.

## Task 1.5: Settings

**Files:**
- Modify: `Perch/Models/Slot.swift` (`PerchSettings`, `SlotStoreDocument.validate`)
- Modify: `Perch/UI/Settings/GeneralSettingsTab.swift`
- Modify: `Perch/UI/Settings/SettingsModel.swift`
- Modify: `Perch/Infrastructure/Localization/LocalizationKey.swift` and
  `LocalizationCatalog.swift`

**Interfaces produced:**

```swift
enum AutoRestoreMode: String, Codable, CaseIterable, Sendable {
    case off
    case prompt      // default
    case automatic
}

struct PerchSettings {
    // ...existing...
    var autoRestoreMode: AutoRestoreMode          // default .prompt
    var autoRestoreSettleTimeout: TimeInterval    // default 10, range 0...60
}
```

**Steps:**

- [ ] Add both fields with `decodeIfPresent` defaults in `init(from:)`.
- [ ] Add `autoRestoreSettleTimeoutRange = 0.0...60.0` and validate it in
      `SlotStoreDocument.validate()`, matching the existing
      `stabilizationTimeoutRange` pattern including a new `ValidationError` case.
- [ ] UI in the General tab: a segmented control or popup with three options.
      Copy suggestion (EN):
      - "When displays change: **Do nothing** / **Ask me** / **Restore automatically**"
      - Footnote for `.prompt`: "Perch will offer to restore the layout saved for
        this display arrangement."
- [ ] Put the settle timeout in an advanced/disclosure area, not the main tab.
- [ ] Add localisation keys for all five languages. Follow the existing
      `LocalizationKey` enum + catalog structure; do not hardcode strings.
- [ ] Tests: defaults; out-of-range timeout rejected; unknown mode string in JSON
      falls back to `.prompt` rather than failing the whole document load.

## Task 1.6: Restore prompt UI

**Files:**
- Create: `Perch/UI/RestorePromptWindow.swift`
- Modify: `Perch/Infrastructure/Localization/*` (new keys)

**The important constraint:** `ToastWindow` sets `ignoresMouseEvents = true`,
`canBecomeKey = false` and is a `.nonactivatingPanel`. Perch is `LSUIElement`, so
making a panel key requires activating the app, which steals focus from whatever
the user is doing. **Do not activate the app.**

Solution: the prompt is **clickable, and confirmable via the layout's existing
global restore shortcut**. No new hotkey machinery, no focus theft. The prompt
displays the shortcut so the user knows what to press.

**Interfaces produced:**

```swift
@MainActor
final class RestorePromptWindow: NSPanel {
    static func show(
        layoutName: String,
        shortcutDescription: String?,
        duration: TimeInterval,
        onConfirm: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    )
    static func dismissCurrent()
}
```

**Steps:**

- [ ] Start from `ToastWindow` — same `NSVisualEffectView` container, same
      positioning, same `.canJoinAllSpaces` collection behaviour, same fade.
      Consider extracting the shared chrome rather than copy-pasting.
- [ ] Set `ignoresMouseEvents = false`. Keep `canBecomeKey = false` and
      `canBecomeMain = false`. Keep `isFloatingPanel = true`, `level = .statusBar`.
- [ ] Content: SF Symbol `macwindow.on.rectangle`, text
      "Restore *{layoutName}*?", a subdued line showing the shortcut, a primary
      "Restore" button and a close affordance.
- [ ] Auto-dismiss after **12 s** (longer than the 1.8 s toast — the user may be
      looking away when the machine wakes). Cancel the timer on hover.
- [ ] Only one prompt at a time; `show` dismisses any existing one.
- [ ] Post the accessibility announcement like `ToastWindow` does.
- [ ] Do not reuse `ToastWindow.currentToast` — a restore-result toast firing
      must not silently kill an open prompt, and vice versa.

## Task 1.7: Coordinator wiring

**Files:**
- Create: `Perch/Core/AutoRestoreCoordinator.swift`
- Modify: `Perch/PerchApp.swift`
- Modify: `Perch/UI/MenuBarController.swift`

**Interfaces produced:**

```swift
@MainActor
final class AutoRestoreCoordinator {
    init(slotEngine: SlotEngine, menuBarController: MenuBarController)
    func start()
}
```

**Steps:**

- [ ] Own an `EnvironmentChangeObserver`. On settle: read the current document,
      build `AutoRestoreInput`, call `AutoRestorePolicy.decide`.
- [ ] Track `topologyAtLastDecision` and `alreadyPromptedForCurrentTopology` in
      the coordinator. Reset the "already prompted" flag whenever the topology
      identity changes.
- [ ] `userInteractedSinceTrigger`: use
      `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)`
      and the keyboard equivalent, or a `NSEvent.addGlobalMonitorForEvents`
      started at trigger time. The event-source approach needs no extra
      permission and is simpler — prefer it. Threshold: any input within the
      last 3 s counts as interaction.
- [ ] `.prompt` → `RestorePromptWindow.show(...)`, confirm handler calls the
      same `menuBarController.restoreLayout(id:)` path the shortcut uses, so
      result toasts and error reporting are identical (R5).
- [ ] `.restore` → call the restore path directly.
- [ ] `.doNothing` → log the reason at `.debug`, do nothing visible.
- [ ] Never bypass `SlotEngine.performExclusiveWindowOperation`. If a manual
      operation is already running the automatic one is correctly rejected —
      swallow that specific error silently rather than showing an alarming toast.
- [ ] Menu bar: add a diagnostic line showing what the last automatic decision
      was, disabled/greyed. Very cheap, saves enormous support pain.
- [ ] Include the last decision in `DiagnosticsExporter` output.

## Task 1.8: Manual verification checklist

Automated tests cannot cover any of this. Perform each on real hardware and
record the result.

- [ ] Sleep with two external displays, wake → prompt appears once, naming the
      right layout.
- [ ] Same, but confirm the prompt → windows land correctly, result toast shows.
- [ ] Same, but ignore the prompt → it disappears, nothing moves, no second prompt.
- [ ] Wake with **no** display change (laptop alone, slept and woken) → no prompt.
- [ ] Undock while awake → prompt for the laptop-only layout.
- [ ] Redock while awake → prompt for the docked layout.
- [ ] DisplayLink or USB-C dock, if available → confirm the 10 s settle timeout
      is enough. Tune the default if not.
- [ ] Clamshell: close lid docked, open lid → correct behaviour, no double prompt.
- [ ] Wake and immediately start typing → automatic mode downgrades to a prompt.
- [ ] Two displays of the same model → confirm UUIDs differ and matching is stable.
- [ ] Automatic mode, wake without any input after the environment trigger → the
      matching layout restores without a prompt.
- [ ] Wake using a key or trackpad, then provide no further input → record whether
      the wake event precedes the trigger and confirm automatic mode still fires.
- [ ] Provide keyboard or pointer input after the trigger, including during a slow
      dock settle → automatic mode always downgrades to a prompt.
- [ ] Unlock with both password and Touch ID → the unlock itself does not cause a
      false downgrade; input after unlock still does.
- [ ] Cause a late display-reconfiguration wave after a prompt appears or before
      automatic restore commits, ending on the same topology → the invalidated
      offer is made again exactly once after the new settle.
- [ ] With a slow/DisplayLink dock, watch diagnostics for a temporarily incomplete
      display UUID mapping. If observed, confirm Perch stays fail-closed, retries
      once, and either offers after identity becomes complete or records a final
      skipped decision without looping (the forced nil path is covered by tests).
- [ ] Force a restore-shortcut registration collision → the prompt remains clickable
      but does not advertise the unavailable shortcut.
- [ ] Quit during a committed automatic restore → termination waits for the normal
      restore result rather than silently cancelling a partially moved layout.

---

# Phase 2 — Live layouts (auto-save)

Do not start Phase 2 until Phase 1 has been dogfooded for at least a week. R1 is
the reason: a bug here destroys user data silently.

## Task 2.1: Live layout store

**Files:**
- Modify: `Perch/Models/Slot.swift` (`SlotStoreDocument`)
- Modify: `Perch/Models/SlotStore.swift`

**Interfaces produced:**

```swift
struct LiveLayout: Codable, Equatable, Sendable {
    var topology: DisplayTopologyFingerprint
    var capturedAt: Date
    var windows: [WindowSnapshot]
}

struct SlotStoreDocument {
    // ...existing...
    /// Automatically maintained snapshots, keyed by topology identity.
    /// Never shown as user layouts; never merged with `slots`.
    var liveLayouts: [String: LiveLayout]
}
```

**Steps:**

- [ ] Keyed by `DisplayTopologyFingerprint.identity` (R2). Storing the full
      fingerprint inside the value as well makes diagnostics readable.
- [ ] Cap the dictionary at **8 entries**, evicting the oldest `capturedAt`.
      Someone who visits many offices should not grow the file forever.
- [ ] Validate live layouts with the same window-frame checks as slot windows.
- [ ] `liveLayouts` is additive within schema v3 — no further version bump if
      Phase 1 already shipped v3. If Phase 1 has not shipped, fold this in.

## Task 2.2: Auto-save engine

**Files:**
- Create: `Perch/Core/LiveLayoutRecorder.swift`
- Create: `PerchTests/LiveLayoutRecorderPolicyTests.swift`
- Modify: `Perch/Models/Slot.swift` (`PerchSettings`)

**Interfaces produced:**

```swift
struct PerchSettings {
    // ...existing...
    var liveLayoutsEnabled: Bool        // default false until dogfooded
    var liveLayoutInterval: TimeInterval // default 60, range 15...600
}

@MainActor
final class LiveLayoutRecorder {
    init(slotEngine: SlotEngine)
    func start()
    /// Blocks capture until explicitly resumed. Called on every environment
    /// change trigger.
    func suspend(reason: String)
    func resume()
}
```

**Capture triggers:** a repeating timer at `liveLayoutInterval`, plus
`NSWorkspace.willSleepNotification` and `screensDidSleepNotification`.

**Steps:**

- [ ] **R1 is implemented here and nowhere else.** `suspend()` is called by
      `AutoRestoreCoordinator` the instant *any* environment trigger fires —
      before `waitForStable`, not after. `resume()` is called only after the
      coordinator's decision has been made **and** 30 s have elapsed with no
      further trigger. A suspended recorder must drop timer ticks entirely, not
      queue them.
- [ ] The `willSleep` capture is the valuable one and it is racing the system.
      Capture synchronously enough to finish, but never block sleep for more
      than ~1 s. `NSSupportsSuddenTermination` is already false, which helps.
      If the capture does not complete in time, skip it — the last timer capture
      is a good enough fallback. Do not write a partial snapshot.
- [ ] Write only under the key for the topology present **at capture time**
      (R2). Recompute the topology at capture; never trust a cached value.
- [ ] Skip capture entirely if `captureCurrentWindows` throws
      `incompleteAccessibilityRead` — the existing behaviour of refusing partial
      captures is correct and must be preserved here.
- [ ] Skip capture if fewer than 2 windows are found. A single-window capture is
      almost always a transient state, and overwriting a good layout with it is
      the worst possible outcome.
- [ ] Extract the "should I capture now?" decision into a pure, testable
      function taking (suspended, lastCaptureAt, now, windowCount, topology,
      existingEntry) so the guards above are covered by unit tests.

## Task 2.3: Prefer live layouts in the policy

**Files:**
- Modify: `Perch/Core/AutoRestorePolicy.swift`
- Modify: `PerchTests/AutoRestorePolicyTests.swift`

**Steps:**

- [ ] Extend `AutoRestoreInput` with `liveLayouts: [String: LiveLayout]`.
- [ ] Insert between current steps 4 and 5: if a live layout exists for the
      current topology identity and is **newer** than any matching user slot,
      offer it. Name it in the prompt as "your last arrangement" rather than a
      layout name.
- [ ] A user layout saved more recently than the live snapshot wins — an
      explicit user action should always outrank an automatic capture.
- [ ] Tests for the precedence rules in both directions.

## Task 2.4: Onboarding and honesty

**Files:**
- Modify: `Perch/UI/Settings/GeneralSettingsTab.swift`
- Modify: `../../README.md`
- Modify: `../../SUPPORT.md`

**Steps:**

- [ ] Live layouts are opt-in on first run with one clear sentence explaining
      what gets recorded and that it never leaves the Mac.
- [ ] Add a "Forget recorded arrangements" button that clears `liveLayouts`.
- [ ] Update the repository README and SUPPORT documentation with the caveat
      that automatic restore is best-effort and depends on the display
      arrangement being recognised. Never claim "100% reliable" or "works
      with every app".

---

## 5. Explicitly out of scope

- **Spaces / virtual desktops.** Still unsupported, still requires private API.
  Automatic restore does not change this. `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`
  sees only the active Space, so live captures have the same blind spot as
  manual ones. Do not let this feature grow into a Spaces project.
- **Fullscreen and minimised windows on capture.** Unchanged — still skipped.
- **Per-application rules or exclusions.** Separate feature.
- **Restoring windows to a display that is not connected.** Existing fallback
  behaviour (largest-intersection, then nearest display) applies unchanged.

## 6. Risk register

| Risk | Mitigation |
|---|---|
| Auto-save overwrites a good layout with a post-wake scrambled state | R1, enforced in `LiveLayoutRecorder.suspend/resume` + the 2-window minimum |
| Settle timeout too short for slow docks | Configurable, default 10 s, logged on every trigger so user reports are diagnosable |
| Prompt is annoying | Once per topology change, auto-dismiss, fully disableable, never steals focus |
| Topology matching too strict, feature silently never fires | R3 — identity by UUID set, not bounds; menu bar shows the last decision |
| Automatic mode fights the user | R4 — downgrade to prompt on recent input |
| Distributed notification breaks under sandboxing | Comment in `EnvironmentChangeObserver`; Perch is intentionally unsandboxed |

## 7. Definition of done for Phase 1

- All Task 1.x steps checked.
- `PerchModelTests` green in CI; new tests for topology identity, schema
  migration, settings validation, and every `AutoRestorePolicy` branch.
- Task 1.8 manual checklist completed on real hardware with two displays.
- Default `autoRestoreMode` is `.prompt`. Upgrading users get the prompt without
  any action, and nothing moves without their confirmation.
- Release notes state plainly what is automatic and what is not.
