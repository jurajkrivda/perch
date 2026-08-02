# Perch 0.1.0 Release Verification

Date: May 22, 2026

## Metadata

- Version: `0.1.0`
- Build: `1`
- Bundle ID: `com.jurajkrivda.perch`
- Minimum macOS: `14.0`
- Signing identity: `Developer ID Application: Juraj Krivda (VFFR3HLW27)`

## Artifacts

- `dist/release/Perch.app`
- `dist/release/Perch.zip`
- `dist/release/Perch.dmg`

## Checksums

```text
1c37ce3208d894f1c07baa183a3e7b40615ec2e1928c119bcc16b813ff5a187b  dist/release/Perch.dmg
d37c0d9eeac0678b65e14cc6f2057ff7df0191f76ae4a6a0aee92b9dbc9abe65  dist/release/Perch.zip
```

## Automated Verification

- `xcodebuild test -project Perch.xcodeproj -scheme PerchModelTests -destination 'platform=macOS' -derivedDataPath build/DerivedData`
- `xcodebuild analyze -project Perch.xcodeproj -scheme Perch -destination 'platform=macOS' -derivedDataPath build/DerivedData`
- `./script/build_and_run.sh --verify`
- `PERCH_NOTARY_PROFILE=perch-notary ./script/build_dmg.sh notarize`
- `xcrun stapler validate dist/release/Perch.dmg`
- `spctl -a -vv -t open --context context:primary-signature dist/release/Perch.dmg`
- `spctl -a -vv dist/release/Perch.app`
- `codesign --verify --strict --deep --verbose=4 dist/release/Perch.app`
- DMG mount smoke test with `Perch.app` accepted by Gatekeeper from the mounted volume.
- Non-destructive `/Applications` launch smoke test using `/Applications/Perch Release Test.app`, then removing the test copy.

## Notarization

- Zip submission: `583787bb-d8cb-4a91-b36f-3dc0c53b30da`, status `Accepted`
- DMG submission: `c19e2e25-f7ee-452a-a81f-f660e8124b44`, status `Accepted`

## Manual Checks Still Required

- Fresh install as `/Applications/Perch.app` if replacing the existing installed copy is intended.
- Grant Accessibility permission to the final installed app path.
- Smoke test saving and restoring a real layout with at least two apps.
- Smoke test restore after quitting and reopening one captured app.
- Smoke test multi-display disconnect/reconnect behavior on the target support matrix.
