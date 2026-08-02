# Perch 0.1.0 Release Notes

Initial public release candidate.

## Highlights

- Save named macOS window layouts from the menu bar.
- Restore layouts with menu actions or global keyboard shortcuts.
- Create, rename, and delete layouts in Settings.
- Configure custom restore shortcuts per layout.
- Launch apps during restore when a saved app is not currently running.
- Show restore summaries when some windows cannot be restored.
- Support launch at login and icon-only menu bar mode.
- Export redacted diagnostics for support.

## Known Limitations

- Perch requires macOS Accessibility permission.
- Fullscreen and minimized windows are skipped when saving layouts.
- Some apps expose limited Accessibility metadata, so exact restore matching may be best effort.
- Multi-display restore is best when the saved display is connected; otherwise Perch falls back to the closest available display.
- macOS or another app may reserve a shortcut. Perch shows unavailable shortcuts in the menu when registration fails.
