# Perch 0.2.2

This release improves automatic restore after login, wake, and display changes.

- Perch now checks for a matching saved layout when it starts, including when
  macOS has already sent its login notifications. Launch at login must still
  be enabled and approved in macOS.
- Restore waits for an unlocked session and settled displays, handles late
  wake notifications, and retries windows that running apps are still opening.
- Changes to restore mode or saved layouts are checked again before windows
  move. Keyboard or pointer activity makes Automatic mode ask first.
- Application launch requests have a timeout, so a missing system response
  cannot leave restore waiting indefinitely.
- If saved layouts cannot be read, a persistent notice links to the preserved
  originals. Dismissing it keeps those files available for recovery.
- Settings report failed saves and refresh login-item and permission status.
- Sparkle is updated to 2.9.6, and diagnostic error details and system logging
  better protect local information.
- Internal modules, tests, and release tooling have been reorganized and cleaned up.

Perch restores explicitly saved layouts. It does not automatically save your
latest arrangement or recreate documents and tabs from a previous session.
