# Perch architecture

Perch is a Swift 6 menu bar application for macOS 14 and later. XcodeGen's
`project.yml` is the source of truth for targets and dependency versions. Keep
the generated Xcode project and `Package.resolved` checked in so Xcode and CI
can build without first installing XcodeGen.

## Responsibilities

| Module | Owns | Does not own |
|---|---|---|
| `PerchApp` | Process lifetime, single-instance lock, service composition, hotkey refresh | Matching or restore policy |
| `SlotStore` actor | Serialized read/modify/write, validation, schema migration, private file permissions, quarantine and recovery notices | Window operations or UI |
| `SlotEngine` and extensions | Layout capture, repair, preference/history operations, exclusive restore/retry/undo, final preflight | AX matching |
| `RestoreSession` | Observable progress, partial reports, exact live reservations and in-memory undo frames | Persistence |
| `LayoutHistory` | Valid previous layouts, private revision files, bounded retention | Moving windows |
| `LayoutWindowRestorer` | Application grouping, optional launch, delayed-window retry, reservations and topology remapping | AX attribute decoding |
| `WorkspaceApplicationLauncher` | OS application launch, bounded callback wait and cancellation | Window discovery or movement |
| `WindowSnapshotter` actor | Consistent capture of eligible visible windows | Saving the document |
| `WindowMover` actor | AX candidate discovery, live process identity, verified moves | Choosing when an automatic restore is appropriate |
| `WindowMatcher` / `WindowTitleSimilarity` | Pure one-to-one matching and title scoring | Calling Accessibility APIs |
| `AccessibilityValues` / `CGWindowCatalog` | Shared AX decoding and CG/AX correlation | Restore orchestration |
| `WindowGeometry` / `DisplayManager` | Target frames, coordinate conversion, physical display identity | Selecting a saved layout |
| `EnvironmentChangeObserver` / `DisplayStabilizer` | Session, sleep and display signals; coalescing; monotonic settling | Selecting or restoring a layout |
| `AutoRestorePolicy` | Pure decision from settings, topology and saved layouts | Timers or UI |
| `AutoRestoreCoordinator` | Attempts, generation validity, commit boundary and presentation through `AutoRestorePresenting` | AX calls |
| `MenuBarController` and extensions | Menu actions, layout management, prompt/toast/report presentation | Persistence implementation |
| `SettingsModel` | UI loading, serialized optimistic writes, errors and stale-task protection | Owning a second live store |
| `Localization` | Typed keys, five language catalogs, runtime language changes | Window behavior |

The extensions separate parts of an existing actor/controller by responsibility;
they share the same owner and lifetime. Stateless matching, decoding and geometry
have separate value-based interfaces. Protocols exist at OS and UI boundaries
used by tests, rather than around every small helper.

## Concurrency and operation boundaries

AppKit UI, the coordinator and `SlotEngine` run on the main actor. Blocking AX
capture/move work runs on dedicated actors. `SlotStore` is a separate actor;
its update closure completes within one actor turn. The application shares one
live `SlotEngine`, including settings and diagnostics.

Capture, repair, restore, retry and undo operations are mutually exclusive. Later requests fail with
`operationInProgress` instead of accumulating a queue of repeated hotkeys.
Settings writes can still complete while a restore is waiting for displays.

An automatic restore re-reads the document and validates mode, layout, session,
generation and topology immediately before committing. Before
commit, newer events can cancel it. After commit, the operation finishes and
reports its result; quitting waits for that committed operation. Explicit user
cancellation propagates to the managed restore task, preserving progress and undo
for writes already attempted. Each application
launch callback has a 10-second deadline and responds to task cancellation.
Late callbacks cannot resume the operation again. Launch Services may still open
the application later. Window polling has its own deadline; there is no single
global deadline across all application groups and synchronous AX calls.

Automatic mode never requires confirmation because of keyboard or pointer input.
The policy has no input-activity dependency. Switching a pending offer from Ask
to Automatic invalidates its old callback and re-evaluates the current saved
layout. Hidden or changed displays still require the observer's settling path.
Switching to Ask before commit creates an offer; switching to Off cancels it.

Saving checks topology before and after capture. A changed configuration or
incomplete AX read rejects the save without replacing the previous layout.
Saving with consistently unavailable topology retains manual restore support
but leaves the layout ineligible for automatic matching until it is saved again.

## Persistence and privacy

`slots.json` remains schema v3. Display UUIDs and main-display identity select
automatic layouts; exact bounds support diagnostics and remapping. Window IDs
are trusted only with matching process identity. Names and titles are local
metadata and must not be interpolated into public system logs or diagnostics.
Diagnostic exports intentionally retain bundle IDs, layout IDs and display
geometry; they are redacted, not anonymous.

`StoreRecoveryFiles` discovers quarantined originals from current and older builds.
Pending notices remain visible in the menu and settings across app launches.
Acknowledgement renames only the originals included in that notice with an
`.acknowledged` suffix, preserving contents and permissions. It does not hide a
new corruption incident. Valid previous layout versions can be recovered through Settings without moving
windows. `LayoutHistory` keeps at most ten versions per layout and one hundred
in total, including deleted layouts. Each capture change is backed up before the
live document is replaced; a failed backup prevents the replacement. Settings-only
writes do not create revisions. Recovered existing layouts keep current names and
shortcuts; recovered deleted layouts receive no shortcut, avoiding conflicts.
The preference map is optional in schema v3 settings and defaults to empty for
older files. Its physical display UUID keys are removed from diagnostic exports.

## Verification and maintenance

From `app/`:

```sh
python3 script/check_repository.py
xcodebuild test -project Perch.xcodeproj -scheme PerchModelTests -destination 'platform=macOS'
```

The test target compiles all reusable application code, without the application
entry point. Real observer/coordinator/store/engine integration tests inject
notification centers, session state, presentation and window operations. Pure
tests cover matching, geometry, topology, policy, migrations and validation.

Swift source and test files have a 500-line maintenance guardrail in CI. Split
by behavior and ownership; moving arbitrary line ranges into extensions is not
enough. The same check catches exact duplicate Swift files, malformed shell
scripts and inconsistent Sparkle pins/licenses. After adding or moving sources,
regenerate with `xcodegen generate`, then build Debug and Release.

The [automatic restore contract](auto-restore-brief.md) describes timing and the
hardware matrix. The [September 2026 audit](audit-2026-09-07.md) records findings,
validation and remaining limitations.
