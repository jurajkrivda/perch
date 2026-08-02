# Perch Release Checklist

Use this checklist for every public GitHub release.

## 0. One-time repository setup

- Verify that the public repository is `jurajkrivda/perch` and that `origin`
  points to it over either SSH or HTTPS.
- Review the canonical Apache License 2.0 `LICENSE` file and `NOTICE`.
- In **Settings → Pages**, select **GitHub Actions** as the source.
- In **Settings → General → Releases**, enable release immutability before the
  first public release. It protects future tags and assets and creates a
  verifiable release attestation.
- Add the raw Sparkle EdDSA private key as the Actions repository secret
  `SPARKLE_PRIVATE_KEY`. Never print it or store it in the repository.
- Keep a separate encrypted backup of the Sparkle key. Losing it or publishing
  it requires a deliberate update-signing recovery plan.
- Verify that the public key printed by
  `"$(./script/sparkle_tools.sh)/bin/generate_keys" -p` matches
  `SUPublicEDKey` in `Perch/Info.plist`.
- Verify that `SUFeedURL` is
  `https://jurajkrivda.github.io/perch/appcast.xml`.
- Protect the GitHub account and repository with two-factor authentication and
  restrict who can publish releases or change Actions secrets.

The workflow `.github/workflows/publish-sparkle-feed.yml` runs when a release
is published and can also be started manually. It reads published,
non-prerelease GitHub Releases, generates the signed appcast, and deploys the
Sparkle feed to GitHub Pages. Appcast downloads point directly to immutable,
tagged GitHub Release assets. The Pages root may only redirect to the
repository; README is the product landing page.

## 1. Update release metadata

- Update `CFBundleShortVersionString` and the strictly increasing
  `CFBundleVersion` in `Perch/Info.plist`.
- Choose the matching tag `v<version>`, for example `v0.2.0`.
- Prepare concise user-facing Markdown release notes in
  `docs/release-notes-<version>.md`.
- Add the matching HTML notes if the local release tooling still consumes
  them.
- Review known limitations and update README or SUPPORT if behavior changed.

## 2. Run local verification

```bash
xcodebuild test -project Perch.xcodeproj -scheme PerchModelTests \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData
```

Smoke-test a debug build:

```bash
./script/build_and_run.sh
```

Verify manually:

- Perch launches as a menu bar app and all layout actions are available.
- Accessibility permission opens the correct System Settings page.
- Saving and restoring works with at least two applications.
- Restore still works after quitting and reopening one captured application.
- Automatic restore works after wake and a real display topology change.
- The prompt and fully automatic modes both behave as configured.
- DisplayLink or another slow dock follows the hardware checklist in
  `auto-restore-brief.md`.
- Compatibility is smoke-tested on macOS 14 Sonoma.

## 3. Build the distribution artifact

Create the signed, notarized app and DMG:

```bash
PERCH_NOTARY_PROFILE=perch-notary ./script/build_dmg.sh notarize
```

Expected outputs:

- `dist/release/Perch.app`
- `dist/release/Perch.zip`
- `dist/release/Perch.dmg`

The app must contain `Contents/Resources/Sparkle-2.9.5-LICENSE.txt`. The DMG
must contain `Perch.app`, the Applications shortcut, `LICENSE`, and `NOTICE`.

The GitHub Release asset must keep the exact basename `Perch.dmg`. Do not add
the version to that filename; the stable latest-download URL depends on it.

## 4. Verify the final DMG

```bash
xcrun stapler validate dist/release/Perch.dmg
spctl -a -vv -t open --context context:primary-signature dist/release/Perch.dmg
codesign --verify --deep --strict --verbose=2 dist/release/Perch.app
```

On a clean macOS account:

1. Mount `dist/release/Perch.dmg`.
2. Drag `Perch.app` to `/Applications`.
3. Launch it from `/Applications` and confirm Gatekeeper accepts it.
4. Grant Accessibility permission.
5. Save and restore a real layout.
6. Quit and relaunch to confirm persisted layouts survive.

## 5. Tag and publish the GitHub Release

Run from `app/` after the release commit is reviewed and pushed:

```bash
release_version="$(/usr/libexec/PlistBuddy -c \
  'Print :CFBundleShortVersionString' Perch/Info.plist)"
release_tag="v${release_version}"

git tag -s "$release_tag" -m "Perch ${release_version}"
git push origin "$release_tag"

gh release create "$release_tag" dist/release/Perch.dmg \
  --draft \
  --verify-tag \
  --title "Perch ${release_version}" \
  --notes-file "docs/release-notes-${release_version}.md"
```

Before publishing the draft, check that:

- it is still a draft and is not marked as a prerelease;
- it contains exactly one asset named `Perch.dmg`;
- the uploaded size and SHA-256 match the local artifact.
- `gh api repos/jurajkrivda/perch/immutable-releases` reports `enabled: true`.

Publish only after those checks pass:

```bash
gh release edit "$release_tag" --draft=false
gh release verify "$release_tag"
gh release verify-asset "$release_tag" dist/release/Perch.dmg
```

Publishing triggers `publish-sparkle-feed.yml`. A missing or incorrectly named
DMG, or a missing `SPARKLE_PRIVATE_KEY`, must fail that workflow.

## 6. Verify GitHub Releases and Pages

Wait for the **Publish Sparkle feed** workflow and its Pages deployment to
succeed, then run:

```bash
repo_slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
latest_dmg_url="https://github.com/${repo_slug}/releases/latest/download/Perch.dmg"
pages_base_url="https://jurajkrivda.github.io/perch"

curl -fIL "$latest_dmg_url"
curl -fsS "$pages_base_url/appcast.xml" | xmllint --noout -
curl -fsS "$pages_base_url/appcast.xml" |
  grep -Eo 'https://github\.com/[^" ]+/releases/download/v[^" ]+/Perch\.dmg'
```

Verify every printed enclosure URL returns `200`, each URL uses an immutable
version tag, and the newest appcast item has the
expected version, build number, EdDSA signature, and release notes. Pages is a
technical update endpoint, not the product landing page; its root only
redirects to the repository.

## 7. Verify the Sparkle update path

Install an older public Perch release into `/Applications`.

- **Check for Updates…** must offer the new version.
- Sparkle must read the feed from Pages, download the DMG from the tagged
  GitHub Release URL, verify the signature, install it, and relaunch.
- The updated app in `/Applications` must pass:

```bash
spctl -a -vv /Applications/Perch.app
```

Also confirm that a missing network connection produces a recoverable update
error and does not affect layout work.

## 8. After release

- Record the tag, app version, build number, commit, DMG SHA-256, release URL,
  Pages workflow run, and smoke-test result.
- Keep the notarized DMG and signing records in an independent archive.
- Confirm all previously published enclosures remain reachable after the Pages
  deployment.
- Track support issues by macOS version, display setup, and affected
  application.
- Prioritize restore reliability before broader window-management features.
