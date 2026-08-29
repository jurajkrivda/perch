# Perch 0.2.1 Release Notes

More reliable automatic restore prompts after wake and display changes.

## Automatic Restore Reliability

- The `Ask Me` prompt now appears on the display where you are working instead
  of being biased toward the built-in display.
- Perch verifies that the user session is visible before starting a prompt, so
  its 12-second confirmation window is not consumed behind the lock screen.
- Wake intent now survives late display and dock callbacks while Perch is
  deciding what to restore. This prevents a valid wake offer from being lost
  when the connected display arrangement has not changed.
- A temporarily unavailable screen configuration gets one bounded retry rather
  than silently dropping the restore offer.
- Automatic mode retains its original interaction safety window across late
  display callbacks and continues to ask before moving windows if you have
  already resumed using the Mac.

## Compatibility

- Saved layouts and settings are unchanged and remain compatible with 0.2.0.
- Perch still requires macOS 14 or later and Accessibility permission.
