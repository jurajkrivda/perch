# Perch 0.2.2 release verification

Date: September 7, 2026. This is the build 6 candidate, superseding the
unpublished build 5. Public release remains pending protected-branch review.

## Artifact

- Version: `0.2.2`, build `6`; minimum macOS `14.0`.
- Bundle ID: `com.jurajkrivda.perch`.
- Universal app: `arm64` and `x86_64`.
- Developer ID team: `VFFR3HLW27`; hardened runtime enabled.
- DMG SHA-256: `4f09e33f9de891d05ae09362b67191b6ff2df678c4095a9e0d51e683ac240c77`.
- DMG size: 4,538,860 bytes.
- App notarization: `014b0b4b-2fb1-44e1-b9fd-630833b1949f`, Accepted.
- DMG notarization: `c5ffe1b8-2f9a-491c-a1b9-e671ec1230d9`, Accepted.
- Stapler validation, deep strict code-signature verification, and Gatekeeper
  assessment passed.
- Read-only DMG mounting verified version/build, Applications shortcut, LICENSE,
  NOTICE, and the Sparkle license. The installed executable matches the DMG.
- The DMG retains the previous release's Finder layout metadata; packaging did
  not require interacting with Finder.
- Local appcast generation and verification passed: build 6, version 0.2.2,
  immutable enclosure URL, length, and EdDSA signature.

## Automated tests

- 220 tests passed with zero failures on Apple Silicon, macOS 26.6.2, Xcode 26.5.
- Includes 18 integration tests for automatic restore, settings transitions,
  locked sessions, delayed display events, stale prompts, and preflight changes.
- The mode contract is tested for every eligible trigger: Automatic restores
  without confirmation, Ask waits for confirmation, Off does nothing.
- The new Ask-to-Automatic test first reproduced an outstanding prompt that
  failed to restore. It passes after the fix, and the stale callback cannot
  start a duplicate restore.
- A mode change while locked or with changed display geometry must still wait
  for visibility and settling. Off updates the last decision as well as closing
  the outstanding offer.
- Debug and Release universal builds, repository hygiene, regenerated Xcode
  project, and `git diff --check` passed.
- Unit tests use temporary stores and substituted OS/window boundaries. The live
  check below separately exercises the installed signed application.

## Installed application

- The previous application and saved data were backed up before replacement.
- Build 6 is installed at `/Applications/Perch.app`; Accessibility remains trusted.
- At 16:57:59 CEST the installed app started with Automatic selected. A read-only
  timing probe confirmed keyboard/pointer activity during the settling interval;
  it collected elapsed seconds only, without key contents or pointer positions.
- At 16:58:03 the app recorded a `restore` decision for `applicationLaunch`,
  without a confirmation prompt. Restoration completed at 16:58:19.
- It restored 6 of 11 saved windows. Two saved applications were closed, two
  matches were ambiguous, and one window was absent. Those cases were reported
  as partial failures rather than guessed or silently counted as successful.
- The saved-layout file remained byte-identical. Earlier build 5 artifacts and
  the replaced application remain in local backups.

## GitHub and remaining checks

- [PR #5](https://github.com/jurajkrivda/perch/pull/5) contains the release changes;
  its current checks provide the remote CI result for the latest commit.
- The draft GitHub Release must contain only the build 6 `Perch.dmg`, with the
  SHA-256 and size above. Publish after branch approval, then verify the immutable
  release and deployed Sparkle feed.
- Physical cold boot, sleep/wake and dock changes, minimum macOS 14 and Intel
  runtime remain outside completed live verification. See the
  [hardware matrix](auto-restore-brief.md#hardware-verification-before-release).
- Native Perch inspection through Computer Use is unavailable. Visual layout,
  VoiceOver, and the full interactive Sparkle upgrade path are not claimed as
  verified by these runtime logs.
