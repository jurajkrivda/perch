# Contributing to Perch

Thanks for helping improve Perch. Bug fixes and focused reliability
improvements are especially welcome.

## Before you start

- Read [SUPPORT.md](SUPPORT.md) for the project's scope and known limitations.
- Open an issue before starting a large behavioral change.
- Do not add private macOS APIs, analytics, telemetry, accounts, or hosted
  runtime dependencies.

## Development

Perch requires macOS 14 or later, Xcode 16 or later, and XcodeGen.

```sh
cd app
xcodegen generate
xcodebuild test -project Perch.xcodeproj -scheme PerchModelTests \
  -destination 'platform=macOS'
```

Keep pure policy and matching logic covered by unit tests. Changes involving
window movement, wake, displays, Accessibility permission, or global shortcuts
should also include the hardware and macOS versions used for manual testing.

Keep Swift source and test files under 500 lines by separating responsibilities.
Generated Xcode project files are exempt. Run `python3 script/check_repository.py`
from `app/` before submitting changes. Regenerate `Perch.xcodeproj` with XcodeGen
when adding or removing sources. Test sources are included by directory so new
reusable application code is compiled by the test target too.

## Pull requests

- Keep each pull request focused and explain the user-visible effect.
- Include tests for regressions where practical.
- Update README, SUPPORT, privacy, or release documentation when behavior
  changes.
- Confirm the app target builds and the complete test suite passes.

By contributing, you agree that your contribution is licensed under the
repository's [Apache License 2.0](LICENSE).
