# Perch

**Save your window layout. Get it back after your Mac wakes up.**

Perch is a small macOS menu bar app that remembers where your windows were and
puts them back — manually with a shortcut, or automatically after your Mac wakes
from sleep or your displays change.

macOS has no built-in way to do this. If you use a MacBook with external
displays, you already know the problem: you put the machine to sleep with a
carefully arranged workspace, and when it wakes, everything has been dumped onto
the built-in screen and scattered again once the external displays reconnect.

Perch is free and open source under the Apache License 2.0.

[Download the latest `Perch.dmg`](https://github.com/jurajkrivda/perch/releases/latest/download/Perch.dmg) ·
[All releases](https://github.com/jurajkrivda/perch/releases) · [Support](SUPPORT.md)

---

## What it does

- **Named layouts.** Save the current arrangement of your windows under a name,
  restore it later from the menu bar or a global shortcut.
- **Automatic restore.** When your Mac wakes or your display arrangement
  changes, Perch waits for things to settle and offers to restore the layout
  saved for that arrangement. It asks by default — nothing moves without your
  confirmation. Fully automatic mode is available if you prefer it.
- **Multiple displays.** Layouts remember which physical display each window
  belonged to, by display UUID, so a window goes back to the right screen even
  if the arrangement shifted.
- **Reopen closed apps.** Optionally, Perch can launch applications that aren't
  running and restore their windows once they appear. Off by default.
- **Quiet.** Menu bar only, no dock icon, launches at login if you want.
- **Five languages.** Czech, Slovak, English, Spanish, German.

## What it deliberately does not do

Being straight about this up front saves everyone time.

- **No Spaces support.** Perch only sees windows on the active Space. macOS
  offers no public API for windows on other desktops, and the private one isn't
  worth the maintenance risk. Windows on other Spaces are neither saved nor
  restored.
- **Minimized and fullscreen windows are skipped when saving.** They are valid
  targets when restoring — Perch will pull a window back out of fullscreen or
  un-minimize it to put it where it belongs — but it won't record one.
- **Window matching is best effort.** macOS gives windows no stable identifier
  that survives an app restart. Perch matches on a cascade of signals (window
  ID, accessibility identifier, exact title, fuzzy title, position) and gets it
  right most of the time. Applications with poor accessibility metadata are
  harder, and Perch tells you in the restore report when it had to guess.
- **It is not a tiling window manager.** No snap zones, no keyboard-driven
  halves and thirds. If that's what you want, look at
  [Rectangle](https://rectangleapp.com).

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon or Intel
- Accessibility permission (Perch moves windows through the Accessibility API;
  there is no other way to do it)

## Install

1. [Download the latest signed and notarized `Perch.dmg`](https://github.com/jurajkrivda/perch/releases/latest/download/Perch.dmg).
2. Open the DMG and drag Perch to Applications.
3. Launch Perch and grant Accessibility permission when macOS asks.

The direct download always follows the newest GitHub Release. Maintainers must
therefore attach the DMG under the exact filename `Perch.dmg` in every release.

Perch checks for signed updates through
[Sparkle](https://sparkle-project.org). GitHub Releases hosts the install DMG;
GitHub Pages hosts only the signed Sparkle feed. Update downloads come from the
matching tagged GitHub Release.

## Privacy

Everything stays on your Mac. Layouts and window metadata are stored in
`~/Library/Application Support/Perch/slots.json`. There is no analytics,
telemetry, or account, and no layout or window metadata leaves your Mac. Network
access is used only for checking for updates.

See the complete [privacy policy](app/docs/privacy-policy.md).

Window titles are recorded locally as part of matching, and are deliberately
kept out of the system log.

---

## How it works

The interesting part of Perch isn't moving windows — that's a handful of
Accessibility API calls. It's deciding **which** window is which.

macOS gives you no persistent window identity. `CGWindowID` dies when the app
restarts. Titles change as you work. Two Chrome windows are indistinguishable
from the outside. So restoring a layout is fundamentally a matching problem
between the windows you saved and the windows that exist now, and it has to be
1:1 — the failure mode people actually notice isn't a window landing slightly
off, it's two windows swapping places.

Perch matches with a cascade of decreasing confidence:

1. **Reservation** — a window already claimed by another snapshot in this batch
   is off limits, so two windows of the same app can never trade places.
2. **`CGWindowID`**, if the owning process is provably the same one that was
   captured (pid *and* launch date).
3. **`AXIdentifier`**, where the app provides one.
4. **Exact title**, then **fuzzy title** (token overlap plus edit distance, with
   a minimum score and a required margin over the runner-up).
5. **Frame proximity**, within a threshold.
6. **Single candidate** — if the app has exactly one window, it's that one.

Perch uses a balanced fuzzy-matching policy. The restore report tells you which
rule matched each window, so when something lands wrong you can see why.

The other genuinely hard part is timing. Displays don't come back all at once;
a DisplayLink dock can take five seconds and arrive in waves. Restoring too
early means writing positions into an arrangement that's about to change. Perch
watches for display reconfiguration events and waits for a quiet period before
touching anything.

The [automatic restore implementation brief](app/docs/auto-restore-brief.md)
documents the failure modes, policy, and hardware verification matrix.

## Building

Requires Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
cd app
xcodegen generate
open Perch.xcodeproj
```

The project is Swift 6 with `strict concurrency: complete`. Window capture and
window moving are actors, so blocking Accessibility calls never run on the main
actor — an unresponsive app can't freeze the menu bar.

Tests:

```
xcodebuild test -project Perch.xcodeproj -scheme PerchModelTests -destination 'platform=macOS'
```

The test target compiles the model plus testable core policy and state types,
without launching the AppKit UI. Matching rules and auto-restore decisions are
kept as pure logic so they can run without a window server.

## Repository layout

```
app/    the macOS application, tests, release scripts, and documentation
```

## Contributing

Issues and pull requests are welcome, with one honest caveat: this is a side
project maintained in spare time. Please read [SUPPORT.md](SUPPORT.md) before
opening an issue so you know what to expect.

## License

Perch is licensed under the [Apache License 2.0](LICENSE). Third-party
attribution is recorded in [NOTICE](NOTICE).
