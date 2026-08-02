# Perch 0.2.0 Release Notes

Automatic restore after wake and display changes, with conservative defaults.

Perch is now free and open source under the Apache License 2.0.

## Automatic Restore

- Perch now recognises wake, unlock, and display configuration changes, waits
  for the displays to settle, and looks for the newest saved layout that
  belongs to the connected display arrangement.
- The default `Ask Me` mode never moves windows on its own. It shows a
  non-activating prompt that can be confirmed with one click or the layout's
  existing restore shortcut.
- The opt-in `Automatic` mode restores the matching layout without a prompt.
  If Perch detects recent keyboard or mouse activity, it asks first instead of
  moving windows while the Mac is in use.
- Automatic restore can be disabled completely. An advanced setting controls
  how long Perch waits for slow displays or docks to settle.
- The menu bar and exported diagnostics now show the last automatic-restore
  decision, making skipped restores easier to understand.

## Data Compatibility

- Saved layouts now include the display arrangement on which they were
  captured. Existing layouts remain valid, but must be saved again before
  they can be selected automatically.

## Known Limitations

- Automatic restore is best effort and only runs when Perch recognises the
  connected display arrangement and finds a layout captured for it.
- macOS Spaces and virtual desktops are not supported. Perch only sees windows
  on the active Space.
- Fullscreen and minimized windows are still skipped when saving layouts.
- Perch requires macOS Accessibility permission, and some apps expose limited
  Accessibility metadata.
- Restoring to a disconnected display continues to use Perch's existing
  closest-display fallback when a restore is started manually.
