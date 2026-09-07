# Perch 0.3.0

## Restore controls

- A live progress and results window shows individual saved windows, completed
  work, the application currently being restored, and a stop action. Manual
  restores open it; automatic restores show progress in the menu bar.
- Retry all remaining windows or one failed window. Successfully restored
  siblings retain exact reservations and are not moved by a user retry.
- Open a closed application for one retry without changing automatic settings.
- Assign a currently open window to a saved destination when its identity can
  be distinguished. The destination stays unchanged and the old saved version
  is retained.
- Undo the most recent restore, including partial or interrupted writes. Undo
  requires the same display geometry and exact live windows; it never launches
  an application or substitutes a similarly named replacement window.

## Saved layouts

- Save Current Layout captures open windows and creates the layout together.
  Empty or failed captures do not leave a placeholder behind.
- Settings show save times, saved applications, and a display/window preview.
- Choose a preferred layout for each display arrangement. Saving another layout
  does not change that preference. Without a preference, the newest nonempty
  matching layout wins. Changing the preference replaces pending restore offers.
- Saved Versions keeps up to ten previous versions per layout and one hundred
  overall. Recover overwritten or deleted layouts without moving windows or
  changing unrelated settings and shortcuts.
- All new controls are translated into Czech, Slovak, English, German, and Spanish.

## Validation

253 automated tests pass locally, including the real automatic event pipeline,
preference changes before commit, cancellation during writes, exact-window undo,
partial retries, reassignment, private history retention and recovery after store
corruption. Debug and universal Release builds are checked before installation.

Physical cold boot, dock reconnect, VoiceOver and the final visual walkthrough
remain part of testing on the installed app. Window/session recreation and Spaces
are outside the restore contract. Undo is available only until another full
restore or Perch exits; saved version history persists across restarts.
