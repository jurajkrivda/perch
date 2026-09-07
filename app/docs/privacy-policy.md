# Perch Privacy Policy

Last updated: September 7, 2026

Perch is a macOS menu bar utility for saving and restoring local window layouts.

## Data Perch Handles

Perch uses the macOS Accessibility API when you save or restore a layout. This lets the app read visible window metadata such as app bundle identifiers, window titles, window positions, window sizes, and display placement.

Saved layouts are stored locally on your Mac in:

```text
~/Library/Application Support/Perch/slots.json
```

App preferences are stored locally in macOS preferences and Application Support.

If a saved-layout file cannot be read, Perch preserves it in the same folder
under a `slots.json.corrupt-…` name. Dismissing its recovery notice adds
`.acknowledged` to the name and keeps the contents. These preserved files may
contain the same metadata as saved layouts; they are not uploaded automatically.

Perch does not use analytics, advertising trackers, or third-party telemetry.

## Diagnostics

If you choose to export diagnostics, Perch creates a redacted, not anonymous, JSON report at the location you select. The report can include app bundle identifiers, display geometry, layout identifiers, window and layout counts, timestamps, Perch settings, app and macOS versions, system architecture, Accessibility permission status, launch-at-login status, and the last automatic restore decision. It does not include window titles or layout names. Error information is limited to a domain and numeric code. Perch does not upload the report; it leaves your Mac only if you choose to share it.

## Network Access

Perch does not send your layouts, window metadata, diagnostics, or settings to a server.

Perch makes the following network requests:

- **Software updates (Sparkle):** If automatic update checks are enabled, or
  when you manually check, Sparkle contacts Perch's update feed on GitHub Pages
  and may download an update. GitHub receives ordinary request metadata such as
  your IP address, app version, and user agent. No saved layout or window
  information is included.
- **Links you open:** Repository, release, support, and other external links are
  contacted only after you choose to open them and are governed by the
  destination's privacy policy.

## Permissions

Perch requires Accessibility permission to read and move windows. You can remove this permission at any time in macOS System Settings under Privacy & Security.

## Data Removal

To remove Perch data from this Mac completely:

1. Turn off **Launch at login**, quit Perch, and remove the app.
2. Delete Perch's Application Support directory:

```text
~/Library/Application Support/Perch
```

3. Remove Perch preferences, including language, update, and UI preferences:

```sh
defaults delete com.jurajkrivda.perch
```

4. Remove Perch from **System Settings → Privacy & Security → Accessibility**
   and, if still present, from **General → Login Items**.
5. Delete these standard macOS folders if they exist:

```text
~/Library/Caches/com.jurajkrivda.perch
~/Library/Saved Application State/com.jurajkrivda.perch.savedState
```

6. Delete any diagnostic JSON files you previously exported from the locations
   where you saved or shared them.
