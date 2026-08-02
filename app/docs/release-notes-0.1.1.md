# Perch 0.1.1 Release Notes

Reliability, localization, and polish release based on a full technical
audit; no data or settings migration is required.

## Languages

- Perch now speaks Czech, Slovak, English, Spanish, and German.
- A Language picker in General Settings switches the whole UI immediately —
  settings, menu bar, toasts, and restore reports — without restarting.
- The default `System` option follows the macOS preferred language and falls
  back to English.

## Reliability

- An unresponsive app can no longer freeze Perch: every Accessibility request
  is now capped at one second instead of the multi-second system default.
- Pressing a save or restore shortcut while a restore is still running no
  longer starts a second overlapping operation.
- `Restart Perch` now waits for the old instance to exit before relaunching,
  so the restart can no longer race itself and leave Perch closed.
- Display configuration changes are tracked from launch, so the first restore
  after connecting or disconnecting a monitor waits for a stable layout.
- Capture and restore now resolve a window's display with the same rule
  (largest visible intersection), so edge-straddling windows round-trip
  consistently.

## Interface

- The Settings window follows a light/dark mode switch while it is open.
- Shortcuts recorded on function keys, arrow keys, the navigation cluster,
  and punctuation now display readable names instead of `Key 122`.
- Resetting the Accessibility permission no longer briefly blocks the UI.

## Privacy

- Layout names and window titles no longer appear in the public unified log;
  they were already excluded from exported diagnostics.

## Known Limitations

- Perch requires macOS Accessibility permission.
- Fullscreen and minimized windows are skipped when saving layouts.
- Some apps expose limited Accessibility metadata, so exact restore matching
  may be best effort.
- Multi-display restore is best when the saved display is connected;
  otherwise Perch falls back to the closest available display.
- macOS or another app may reserve a shortcut. Perch shows unavailable
  shortcuts in the menu when registration fails.
