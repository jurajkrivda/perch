# Automatic restore: behavior and verification

Current implementation, updated September 7, 2026. Persistence remains schema
v3. This replaces the historical implementation checklist; older plans remain
in Git history. Physical restart/dock verification for the audit fixes is pending.

## User contract

Perch restores an explicitly saved layout. It does not continuously record the
current arrangement, restore unsaved documents, or recreate a previous session's
tabs. An explicit preference wins among nonempty layouts matching the connected
displays; otherwise the most recently saved nonempty matching layout wins. Empty
placeholders never hide a usable layout. Preferences belong to one display
identity and do not follow a layout saved on a different display arrangement.

Modes:

- **Off:** environment events do not restore or offer a layout.
- **Ask:** after startup, wake or a changed display arrangement, offer the matching
  layout once the session is visible and displays have settled.
- **Automatic:** restore without confirmation after unlocking and display settling,
  including while the user types, scrolls, or moves the pointer.

**Launch at login** must be registered and approved in macOS for Perch to run
after a computer restart. Accessibility permission is separately required for
capture and restore. A successful registration request alone does not prove that
macOS has granted login-item approval.

Closed applications stay closed unless **Open missing applications** is enabled.
Already-running applications can take time to create their windows, so retrying
those windows is independent of the setting that launches closed applications.

## Event pipeline

1. Startup explicitly schedules an evaluation. It does not wait for a session
   notification that may have occurred before the app launched.
2. Sleep, display sleep, locking and switching away from the session hide it and
   cancel uncommitted work. Wake and startup intent survives until the session
   is visible. An unavailable session dictionary is not treated as an unlock.
3. Wake/unlock visibility confirmation polls for at most 30 seconds. A later
   system event can resume deferred work after that bound.
4. Display changes coalesce into a quiet interval of 2 seconds, followed by a
   1.5-second window-relocation grace period. The configurable settle timeout
   defaults to 10 seconds. A timed-out automatic settle defers restoration; it
   does not claim the environment was stable.
   The saved timeout is loaded before the first startup wait as well.
5. The coordinator requires complete display identity. An incomplete topology
   gets one additional evaluation after 3 seconds, without an infinite loop.
6. Startup and a new sleep/wake cycle may evaluate even if display identity is
   unchanged: macOS can still have moved windows. Duplicate wake signals in one
   observed sleep cycle and no-op unlock/display callbacks do not create a new
   completed offer for the same topology.
7. Policy matches the set of display UUIDs and the main display, ignoring bounds.
   It chooses the preferred matching layout, or the most recently saved usable
   match, and checks the selected mode.
8. Immediately before automatic or prompt-confirmed movement, the engine loads
   a fresh document. The coordinator checks the current mode, layout eligibility,
   event generation, session and topology again.

Invalidating a prompt makes its stale confirmation callback ineffective. Turning
the mode off dismisses an outstanding offer. New display events invalidate an
uncommitted attempt and can offer again after the new settling window.
Switching an outstanding offer from Ask to Automatic dismisses it and restores
the current matching layout without a click, provided the session and display
configuration are still ready. Changing modes does not permit a hidden or
unsettled restore, and stale offer callbacks cannot start a second operation.
Changing the preferred layout replaces an outstanding offer or uncommitted
automatic attempt; its old confirmation cannot restore the previous choice.

## Window-operation invariants

- Capture refuses incomplete AX reads and a topology change during capture.
  Existing saved data is preserved on failure or cancellation.
- The same engine operation and report serve the menu, shortcut and automation.
  Exclusive access prevents overlapping saves/restores.
- A batch reserves each matched live window for one snapshot. Delayed-window
  retries retain successful matches and do not move a completed window again
  unless the display topology changed.
- Retries use a monotonic 8-second per-application polling deadline, with one
  final topology remap allowed after that deadline. Continual display changes
  cannot extend polling forever or produce success against an obsolete topology.
- Waiting for an application-launch callback is limited to 10 seconds and is
  cancellable. Late callbacks cannot resume window restoration, although macOS
  may still finish opening the application after that timeout.
- A committed automatic restore finishes and reports partial failures even if a
  later event arrives. The user can explicitly stop remaining work from the menu
  or progress window; completed moves remain reported and can be undone. Quitting waits for that operation. Individual OS calls
  are external dependencies; the polling deadline is not a global quit deadline.
- Layout selection uses tolerant identity; remapping and capture consistency
  use full display geometry. These comparisons serve different purposes.

## Report actions and undo

The shared in-memory `RestoreSession` streams verified progress for menu, hotkey,
settings, and automatic restores. Manual restores open the progress window;
automatic restores remain unobtrusive in the menu bar.

- Retry uses the original saved layout and refuses changed window data or display
  geometry. Successful siblings participate only as exact reservations and never
  move again during a user retry, including topology remaps within that retry.
- A per-window open-and-retry action may launch that window's app for this attempt
  without changing the global automatic-launch preference.
- Reassignment captures currently open windows, validates the choice again, and
  changes only a saved window's identity. Destination geometry is preserved.
- Undo records original frames before writing, including partially completed
  writes. It requires the same complete display geometry and uses exact live
  process/window reservations, never a title fallback or an app launch.
- Undo remains in memory until the next full restore or process exit. Successful
  undos are removed; unavailable windows remain eligible for another undo attempt.

## Diagnostics

The menu shows the last decision. Diagnostics export includes the trigger and
decision code, login-item status and Accessibility state, without layout names
or window titles. Decision codes are also recorded at info level in the system
log. The report can explain a skipped decision but cannot prove that a physical
dock completed every stage of its reconnection.

## Hardware verification before release

Automated tests cover the state transitions with simulated OS events. Record
actual results for this matrix on an installed, signed build before releasing:

| Scenario | Expected result | Status |
|---|---|---|
| Cold boot with login item enabled; dock already attached | One startup evaluation after visible login and stable displays | Pending |
| Login item disabled or requiring approval | No promise of auto-launch; settings/diagnostics show the status | Pending |
| Wake with unchanged displays, both laptop-only and docked | One restore opportunity per sleep cycle | Pending |
| Late screen-wake notification following system wake | No duplicate completed offer for the same arrangement | Pending |
| Locked screen, password unlock, Touch ID, fast-user switching | No hidden prompt expiry or uncommitted movement behind locked UI | Pending |
| Type, scroll, or move the pointer while displays settle | Automatic restores without confirmation; Ask still waits for confirmation | Pending |
| Slow USB-C/DisplayLink dock, disconnect/reconnect, clamshell | Correct final layout; stale prompts cannot restore | Pending |
| Change resolution, main display or arrangement; two identical monitor models | Correct identity selection and frame remapping | Pending |
| Apps already running with delayed windows; closed apps with opening off/on | Retry existing windows; launch only when enabled | Pending |
| Window minimized/fullscreen at restore time; app refuses resizing | Accurate verified result and partial-failure report | Pending |
| Quit after automatic restore commits | Committed operation finishes and quit completes | Pending |
| macOS 14 minimum; Intel hardware | Same contract on supported minimum OS and architecture | Pending |

Spaces remain outside the capture contract. Automatic saving of live layouts is
a separate future feature and is not implemented by this pipeline.
