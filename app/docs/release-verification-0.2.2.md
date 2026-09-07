# Perch 0.2.2 release verification

Date: September 7, 2026. Release preparation is in progress; this record does
not by itself indicate that a public release has been published.

## Artifact

- Version: `0.2.2`, build `5`; minimum macOS `14.0`.
- Bundle ID: `com.jurajkrivda.perch`.
- Universal app: `arm64` and `x86_64`.
- Developer ID team: `VFFR3HLW27`; hardened runtime enabled.
- DMG SHA-256: `526206723d9c64aa09920915bf86a3e5fb3a34893af12d7be173afeca569b2fa`.
- App notarization: `4eccaee4-2075-4a11-82f9-971a38a3e329`, Accepted.
- DMG notarization: `618059bd-bd6e-4e89-bc41-57e3dcec17fb`, Accepted.
- Stapler validation, deep strict code-signature verification, and Gatekeeper
  assessment passed for the distribution artifact.

## Automated tests

- 217 tests passed with zero failures on Apple Silicon, macOS 26.6.2, Xcode 26.5.
- Includes 15 integration tests for startup, wake, delayed display events,
  locked sessions, user interaction, stale prompts, and settings changes before
  automatic restore commits.
- Debug and Release builds, repository hygiene, project regeneration, and
  `git diff --check` passed.
- The test suite uses temporary stores and substituted OS/window boundaries.
  The live checks below exercise the installed signed application separately.

## Installed application

- The previous application and saved data were backed up before replacement.
- The notarized candidate was installed at `/Applications/Perch.app`.
- Accessibility remained trusted without resetting or changing permissions.
- Two controlled app starts recorded `applicationLaunch` after a visible
  session and settled displays. Both offered confirmation after detected user
  input. The resulting restores each moved 7 of 11 saved windows; one saved
  application was closed, two matches were ambiguous, and one window was absent.
- The saved-layout file remained byte-identical after these checks.
- An idle startup with no confirmation is still being checked before publication.

## Remaining release checks

- Remote CI and protected-branch review.
- Final GitHub Release, uploaded-asset verification, and Sparkle feed deployment.
- Physical cold boot, sleep/wake and dock changes, minimum macOS 14 and Intel
  runtime remain outside this machine's completed verification. The full matrix
  is in [automatic restore](auto-restore-brief.md#hardware-verification-before-release).
- Native UI inspection through Computer Use still times out for Perch; visual
  layout, VoiceOver, and the full interactive Sparkle upgrade path are not claimed
  as verified by the runtime logs.
